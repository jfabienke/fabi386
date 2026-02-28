/*
 * fabi386: L1 Data Cache (16KB, 4-way set-associative, write-back)
 * ------------------------------------------------------------------
 * 3-cycle pipelined, non-blocking L1 data cache.
 *
 * Pipeline:
 *   Cycle 1 (S1): Index SRAM — read tag + data arrays for the addressed set.
 *   Cycle 2 (S2): Tag compare — 4-way parallel compare, hit/miss decision.
 *   Cycle 3 (S3): Data read on hit / MSHR allocation on miss.
 *
 * Geometry (local override of CONF_L1D_BYTES for 16KB):
 *   Total size   : 16384 bytes (16KB)
 *   Line size    : 32 bytes (8 words)
 *   Ways         : 4
 *   Sets         : 128 (16384 / 32 / 4)
 *   Tag width    : 20 bits  (32 - 7 index - 5 offset)
 *   Index width  : 7 bits   (log2(128))
 *   Offset width : 5 bits   (log2(32))
 *
 * Replacement : Tree-based PLRU (3 bits per set for 4 ways)
 * Write policy: Write-back with per-line dirty bit; writeback on eviction
 * Non-blocking: 2-entry MSHR (f386_dcache_mshr) for outstanding misses
 *
 * Feature-gated by CONF_ENABLE_DCACHE — when disabled the module
 * passes requests straight through (TODO: bypass mux not shown here).
 *
 * SRAM synthesis hints use (* ramstyle = "M10K, no_rw_check" *) for
 * Intel/Altera targets.
 *
 * Reference: Patterson & Hennessy COD 5e Ch5; BOOM dcache.scala
 */

import f386_pkg::*;

