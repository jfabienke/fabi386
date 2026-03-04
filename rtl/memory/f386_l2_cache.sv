/*
 * fabi386: Unified L2 Cache (128KB, 4-way set-associative, write-back)
 * ---------------------------------------------------------------------
 * Drop-in replacement for f386_mem_ctrl. Same port interface (plus
 * data_cacheable/data_strong_order from shim attribute pass-through).
 *
 * Geometry:
 *   Total size   : 128 KB
 *   Line size    : 32 bytes (4 × 64-bit words)
 *   Ways         : 4
 *   Sets         : 1024 (128KB / 32B / 4)
 *   Tag width    : 17 bits  (addr[31:15])
 *   Index width  : 10 bits  (addr[14:5])
 *   Offset width : 5 bits   (addr[4:0])
 *   Word offset  : 2 bits   (addr[4:3]) — selects 64-bit word within line
 *
 * Replacement : Tree-based PLRU (3 bits per set, same as L1D)
 * Write policy: Write-back, write-allocate
 *
 * DDRAM interface: burst-4 for line fills and dirty writebacks.
 *
 * Feature-gated by CONF_ENABLE_L2_CACHE.
 *
 * Reference: f386_dcache.sv (L1D patterns), f386_mem_ctrl.sv (port interface)
 */

import f386_pkg::*;