module f386_dcache (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,          // Invalidate all lines

    // CPU-side request (from LSQ)
    input  logic        req_valid,
    input  logic [31:0] req_addr,
    input  logic [31:0] req_wdata,
    input  logic [3:0]  req_byte_en,    // Byte write enable
    input  logic        req_wr,         // 0=read, 1=write
    output logic        req_ready,      // Can accept request
    output logic        resp_valid,     // Response ready
    output logic [31:0] resp_data,      // Read data
    output logic        resp_miss,      // Miss (went to MSHR)

    // Memory-side (to L2 / memory controller) — cache line fills
    output logic        fill_req,       // Request a cache line fill
    output logic [31:0] fill_addr,      // Line-aligned address
    input  logic        fill_valid,     // Fill data arriving
    input  logic [255:0] fill_data,     // Full 32-byte line
    input  logic        fill_done,      // Fill complete

    // Writeback (evicted dirty lines)
    output logic        wb_req,
    output logic [31:0] wb_addr,
    output logic [255:0] wb_data,
    input  logic        wb_done
);

    // =========================================================================
    // Local Parameters (override CONF_L1D_BYTES for 16KB)
    // =========================================================================
    localparam int CACHE_BYTES     = 16384;               // 16KB total
    localparam int LINE_BYTES      = CONF_L1D_LINE_BYTES; // 32 bytes
    localparam int NUM_WAYS        = 4;
    localparam int NUM_SETS        = CACHE_BYTES / LINE_BYTES / NUM_WAYS; // 128
    localparam int WORDS_PER_LINE  = LINE_BYTES / 4;      // 8
    localparam int OFFSET_W        = $clog2(LINE_BYTES);  // 5
    localparam int INDEX_W         = $clog2(NUM_SETS);    // 7
    localparam int TAG_W           = 32 - INDEX_W - OFFSET_W; // 20
    localparam int WORD_SEL_W      = $clog2(WORDS_PER_LINE);  // 3
    localparam int PLRU_BITS       = 3; // Tree-PLRU for 4 ways: 3 internal nodes

    // =========================================================================
    // Address Field Extraction
    // =========================================================================
    function automatic logic [TAG_W-1:0] addr_tag(input logic [31:0] a);
        return a[31:INDEX_W+OFFSET_W];
    endfunction

    function automatic logic [INDEX_W-1:0] addr_index(input logic [31:0] a);
        return a[INDEX_W+OFFSET_W-1:OFFSET_W];
    endfunction

    function automatic logic [WORD_SEL_W-1:0] addr_word(input logic [31:0] a);
        return a[OFFSET_W-1:2];
    endfunction

    // =========================================================================
    // Tag SRAM: 128 sets x 4 ways — {valid, dirty, tag[19:0]}
    // =========================================================================
    localparam int TAG_ENTRY_W = 1 + 1 + TAG_W; // valid + dirty + tag = 22 bits

    (* ramstyle = "M10K, no_rw_check" *)
    logic [TAG_ENTRY_W-1:0] tag_mem [NUM_SETS][NUM_WAYS];

    // Tag entry field accessors
    function automatic logic tag_valid(input logic [TAG_ENTRY_W-1:0] e);
        return e[TAG_ENTRY_W-1];
    endfunction

    function automatic logic tag_dirty(input logic [TAG_ENTRY_W-1:0] e);
        return e[TAG_ENTRY_W-2];
    endfunction

    function automatic logic [TAG_W-1:0] tag_bits(input logic [TAG_ENTRY_W-1:0] e);
        return e[TAG_W-1:0];
    endfunction

    function automatic logic [TAG_ENTRY_W-1:0] make_tag_entry(
        input logic             v,
        input logic             d,
        input logic [TAG_W-1:0] t
    );
        return {v, d, t};
    endfunction

    // =========================================================================
    // Data SRAM: 128 sets x 4 ways x 8 words
    // =========================================================================
    (* ramstyle = "M10K, no_rw_check" *)
    logic [31:0] data_mem [NUM_SETS][NUM_WAYS][WORDS_PER_LINE];

    // =========================================================================
    // PLRU State: 128 sets x 3 bits (tree-based for 4 ways)
    // =========================================================================
    logic [PLRU_BITS-1:0] plru_bits [NUM_SETS];

    // =========================================================================
    // Pipeline State Machine
    // =========================================================================
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_S1_TAG_RD,
        ST_S2_COMPARE,
        ST_S3_RESPOND,
        ST_WRITEBACK,
        ST_FILL_WAIT,
        ST_FILL_INSTALL,
        ST_FLUSH
    } cache_state_t;

    cache_state_t state, state_next;

    // =========================================================================
    // S1 Pipeline Registers (latched from request)
    // =========================================================================
    logic        s1_valid;
    logic [31:0] s1_addr;
    logic [31:0] s1_wdata;
    logic [3:0]  s1_byte_en;
    logic        s1_wr;

    // =========================================================================
    // S2 Pipeline Registers (tag read results + compare)
    // =========================================================================
    logic                     s2_valid;
    logic [31:0]              s2_addr;
    logic [31:0]              s2_wdata;
    logic [3:0]               s2_byte_en;
    logic                     s2_wr;
    logic [TAG_ENTRY_W-1:0]   s2_tags [NUM_WAYS];
    logic [31:0]              s2_data_words [NUM_WAYS]; // Selected word from each way

    // Hit detection
    logic [NUM_WAYS-1:0]      s2_hit_vec;
    logic                     s2_any_hit;
    logic [1:0]               s2_hit_way;

    // =========================================================================
    // Writeback buffer
    // =========================================================================
    logic [31:0]  wb_addr_r;
    logic [255:0] wb_data_r;
    logic         wb_pending;

    // =========================================================================
    // Fill tracking
    // =========================================================================
    logic [31:0]  fill_addr_r;
    logic         fill_pending;
    logic [1:0]   victim_way;

    // =========================================================================
    // PLRU: 4-way tree-based pseudo-LRU
    // =========================================================================
    // Tree layout for 4 ways (3 bits: b[2], b[1], b[0]):
    //
    //          b[0]
    //         /    \
    //      b[1]    b[2]
    //      / \     / \
    //    w0   w1  w2  w3
    //
    // A bit value of 0 points left (recently used), 1 points right.
    // Victim selection: follow the tree bits to find the LRU leaf.

    function automatic logic [1:0] plru_victim_way(input logic [PLRU_BITS-1:0] bits);
        if (!bits[0]) begin
            // Go right subtree (left was recently used)
            if (!bits[2])
                return 2'd3;
            else
                return 2'd2;
        end else begin
            // Go left subtree
            if (!bits[1])
                return 2'd1;
            else
                return 2'd0;
        end
    endfunction

    function automatic logic [PLRU_BITS-1:0] plru_update(
        input logic [PLRU_BITS-1:0] bits,
        input logic [1:0]           way
    );
        logic [PLRU_BITS-1:0] updated;
        updated = bits;
        case (way)
            2'd0: begin updated[0] = 1'b1; updated[1] = 1'b1; end // Mark w0 as recently used
            2'd1: begin updated[0] = 1'b1; updated[1] = 1'b0; end
            2'd2: begin updated[0] = 1'b0; updated[2] = 1'b1; end
            2'd3: begin updated[0] = 1'b0; updated[2] = 1'b0; end
        endcase
        return updated;
    endfunction

    // =========================================================================
    // MSHR Instance
    // =========================================================================
    logic        mshr_alloc_valid;
    logic [31:0] mshr_alloc_addr;
    logic        mshr_alloc_is_write;
    logic [31:0] mshr_alloc_wdata;
    logic [3:0]  mshr_alloc_byte_en;
    logic        mshr_alloc_ready;

    logic        mshr_fill_match;

    logic        mshr_has_pending;
    logic [31:0] mshr_pending_addr;
    logic        mshr_pending_is_write;
    logic [31:0] mshr_pending_wdata;
    logic [3:0]  mshr_pending_byte_en;

    f386_dcache_mshr u_mshr (
        .clk            (clk),
        .rst_n          (rst_n),
        .flush          (flush),

        .alloc_valid    (mshr_alloc_valid),
        .alloc_addr     (mshr_alloc_addr),
        .alloc_is_write (mshr_alloc_is_write),
        .alloc_wdata    (mshr_alloc_wdata),
        .alloc_byte_en  (mshr_alloc_byte_en),
        .alloc_ready    (mshr_alloc_ready),

        .fill_valid     (fill_valid),
        .fill_addr      (fill_addr_r),
        .fill_match     (mshr_fill_match),

        .has_pending    (mshr_has_pending),
        .pending_addr   (mshr_pending_addr),
        .pending_is_write(mshr_pending_is_write),
        .pending_wdata  (mshr_pending_wdata),
        .pending_byte_en(mshr_pending_byte_en)
    );

    // =========================================================================
    // Flush Counter (iterate over all sets to invalidate)
    // =========================================================================
    logic [INDEX_W-1:0] flush_cnt;
    logic               flush_active;

    // =========================================================================
    // Byte-merge helper: merge wdata into existing word using byte_en
    // =========================================================================
    function automatic logic [31:0] byte_merge(
        input logic [31:0] old_data,
        input logic [31:0] new_data,
        input logic [3:0]  byte_en
    );
        logic [31:0] merged;
        merged[ 7: 0] = byte_en[0] ? new_data[ 7: 0] : old_data[ 7: 0];
        merged[15: 8] = byte_en[1] ? new_data[15: 8] : old_data[15: 8];
        merged[23:16] = byte_en[2] ? new_data[23:16] : old_data[23:16];
        merged[31:24] = byte_en[3] ? new_data[31:24] : old_data[31:24];
        return merged;
    endfunction

    // =========================================================================
    // Line packing/unpacking helpers
    // =========================================================================
    function automatic logic [255:0] pack_line(
        input logic [31:0] words [WORDS_PER_LINE]
    );
        logic [255:0] line;
        for (int i = 0; i < WORDS_PER_LINE; i++)
            line[i*32 +: 32] = words[i];
        return line;
    endfunction

    function automatic logic [31:0] extract_word(
        input logic [255:0]         line,
        input logic [WORD_SEL_W-1:0] sel
    );
        return line[sel*32 +: 32];
    endfunction

    // =========================================================================
    // S2: Tag Compare (combinational)
    // =========================================================================
    always_comb begin
        s2_any_hit = 1'b0;
        s2_hit_way = 2'd0;
        for (int w = 0; w < NUM_WAYS; w++) begin
            s2_hit_vec[w] = tag_valid(s2_tags[w]) &&
                            (tag_bits(s2_tags[w]) == addr_tag(s2_addr));
        end
        for (int w = 0; w < NUM_WAYS; w++) begin
            if (s2_hit_vec[w]) begin
                s2_any_hit = 1'b1;
                s2_hit_way = 2'(w);
            end
        end
    end

    // =========================================================================
    // Request acceptance
    // =========================================================================
    assign req_ready = (state == ST_IDLE) && !flush_active;

    // =========================================================================
    // Main FSM + Pipeline Registers
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            s1_valid        <= 1'b0;
            s2_valid        <= 1'b0;
            resp_valid      <= 1'b0;
            resp_data       <= 32'd0;
            resp_miss       <= 1'b0;
            fill_req        <= 1'b0;
            fill_addr       <= 32'd0;
            wb_req          <= 1'b0;
            wb_addr         <= 32'd0;
            wb_data         <= 256'd0;
            wb_pending      <= 1'b0;
            fill_pending    <= 1'b0;
            flush_active    <= 1'b0;
            flush_cnt       <= '0;
            mshr_alloc_valid <= 1'b0;
            fill_addr_r     <= 32'd0;
            for (int s = 0; s < NUM_SETS; s++) begin
                plru_bits[s] <= '0;
                for (int w = 0; w < NUM_WAYS; w++)
                    tag_mem[s][w] <= '0;
            end
        end else begin
            // Defaults: pulse signals clear each cycle
            resp_valid       <= 1'b0;
            resp_miss        <= 1'b0;
            mshr_alloc_valid <= 1'b0;

            // ---------------------------------------------------------------
            // Flush sequence: walk all sets, clear valid bits
            // ---------------------------------------------------------------
            if (flush && !flush_active) begin
                flush_active <= 1'b1;
                flush_cnt    <= '0;
                state        <= ST_FLUSH;
            end

            if (flush_active) begin
                for (int w = 0; w < NUM_WAYS; w++)
                    tag_mem[flush_cnt][w] <= '0;
                if (flush_cnt == INDEX_W'(NUM_SETS - 1)) begin
                    flush_active <= 1'b0;
                    state        <= ST_IDLE;
                end else begin
                    flush_cnt <= flush_cnt + 1'b1;
                end
            end

            // ---------------------------------------------------------------
            // Normal pipeline operation
            // ---------------------------------------------------------------
            if (!flush_active) begin
                case (state)
                    // ===== IDLE: Accept new request =====
                    ST_IDLE: begin
                        fill_req <= 1'b0;
                        wb_req   <= 1'b0;
                        if (req_valid) begin
                            // S1: Latch request, initiate tag/data SRAM read
                            s1_valid   <= 1'b1;
                            s1_addr    <= req_addr;
                            s1_wdata   <= req_wdata;
                            s1_byte_en <= req_byte_en;
                            s1_wr      <= req_wr;
                            state      <= ST_S1_TAG_RD;
                        end
                    end

                    // ===== S1: Tag + Data SRAM read (1 cycle latency) =====
                    ST_S1_TAG_RD: begin
                        s2_valid   <= s1_valid;
                        s2_addr    <= s1_addr;
                        s2_wdata   <= s1_wdata;
                        s2_byte_en <= s1_byte_en;
                        s2_wr      <= s1_wr;
                        s1_valid   <= 1'b0;

                        // Read tag and data arrays for the indexed set
                        for (int w = 0; w < NUM_WAYS; w++) begin
                            s2_tags[w]       <= tag_mem[addr_index(s1_addr)][w];
                            s2_data_words[w] <= data_mem[addr_index(s1_addr)][w][addr_word(s1_addr)];
                        end
                        state <= ST_S2_COMPARE;
                    end

                    // ===== S2: Tag compare + hit/miss =====
                    ST_S2_COMPARE: begin
                        if (s2_any_hit) begin
                            // --- HIT ---
                            if (s2_wr) begin
                                // Write hit: merge byte data, set dirty
                                data_mem[addr_index(s2_addr)][s2_hit_way][addr_word(s2_addr)] <=
                                    byte_merge(s2_data_words[s2_hit_way],
                                               s2_wdata, s2_byte_en);
                                tag_mem[addr_index(s2_addr)][s2_hit_way] <=
                                    make_tag_entry(1'b1, 1'b1,
                                                   addr_tag(s2_addr));
                                resp_valid <= 1'b1;
                            end else begin
                                // Read hit: output data word
                                resp_valid <= 1'b1;
                                resp_data  <= s2_data_words[s2_hit_way];
                            end
                            // Update PLRU
                            plru_bits[addr_index(s2_addr)] <=
                                plru_update(plru_bits[addr_index(s2_addr)],
                                            s2_hit_way);
                            state <= ST_IDLE;
                        end else begin
                            // --- MISS ---
                            // Select victim way via PLRU
                            victim_way <= plru_victim_way(
                                plru_bits[addr_index(s2_addr)]);

                            // Check if victim is dirty → need writeback first
                            if (tag_valid(s2_tags[plru_victim_way(
                                    plru_bits[addr_index(s2_addr)])]) &&
                                tag_dirty(s2_tags[plru_victim_way(
                                    plru_bits[addr_index(s2_addr)])])) begin
                                // Dirty eviction: initiate writeback
                                wb_pending <= 1'b1;
                                // Reconstruct writeback address from victim tag
                                wb_addr_r <= {tag_bits(s2_tags[plru_victim_way(
                                    plru_bits[addr_index(s2_addr)])]),
                                    addr_index(s2_addr), {OFFSET_W{1'b0}}};
                                state <= ST_WRITEBACK;
                            end else begin
                                // Clean eviction or invalid: go straight to fill
                                state <= ST_FILL_WAIT;
                            end

                            // Allocate MSHR for non-blocking behavior
                            if (mshr_alloc_ready) begin
                                mshr_alloc_valid    <= 1'b1;
                                mshr_alloc_addr     <= {s2_addr[31:OFFSET_W],
                                                        {OFFSET_W{1'b0}}};
                                mshr_alloc_is_write <= s2_wr;
                                mshr_alloc_wdata    <= s2_wdata;
                                mshr_alloc_byte_en  <= s2_byte_en;
                            end

                            // Signal miss to CPU
                            resp_valid <= 1'b1;
                            resp_miss  <= 1'b1;

                            // Record fill address
                            fill_addr_r <= {s2_addr[31:OFFSET_W],
                                            {OFFSET_W{1'b0}}};
                        end
                        s2_valid <= 1'b0;
                    end

                    // ===== WRITEBACK: Send dirty victim line to memory =====
                    ST_WRITEBACK: begin
                        wb_req  <= 1'b1;
                        wb_addr <= wb_addr_r;
                        // Pack victim way's full line into writeback bus
                        for (int i = 0; i < WORDS_PER_LINE; i++)
                            wb_data[i*32 +: 32] <=
                                data_mem[addr_index(s2_addr)][victim_way][i];

                        if (wb_done) begin
                            wb_req     <= 1'b0;
                            wb_pending <= 1'b0;
                            state      <= ST_FILL_WAIT;
                        end
                    end

                    // ===== FILL_WAIT: Request line fill from memory =====
                    ST_FILL_WAIT: begin
                        fill_req  <= 1'b1;
                        fill_addr <= fill_addr_r;

                        if (fill_valid) begin
                            fill_req <= 1'b0;
                            state    <= ST_FILL_INSTALL;
                        end
                    end

                    // ===== FILL_INSTALL: Install filled line into cache =====
                    ST_FILL_INSTALL: begin
                        if (fill_done) begin
                            // Write fill data into data SRAM
                            for (int i = 0; i < WORDS_PER_LINE; i++)
                                data_mem[addr_index(fill_addr_r)][victim_way][i] <=
                                    fill_data[i*32 +: 32];

                            // If this was a write miss, merge the store data
                            if (mshr_pending_is_write && mshr_fill_match) begin
                                data_mem[addr_index(fill_addr_r)][victim_way][addr_word(fill_addr_r)] <=
                                    byte_merge(
                                        extract_word(fill_data, addr_word(fill_addr_r)),
                                        mshr_pending_wdata,
                                        mshr_pending_byte_en);
                                // Install tag as dirty (write-allocate merge)
                                tag_mem[addr_index(fill_addr_r)][victim_way] <=
                                    make_tag_entry(1'b1, 1'b1,
                                                   addr_tag(fill_addr_r));
                            end else begin
                                // Clean fill: install tag as valid, not dirty
                                tag_mem[addr_index(fill_addr_r)][victim_way] <=
                                    make_tag_entry(1'b1, 1'b0,
                                                   addr_tag(fill_addr_r));
                            end

                            // Update PLRU for the filled way
                            plru_bits[addr_index(fill_addr_r)] <=
                                plru_update(plru_bits[addr_index(fill_addr_r)],
                                            victim_way);

                            fill_pending <= 1'b0;
                            state        <= ST_IDLE;
                        end
                    end

                    // ===== FLUSH: handled above =====
                    ST_FLUSH: begin
                        // Flush logic handled in flush_active block above
                    end

                    default: state <= ST_IDLE;
                endcase
            end // !flush_active
        end // !rst_n
    end

endmodule