module f386_l2_cache (
    input  logic         clk,
    input  logic         rst_n,

    // --- Instruction Fetch (128-bit) ---
    input  logic [31:0]  ifetch_addr,
    output logic [127:0] ifetch_data,
    output logic         ifetch_valid,
    input  logic         ifetch_req,

    // --- Data Port (64-bit, from shim) ---
    input  logic [31:0]  data_addr,
    input  logic [63:0]  data_wdata,
    output logic [63:0]  data_rdata,
    input  logic         data_req,
    input  logic         data_wr,
    input  logic [7:0]   data_byte_en,
    input  logic         data_cacheable,
    input  logic         data_strong_order,
    output logic         data_ack,
    output logic         data_gnt,        // Grant: 1-cycle pulse when data request accepted

    // --- Page Walker (32-bit) ---
    input  logic [31:0]  pt_addr,
    input  logic [31:0]  pt_wdata,
    output logic [31:0]  pt_rdata,
    input  logic         pt_req,
    input  logic         pt_wr,
    output logic         pt_ack,

    // --- A20 Gate ---
    input  logic         a20_gate,

    // --- DDRAM Interface (29-bit word address) ---
    output logic [28:0]  ddram_addr,
    output logic [7:0]   ddram_burstcnt,
    output logic [63:0]  ddram_din,
    output logic [7:0]   ddram_be,
    output logic         ddram_we,
    output logic         ddram_rd,
    input  logic [63:0]  ddram_dout,
    input  logic         ddram_dout_ready,
    input  logic         ddram_busy
);

    // =========================================================================
    // Local Parameters
    // =========================================================================
    localparam int NUM_SETS       = CONF_L2_SETS;        // 1024
    localparam int NUM_WAYS       = CONF_L2_WAYS;        // 4
    localparam int LINE_BYTES     = CONF_L2_LINE_BYTES;  // 32
    localparam int WORDS_PER_LINE = LINE_BYTES / 8;      // 4 (64-bit words)
    localparam int OFFSET_W       = CONF_L2_OFFSET_W;    // 5
    localparam int INDEX_W        = CONF_L2_INDEX_W;     // 10
    localparam int TAG_W          = CONF_L2_TAG_W;       // 17
    localparam int WORD_SEL_W     = $clog2(WORDS_PER_LINE); // 2
    localparam int PLRU_BITS      = 3;  // Tree-PLRU for 4 ways

    // =========================================================================
    // A20 Gate
    // =========================================================================
    function automatic logic [31:0] apply_a20(input logic [31:0] addr, input logic gate);
        if (gate)
            return addr;
        else
            return {addr[31:21], 1'b0, addr[19:0]};
    endfunction

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
        return a[OFFSET_W-1:3];
    endfunction

    // (Tag entry helpers: te_valid removed — valid is in tag_valid[] FF array.
    //  Remaining accessors: tm_dirty / tm_tag / make_tm_entry — defined below tag_mem.)

    // =========================================================================
    // PLRU Functions (same as L1D f386_dcache.sv)
    // =========================================================================
    //          b[0]
    //         /    \
    //      b[1]    b[2]
    //      / \     / \
    //    w0   w1  w2  w3

    function automatic logic [1:0] plru_victim_way(input logic [PLRU_BITS-1:0] bits);
        if (!bits[0]) begin
            if (!bits[2])
                return 2'd3;
            else
                return 2'd2;
        end else begin
            if (!bits[1])
                return 2'd1;
            else
                return 2'd0;
        end
    endfunction

    // Prefer an invalid (cold) way over PLRU eviction.
    function automatic logic [1:0] select_victim(
        input logic [NUM_WAYS-1:0]    valid,
        input logic [PLRU_BITS-1:0]   plru
    );
        for (int w = 0; w < NUM_WAYS; w++)
            if (!valid[w]) return 2'(w);
        return plru_victim_way(plru);
    endfunction

    function automatic logic [PLRU_BITS-1:0] plru_update(
        input logic [PLRU_BITS-1:0] bits,
        input logic [1:0]           way
    );
        logic [PLRU_BITS-1:0] updated;
        updated = bits;
        case (way)
            2'd0: begin updated[0] = 1'b1; updated[1] = 1'b1; end
            2'd1: begin updated[0] = 1'b1; updated[1] = 1'b0; end
            2'd2: begin updated[0] = 1'b0; updated[2] = 1'b1; end
            2'd3: begin updated[0] = 1'b0; updated[2] = 1'b0; end
        endcase
        return updated;
    endfunction

    // =========================================================================
    // Byte-Merge Helper (64-bit)
    // =========================================================================
    function automatic logic [63:0] byte_merge64(
        input logic [63:0] old_data,
        input logic [63:0] new_data,
        input logic [7:0]  byte_en
    );
        logic [63:0] merged;
        for (int i = 0; i < 8; i++)
            merged[i*8 +: 8] = byte_en[i] ? new_data[i*8 +: 8] : old_data[i*8 +: 8];
        return merged;
    endfunction

    // =========================================================================
    // Tag Valid Bits: FF array (not in M10K — must support async reset)
    // =========================================================================
    // Separated from tag_mem so that the M10K ramstyle hint is not defeated
    // by reset logic.  1024 sets × 4 ways = 4096 FFs.
    logic [NUM_WAYS-1:0] tag_valid [NUM_SETS];

    // =========================================================================
    // Tag SRAM: 1024 sets × 4 ways × (1 dirty + 17 tag) = 18 bits
    // =========================================================================
    // Valid bit lives in tag_valid[] above, NOT in tag_mem.
    localparam int TAG_MEM_W = 1 + TAG_W;  // dirty + tag = 18 bits
    (* ramstyle = "M10K, no_rw_check" *)
    logic [TAG_MEM_W-1:0] tag_mem [NUM_SETS][NUM_WAYS];

    // Tag SRAM field accessors (operate on tag_mem entries, NOT valid)
    function automatic logic tm_dirty(input logic [TAG_MEM_W-1:0] e);
        return e[TAG_MEM_W-1];
    endfunction

    function automatic logic [TAG_W-1:0] tm_tag(input logic [TAG_MEM_W-1:0] e);
        return e[TAG_W-1:0];
    endfunction

    function automatic logic [TAG_MEM_W-1:0] make_tm_entry(
        input logic             d,
        input logic [TAG_W-1:0] t
    );
        return {d, t};
    endfunction

    // =========================================================================
    // Data SRAM: 1024 sets × 4 ways × 4 words × 64 bits
    // =========================================================================
    (* ramstyle = "M10K, no_rw_check" *)
    logic [63:0] data_mem [NUM_SETS][NUM_WAYS][WORDS_PER_LINE];

    // =========================================================================
    // PLRU State: 1024 sets × 3 bits (FFs — too small for M10K)
    // =========================================================================
    logic [PLRU_BITS-1:0] plru_bits [NUM_SETS];

    // =========================================================================
    // Arbiter: Source Selection
    // =========================================================================
    typedef enum logic [1:0] {
        SRC_NONE   = 2'd0,
        SRC_IFETCH = 2'd1,
        SRC_DATA   = 2'd2,
        SRC_PT     = 2'd3
    } arb_source_t;

    // =========================================================================
    // FSM States
    // =========================================================================
    typedef enum logic [3:0] {
        L2_IDLE          = 4'd0,
        L2_TAG_RD        = 4'd1,
        L2_TAG_CMP       = 4'd2,
        L2_HIT_RD        = 4'd3,
        L2_HIT_RD2       = 4'd4,   // Second word for ifetch
        L2_RESPOND       = 4'd5,
        L2_EVICT_RD      = 4'd6,
        L2_WB_BURST      = 4'd7,
        L2_FILL_BURST    = 4'd8,
        L2_FILL_INSTALL  = 4'd9,
        L2_UC_ISSUE      = 4'd10,
        L2_UC_WAIT       = 4'd11,
        L2_IFETCH_XLINE  = 4'd12   // Cross-line ifetch second lookup
    } l2_state_t;

    l2_state_t state;

    // Data grant — combinational, fires on the cycle IDLE accepts data_req
    assign data_gnt = (state == L2_IDLE) && data_req && !pt_req;

    // =========================================================================
    // Pipeline Registers
    // =========================================================================
    arb_source_t arb_source;
    logic [31:0] arb_addr;       // A20-masked, latched address
    logic [63:0] arb_wdata;
    logic [7:0]  arb_byte_en;
    logic        arb_wr;
    logic        arb_cacheable;

    // Tag read results
    logic [TAG_MEM_W-1:0]   tag_rd [NUM_WAYS];    // {dirty, tag} from M10K
    logic [NUM_WAYS-1:0]    tag_valid_rd;          // Valid bits from FF array
    logic [63:0]            data_rd_word;           // Data word from SRAM

    // Hit detection
    logic [NUM_WAYS-1:0] hit_vec;
    logic                any_hit;
    logic [1:0]          hit_way;

    // Victim tracking
    logic [1:0]          victim_way;
    logic [TAG_W-1:0]    evict_tag;
    logic                evict_dirty;

    // Eviction line buffer (4 × 64-bit words read from data SRAM)
    logic [63:0] evict_buf [WORDS_PER_LINE];
    logic [1:0]  evict_rd_cnt;

    // Writeback burst counter
    logic [1:0]  wb_beat_cnt;

    // Fill burst tracking
    logic [63:0] fill_buf [WORDS_PER_LINE];
    logic [1:0]  fill_beat_cnt;
    logic        fill_rd_issued;   // Prevents re-issuing ddram_rd once launched

    // Ifetch assembly
    logic [63:0] ifetch_word0;
    logic        ifetch_cross_line;  // addr[4:3] == 2'b11
    logic        ifetch_second_pass; // Currently on second line lookup

    // =========================================================================
    // Tag Compare (combinational)
    // =========================================================================
    always_comb begin
        any_hit = 1'b0;
        hit_way = 2'd0;
        for (int w = 0; w < NUM_WAYS; w++) begin
            hit_vec[w] = tag_valid_rd[w] &&
                         (tm_tag(tag_rd[w]) == addr_tag(arb_addr));
        end
        for (int w = 0; w < NUM_WAYS; w++) begin
            if (hit_vec[w]) begin
                any_hit = 1'b1;
                hit_way = 2'(w);
            end
        end
    end

    // =========================================================================
    // Main FSM
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= L2_IDLE;
            ifetch_valid <= 1'b0;
            ifetch_data  <= 128'd0;
            data_ack     <= 1'b0;
            data_rdata   <= 64'd0;
            pt_ack       <= 1'b0;
            pt_rdata     <= 32'd0;
            ddram_rd     <= 1'b0;
            ddram_we     <= 1'b0;
            ddram_addr   <= 29'd0;
            ddram_burstcnt <= 8'd0;
            ddram_din    <= 64'd0;
            ddram_be     <= 8'd0;
            arb_source   <= SRC_NONE;
            ifetch_second_pass <= 1'b0;
            wb_beat_cnt  <= 2'd0;
            fill_beat_cnt  <= 2'd0;
            fill_rd_issued <= 1'b0;
            evict_rd_cnt   <= 2'd0;
            // tag_valid[] is a FF array — safe to reset in a loop.
            // tag_mem[] is M10K — NOT reset here (contents are don't-care
            // when valid=0).  plru_bits[] is also FFs.
            for (int s = 0; s < NUM_SETS; s++) begin
                tag_valid[s] <= '0;
                plru_bits[s] <= '0;
            end
        end else begin
            // Pulse signals clear each cycle
            ifetch_valid <= 1'b0;
            data_ack     <= 1'b0;
            pt_ack       <= 1'b0;
            ddram_rd     <= 1'b0;
            ddram_we     <= 1'b0;

            case (state)

                // =============================================================
                // IDLE: Arbitrate and latch request
                // =============================================================
                L2_IDLE: begin
                    if (pt_req) begin
                        arb_source    <= SRC_PT;
                        arb_addr      <= apply_a20(pt_addr, a20_gate);
                        arb_wdata     <= {32'd0, pt_wdata};
                        arb_byte_en   <= 8'h0F;  // 32-bit write: low 4 bytes
                        arb_wr        <= pt_wr;
                        arb_cacheable <= 1'b1;    // Page walks always cacheable
                        state         <= L2_TAG_RD;
                    end else if (data_req) begin
                        arb_source    <= SRC_DATA;
                        arb_addr      <= apply_a20(data_addr, a20_gate);
                        arb_wdata     <= data_wdata;
                        arb_byte_en   <= data_byte_en;
                        arb_wr        <= data_wr;
                        arb_cacheable <= data_cacheable;
                        if (!data_cacheable) begin
                            state <= L2_UC_ISSUE;
                        end else begin
                            state <= L2_TAG_RD;
                        end
                    end else if (ifetch_req) begin
                        arb_source    <= SRC_IFETCH;
                        arb_addr      <= apply_a20(ifetch_addr, a20_gate);
                        arb_wdata     <= 64'd0;
                        arb_byte_en   <= 8'hFF;
                        arb_wr        <= 1'b0;
                        arb_cacheable <= 1'b1;    // Ifetch always cacheable
                        ifetch_cross_line  <= (ifetch_addr[4:3] == 2'b11);
                        ifetch_second_pass <= 1'b0;
                        state         <= L2_TAG_RD;
                    end
                end

                // =============================================================
                // TAG_RD: Read tag + data SRAM (1-cycle M10K latency)
                // =============================================================
                L2_TAG_RD: begin
                    for (int w = 0; w < NUM_WAYS; w++)
                        tag_rd[w] <= tag_mem[addr_index(arb_addr)][w];
                    tag_valid_rd <= tag_valid[addr_index(arb_addr)];
                    state <= L2_TAG_CMP;
                end

                // =============================================================
                // TAG_CMP: Compare tags, determine hit/miss
                // =============================================================
                L2_TAG_CMP: begin
                    if (any_hit) begin
                        // --- HIT ---
                        plru_bits[addr_index(arb_addr)] <=
                            plru_update(plru_bits[addr_index(arb_addr)], hit_way);

                        case (arb_source)
                            SRC_DATA: begin
                                if (arb_wr) begin
                                    // Write hit: read-modify-write
                                    data_rd_word <= data_mem[addr_index(arb_addr)][hit_way][addr_word(arb_addr)];
                                    state <= L2_HIT_RD;  // Need 1 cycle to RMW
                                end else begin
                                    // Read hit: read data word
                                    data_rd_word <= data_mem[addr_index(arb_addr)][hit_way][addr_word(arb_addr)];
                                    state <= L2_RESPOND;
                                end
                            end
                            SRC_PT: begin
                                if (arb_wr) begin
                                    data_rd_word <= data_mem[addr_index(arb_addr)][hit_way][addr_word(arb_addr)];
                                    state <= L2_HIT_RD;
                                end else begin
                                    data_rd_word <= data_mem[addr_index(arb_addr)][hit_way][addr_word(arb_addr)];
                                    state <= L2_RESPOND;
                                end
                            end
                            SRC_IFETCH: begin
                                // Read first word
                                data_rd_word <= data_mem[addr_index(arb_addr)][hit_way][addr_word(arb_addr)];
                                state <= L2_HIT_RD;
                            end
                            default: state <= L2_IDLE;
                        endcase
                    end else begin
                        // --- MISS ---
                        victim_way  <= select_victim(tag_valid_rd, plru_bits[addr_index(arb_addr)]);
                        evict_tag   <= tm_tag(tag_rd[select_victim(tag_valid_rd, plru_bits[addr_index(arb_addr)])]);
                        evict_dirty <= tag_valid_rd[select_victim(tag_valid_rd, plru_bits[addr_index(arb_addr)])] &&
                                       tm_dirty(tag_rd[select_victim(tag_valid_rd, plru_bits[addr_index(arb_addr)])]);
                        evict_rd_cnt <= 2'd0;
                        state <= L2_EVICT_RD;
                    end
                end

                // =============================================================
                // HIT_RD: Data available from SRAM read — process hit
                // =============================================================
                L2_HIT_RD: begin
                    case (arb_source)
                        SRC_DATA: begin
                            if (arb_wr) begin
                                // Write hit: byte-merge and write back
                                data_mem[addr_index(arb_addr)][hit_way][addr_word(arb_addr)] <=
                                    byte_merge64(data_rd_word, arb_wdata, arb_byte_en);
                                tag_mem[addr_index(arb_addr)][hit_way] <=
                                    make_tm_entry(1'b1, addr_tag(arb_addr));
                                // tag_valid already set (this is a hit)
                                data_ack <= 1'b1;
                                state    <= L2_IDLE;
                            end
                        end
                        SRC_PT: begin
                            if (arb_wr) begin
                                data_mem[addr_index(arb_addr)][hit_way][addr_word(arb_addr)] <=
                                    byte_merge64(data_rd_word, arb_wdata, arb_byte_en);
                                tag_mem[addr_index(arb_addr)][hit_way] <=
                                    make_tm_entry(1'b1, addr_tag(arb_addr));
                                pt_ack <= 1'b1;
                                state  <= L2_IDLE;
                            end
                        end
                        SRC_IFETCH: begin
                            if (ifetch_second_pass) begin
                                // Second pass of cross-line fetch:
                                // ifetch_word0 already holds word 3 of previous line
                                // data_rd_word holds word 0 of this line (from TAG_CMP)
                                // Go directly to assembly — no additional SRAM read needed
                                state <= L2_HIT_RD2;
                            end else begin
                                // First (or only) pass: stash first word
                                ifetch_word0 <= data_rd_word;
                                if (ifetch_cross_line) begin
                                    // Need second line lookup for cross-line fetch
                                    state <= L2_IFETCH_XLINE;
                                end else begin
                                    // Same line: read next sequential word
                                    data_rd_word <= data_mem[addr_index(arb_addr)][hit_way][addr_word(arb_addr) + 2'd1];
                                    state <= L2_HIT_RD2;
                                end
                            end
                        end
                        default: state <= L2_IDLE;
                    endcase
                end

                // =============================================================
                // HIT_RD2: Second word for ifetch
                // =============================================================
                L2_HIT_RD2: begin
                    // Assemble 128-bit ifetch block: {high word, low word}
                    ifetch_data  <= {data_rd_word, ifetch_word0};
                    ifetch_valid <= 1'b1;
                    state        <= L2_IDLE;
                end

                // =============================================================
                // IFETCH_XLINE: Cross-line ifetch — start second line lookup
                // =============================================================
                L2_IFETCH_XLINE: begin
                    // Stash first word, update arb_addr to next line
                    arb_addr <= {arb_addr[31:OFFSET_W] + 1'b1, {OFFSET_W{1'b0}}};
                    ifetch_second_pass <= 1'b1;
                    state <= L2_TAG_RD;
                end

                // =============================================================
                // RESPOND: Deliver read data to requesting client
                // =============================================================
                L2_RESPOND: begin
                    case (arb_source)
                        SRC_DATA: begin
                            data_rdata <= data_rd_word;
                            data_ack   <= 1'b1;
                        end
                        SRC_PT: begin
                            pt_rdata <= data_rd_word[31:0];
                            pt_ack   <= 1'b1;
                        end
                        default: ;
                    endcase
                    state <= L2_IDLE;
                end

                // =============================================================
                // EVICT_RD: Read victim line from data SRAM (4 cycles)
                // =============================================================
                L2_EVICT_RD: begin
                    evict_buf[evict_rd_cnt] <= data_mem[addr_index(arb_addr)][victim_way][evict_rd_cnt];
                    if (evict_rd_cnt == 2'd3) begin
                        if (evict_dirty) begin
                            wb_beat_cnt <= 2'd0;
                            state <= L2_WB_BURST;
                        end else begin
                            fill_beat_cnt  <= 2'd0;
                            fill_rd_issued <= 1'b0;
                            state <= L2_FILL_BURST;
                        end
                    end else begin
                        evict_rd_cnt <= evict_rd_cnt + 2'd1;
                    end
                end

                // =============================================================
                // WB_BURST: Write back dirty victim (burst-4)
                // =============================================================
                L2_WB_BURST: begin
                    if (!ddram_busy) begin
                        // Reconstruct writeback word address: {evict_tag, set_index, 2'b00}
                        // Held stable across all beats (Avalon-MM convention)
                        ddram_addr     <= {evict_tag, addr_index(arb_addr), 2'b00};
                        ddram_burstcnt <= 8'd4;
                        ddram_din      <= evict_buf[wb_beat_cnt];
                        ddram_be       <= 8'hFF;
                        ddram_we       <= 1'b1;

                        if (wb_beat_cnt == 2'd3) begin
                            fill_beat_cnt  <= 2'd0;
                            fill_rd_issued <= 1'b0;
                            state <= L2_FILL_BURST;
                        end else begin
                            wb_beat_cnt <= wb_beat_cnt + 2'd1;
                        end
                    end
                end

                // =============================================================
                // FILL_BURST: Read fill line from DDRAM (burst-4)
                // =============================================================
                L2_FILL_BURST: begin
                    // Issue burst-4 read exactly once (fill_rd_issued guards re-issue)
                    if (!fill_rd_issued && !ddram_busy) begin
                        ddram_addr     <= arb_addr[31:3] & ~29'd3;  // Line-aligned word addr
                        ddram_burstcnt <= 8'd4;
                        ddram_rd       <= 1'b1;
                        fill_rd_issued <= 1'b1;
                    end

                    if (ddram_dout_ready) begin
                        fill_buf[fill_beat_cnt] <= ddram_dout;
                        if (fill_beat_cnt == 2'd3) begin
                            state <= L2_FILL_INSTALL;
                        end else begin
                            fill_beat_cnt <= fill_beat_cnt + 2'd1;
                        end
                    end
                end

                // =============================================================
                // FILL_INSTALL: Write fill line into data SRAM + tag
                // =============================================================
                L2_FILL_INSTALL: begin
                    // Install all 4 words
                    for (int i = 0; i < WORDS_PER_LINE; i++)
                        data_mem[addr_index(arb_addr)][victim_way][i] <= fill_buf[i];

                    // Set valid bit for the installed way
                    tag_valid[addr_index(arb_addr)][victim_way] <= 1'b1;

                    // If this was a write miss, merge the store data
                    if (arb_wr && arb_source == SRC_DATA) begin
                        data_mem[addr_index(arb_addr)][victim_way][addr_word(arb_addr)] <=
                            byte_merge64(fill_buf[addr_word(arb_addr)], arb_wdata, arb_byte_en);
                        tag_mem[addr_index(arb_addr)][victim_way] <=
                            make_tm_entry(1'b1, addr_tag(arb_addr));
                        data_ack <= 1'b1;
                    end else if (arb_wr && arb_source == SRC_PT) begin
                        data_mem[addr_index(arb_addr)][victim_way][addr_word(arb_addr)] <=
                            byte_merge64(fill_buf[addr_word(arb_addr)], arb_wdata, arb_byte_en);
                        tag_mem[addr_index(arb_addr)][victim_way] <=
                            make_tm_entry(1'b1, addr_tag(arb_addr));
                        pt_ack <= 1'b1;
                    end else begin
                        // Clean fill
                        tag_mem[addr_index(arb_addr)][victim_way] <=
                            make_tm_entry(1'b0, addr_tag(arb_addr));

                        // Set data_rd_word for the subsequent read response
                        data_rd_word <= fill_buf[addr_word(arb_addr)];
                    end

                    // Update PLRU
                    plru_bits[addr_index(arb_addr)] <=
                        plru_update(plru_bits[addr_index(arb_addr)], victim_way);

                    // Determine next state
                    if (arb_wr) begin
                        state <= L2_IDLE;
                    end else if (arb_source == SRC_IFETCH) begin
                        // Need to re-enter tag path to read the just-installed line
                        // The line is now in the cache; re-do lookup
                        state <= L2_TAG_RD;
                    end else begin
                        // Read hit on just-filled data
                        state <= L2_RESPOND;
                    end
                end

                // =============================================================
                // UC_ISSUE: Uncacheable — direct DDRAM access
                // =============================================================
                L2_UC_ISSUE: begin
                    if (!ddram_busy) begin
                        ddram_addr     <= arb_addr[31:3];
                        ddram_burstcnt <= 8'd1;
                        if (arb_wr) begin
                            ddram_din <= arb_wdata;
                            ddram_be  <= arb_byte_en;
                            ddram_we  <= 1'b1;
                            data_ack  <= 1'b1;
                            state     <= L2_IDLE;
                        end else begin
                            ddram_rd <= 1'b1;
                            state    <= L2_UC_WAIT;
                        end
                    end
                end

                // =============================================================
                // UC_WAIT: Wait for uncacheable read data
                // =============================================================
                L2_UC_WAIT: begin
                    if (ddram_dout_ready) begin
                        data_rdata <= ddram_dout;
                        data_ack   <= 1'b1;
                        state      <= L2_IDLE;
                    end
                end

                default: state <= L2_IDLE;

            endcase
        end
    end

    // =========================================================================
    // Assertions (sim-only)
    // =========================================================================
`ifndef SYNTHESIS

    // Tag hit uniqueness: at most one way may hit
    always @(posedge clk) begin
        if (rst_n && state == L2_TAG_CMP)
            assert ($countones(hit_vec) <= 1)
                else $error("L2: multiple ways hit for addr %08h, hit_vec=%b", arb_addr, hit_vec);
    end

    // No simultaneous client acks
    always @(posedge clk) begin
        if (rst_n)
            assert ($countones({data_ack, ifetch_valid, pt_ack}) <= 1)
                else $error("L2: multiple client acks in same cycle");
    end

    // Cacheability consistency (one-way): if is_mmio_addr says MMIO, cacheable must be false
    always @(posedge clk) begin
        if (rst_n && data_req)
            assert (!(is_mmio_addr(data_addr) && data_cacheable))
                else $warning("L2: is_mmio_addr(%08h) but data_cacheable=1", data_addr);
    end

    // Watchdog: no state should be stuck for > 1024 cycles
    logic [10:0] watchdog_cnt;
    l2_state_t   watchdog_state;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            watchdog_cnt   <= 11'd0;
            watchdog_state <= L2_IDLE;
        end else begin
            if (state != watchdog_state) begin
                watchdog_cnt   <= 11'd0;
                watchdog_state <= state;
            end else if (state != L2_IDLE) begin
                watchdog_cnt <= watchdog_cnt + 11'd1;
                if (watchdog_cnt == 11'd1023)
                    $fatal(1, "L2: stuck in state %0d for 1024 cycles", state);
            end
        end
    end

`endif

endmodule
