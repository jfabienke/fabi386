/*
 * fabi386: Split-Phase L2 Cache with MSHR Support (v2.1)
 * -------------------------------------------------------
 * Non-blocking unified L2 cache with split-phase data port.
 * Replaces shim+L2 pair when CONF_ENABLE_MEM_FABRIC=1.
 *
 * Data port uses mem_req_t/mem_rsp_t (split-phase, tagged).
 * Ifetch and PT remain blocking (same interface as f386_l2_cache).
 *
 * Geometry: same as f386_l2_cache (128KB, 4-way, 32B lines, 1024 sets).
 *
 * v2.0: 4 MSHRs for data-port misses. Lookup pipeline is freed after
 *       MSHR allocation — hits-under-miss while DDRAM fills in flight.
 *       SRAM operations for MSHRs (evict read, fill install) are
 *       serviced by the lookup pipeline via dedicated states.
 *       Ifetch/PT misses use the blocking path (no MSHR).
 *       No secondary miss coalescing — stall on same-line conflict.
 *
 * v2.1: Replaced inferred 2D/3D arrays (tag_mem, data_mem) with explicit
 *       per-way f386_bram_sdp instances.  4 tag BRAMs (1 per way) and
 *       16 data BRAMs (4 ways x 4 words).  tag_valid and plru_bits remain
 *       in flip-flops.
 *
 * v2.2: Secondary miss coalescing.  When a data-port load miss hits an
 *       already-active MSHR (same cache line), the request is enqueued
 *       in the MSHR's secondary queue (up to 3 per MSHR) instead of
 *       stalling.  After the primary response, secondaries are drained
 *       one per cycle from MH_COMPLETE before transitioning to MH_FREE.
 *       If all 3 secondary slots are full, or the MSHR is already in
 *       MH_COMPLETE, mshr_conflict still stalls. Stores are not
 *       coalesced (they need write-allocate merge at install time).
 *
 * v2.3: Non-blocking ifetch/PT path.  Ifetch (non-cross-line) and PT read
 *       misses now allocate MSHRs from the shared pool instead of stalling
 *       the lookup pipeline.  At MH_COMPLETE, responses are routed to the
 *       correct port based on per-MSHR source tracking (mh_source).
 *       Cross-line ifetch misses and PT writes still use the blocking path.
 *       Falls back to blocking path when no MSHR is free.
 *
 * Feature-gated by CONF_ENABLE_MEM_FABRIC.
 */

import f386_pkg::*;

module f386_l2_cache_sp (
    input  logic         clk,
    input  logic         rst_n,

    // --- Instruction Fetch (128-bit, blocking) ---
    input  logic [31:0]  ifetch_addr,
    output logic [127:0] ifetch_data,
    output logic         ifetch_valid,
    input  logic         ifetch_req,

    // --- Data Port (split-phase, from arbiter) ---
    input  logic         data_req_valid,
    output logic         data_req_ready,
    input  mem_req_t     data_req,
    output logic         data_rsp_valid,
    input  logic         data_rsp_ready,
    output mem_rsp_t     data_rsp,

    // --- Page Walker (32-bit, blocking) ---
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

    // Gate dependency: CONF_ENABLE_MEM_FABRIC requires CONF_ENABLE_LSQ_MEMIF + L2_CACHE.
    // Enforced at system level in f386_emu.sv (generate-if). This module is self-contained.

    // =========================================================================
    // Local Parameters
    // =========================================================================
    localparam int NUM_SETS       = CONF_L2_SETS;
    localparam int NUM_WAYS       = CONF_L2_WAYS;
    localparam int LINE_BYTES     = CONF_L2_LINE_BYTES;
    localparam int WORDS_PER_LINE = LINE_BYTES / 8;       // 4
    localparam int OFFSET_W       = CONF_L2_OFFSET_W;     // 5
    localparam int INDEX_W        = CONF_L2_INDEX_W;       // 10
    localparam int TAG_W          = CONF_L2_TAG_W;         // 17
    localparam int WORD_SEL_W     = $clog2(WORDS_PER_LINE);// 2
    localparam int PLRU_BITS      = 3;

    localparam int NUM_MSHR       = CONF_L2_NUM_MSHR;      // 4
    localparam int MSHR_ID_W      = CONF_L2_MSHR_ID_W;     // 2

    // =========================================================================
    // Helper Functions
    // =========================================================================
    function automatic logic [31:0] apply_a20(input logic [31:0] addr, input logic gate);
        if (gate) return addr;
        else      return {addr[31:21], 1'b0, addr[19:0]};
    endfunction

    function automatic logic [TAG_W-1:0] addr_tag(input logic [31:0] a);
        return a[31:INDEX_W+OFFSET_W];
    endfunction

    function automatic logic [INDEX_W-1:0] addr_index(input logic [31:0] a);
        return a[INDEX_W+OFFSET_W-1:OFFSET_W];
    endfunction

    function automatic logic [WORD_SEL_W-1:0] addr_word(input logic [31:0] a);
        return a[OFFSET_W-1:3];
    endfunction

    function automatic logic [1:0] plru_victim_way(input logic [PLRU_BITS-1:0] bits);
        if (!bits[0]) begin
            if (!bits[2]) return 2'd3;
            else          return 2'd2;
        end else begin
            if (!bits[1]) return 2'd1;
            else          return 2'd0;
        end
    endfunction

    // Prefer an invalid (cold) way over PLRU eviction. On a cold set this
    // fills all 4 ways before any eviction occurs.
    function automatic logic [1:0] select_victim(
        input logic [NUM_WAYS-1:0]    valid,
        input logic [PLRU_BITS-1:0]   plru
    );
        for (int w = 0; w < NUM_WAYS; w++)
            if (!valid[w]) return 2'(w);
        return plru_victim_way(plru);
    endfunction

    function automatic logic [PLRU_BITS-1:0] plru_update(
        input logic [PLRU_BITS-1:0] bits, input logic [1:0] way
    );
        logic [PLRU_BITS-1:0] u;
        u = bits;
        case (way)
            2'd0: begin u[0] = 1'b1; u[1] = 1'b1; end
            2'd1: begin u[0] = 1'b1; u[1] = 1'b0; end
            2'd2: begin u[0] = 1'b0; u[2] = 1'b1; end
            2'd3: begin u[0] = 1'b0; u[2] = 1'b0; end
        endcase
        return u;
    endfunction

    function automatic logic [63:0] byte_merge64(
        input logic [63:0] old_data, input logic [63:0] new_data, input logic [7:0] byte_en
    );
        logic [63:0] m;
        for (int i = 0; i < 8; i++)
            m[i*8 +: 8] = byte_en[i] ? new_data[i*8 +: 8] : old_data[i*8 +: 8];
        return m;
    endfunction

    // =========================================================================
    // SRAM — Flip-Flop arrays (NOT BRAM)
    // =========================================================================
    logic [NUM_WAYS-1:0] tag_valid [NUM_SETS];
    logic [PLRU_BITS-1:0] plru_bits [NUM_SETS];

    // =========================================================================
    // SRAM — Tag / Data BRAM port signals
    // =========================================================================
    localparam int TAG_MEM_W = 1 + TAG_W;  // dirty + tag

    function automatic logic tm_dirty(input logic [TAG_MEM_W-1:0] e);
        return e[TAG_MEM_W-1];
    endfunction
    function automatic logic [TAG_W-1:0] tm_tag(input logic [TAG_MEM_W-1:0] e);
        return e[TAG_W-1:0];
    endfunction
    function automatic logic [TAG_MEM_W-1:0] make_tm_entry(
        input logic d, input logic [TAG_W-1:0] t
    );
        return {d, t};
    endfunction

    // --- Tag BRAM port signals (4 BRAMs, one per way) ---
    logic [INDEX_W-1:0]   tm_rd_addr;
    logic [INDEX_W-1:0]   tm_wr_addr;
    logic [TAG_MEM_W-1:0] tm_wr_data  [NUM_WAYS];
    logic                 tm_wr_en    [NUM_WAYS];
    logic [TAG_MEM_W-1:0] tm_rd_data  [NUM_WAYS];   // BRAM output (registered)

    // --- Data BRAM port signals (4 ways x 4 words = 16 BRAMs) ---
    logic [INDEX_W-1:0]   dm_rd_addr;
    logic [INDEX_W-1:0]   dm_wr_addr;
    logic [63:0]          dm_wr_data  [NUM_WAYS][WORDS_PER_LINE];
    logic                 dm_wr_en    [NUM_WAYS][WORDS_PER_LINE];
    logic [63:0]          dm_rd_data  [NUM_WAYS][WORDS_PER_LINE]; // BRAM output (registered)

    // =========================================================================
    // BRAM Instantiation (generate)
    // =========================================================================
    genvar gw, gwd;

    // 4 tag BRAMs — one per way
    generate
        for (gw = 0; gw < NUM_WAYS; gw++) begin : gen_tag_bram
            f386_bram_sdp #(
                .ADDR_W (INDEX_W),
                .DATA_W (TAG_MEM_W)
            ) u_tag (
                .clk     (clk),
                .wr_addr (tm_wr_addr),
                .wr_data (tm_wr_data[gw]),
                .wr_en   (tm_wr_en[gw]),
                .rd_addr (tm_rd_addr),
                .rd_data (tm_rd_data[gw])
            );
        end
    endgenerate

    // 16 data BRAMs — 4 ways x 4 words
    generate
        for (gw = 0; gw < NUM_WAYS; gw++) begin : gen_data_way
            for (gwd = 0; gwd < WORDS_PER_LINE; gwd++) begin : gen_data_word
                f386_bram_sdp #(
                    .ADDR_W (INDEX_W),
                    .DATA_W (64)
                ) u_data (
                    .clk     (clk),
                    .wr_addr (dm_wr_addr),
                    .wr_data (dm_wr_data[gw][gwd]),
                    .wr_en   (dm_wr_en[gw][gwd]),
                    .rd_addr (dm_rd_addr),
                    .rd_data (dm_rd_data[gw][gwd])
                );
            end
        end
    endgenerate

    // =========================================================================
    // Source Selection
    // =========================================================================
    typedef enum logic [1:0] {
        SRC_NONE   = 2'd0, SRC_IFETCH = 2'd1,
        SRC_DATA   = 2'd2, SRC_PT     = 2'd3
    } arb_source_t;

    // =========================================================================
    // MSHR State Machine
    // =========================================================================
    typedef enum logic [3:0] {
        MH_FREE         = 4'd0,
        MH_EVICT_PEND   = 4'd1,   // Waiting for main FSM to read victim from SRAM
        MH_WB_REQ       = 4'd2,   // Ready to issue dirty writeback to DDRAM
        MH_WB_BURST     = 4'd3,   // WB burst in progress
        MH_FILL_REQ     = 4'd4,   // Ready to issue fill read from DDRAM
        MH_FILL_BURST   = 4'd5,   // Fill burst in progress (waiting for data)
        MH_INSTALL_PEND = 4'd6,   // Waiting for main FSM to install fill to SRAM
        MH_COMPLETE     = 4'd7    // Response ready to deliver
    } mh_state_t;

    // Per-MSHR source tracking (v2.3: non-blocking ifetch/PT)
    typedef enum logic [1:0] {
        MH_SRC_DATA   = 2'd0,
        MH_SRC_IFETCH = 2'd1,
        MH_SRC_PT     = 2'd2
    } mh_source_t;

    // Per-MSHR state
    mh_state_t                         mh_state       [NUM_MSHR];
    mh_source_t                        mh_source      [NUM_MSHR];
    logic [TAG_W-1:0]                  mh_tag         [NUM_MSHR];
    logic [INDEX_W-1:0]                mh_set_idx     [NUM_MSHR];
    logic [WORD_SEL_W-1:0]             mh_word_ofs    [NUM_MSHR];
    logic [CONF_MEM_REQ_ID_W-1:0]      mh_req_id      [NUM_MSHR];
    logic                              mh_is_write    [NUM_MSHR];
    logic [63:0]                       mh_wdata       [NUM_MSHR];
    logic [7:0]                        mh_byte_en     [NUM_MSHR];
    logic [1:0]                        mh_victim_way  [NUM_MSHR];
    logic                              mh_evict_dirty [NUM_MSHR];
    logic [TAG_W-1:0]                  mh_evict_tag   [NUM_MSHR];

    // Per-MSHR buffers and counters
    logic [63:0]                       mh_evict_buf   [NUM_MSHR][WORDS_PER_LINE];
    logic [63:0]                       mh_fill_buf    [NUM_MSHR][WORDS_PER_LINE];
    logic [1:0]                        mh_evict_cnt   [NUM_MSHR];
    logic [1:0]                        mh_wb_cnt      [NUM_MSHR];
    logic [1:0]                        mh_fill_cnt    [NUM_MSHR];
    logic                              mh_fill_rd_issued [NUM_MSHR];

    // Secondary miss coalescing queues (up to 3 secondaries per MSHR)
    // 2-bit count: 0 = empty, 3 = full. Drain pointer indexes next to deliver.
    localparam int NUM_SEC = 3;
    logic [CONF_MEM_REQ_ID_W-1:0]      mh_sec_id      [NUM_MSHR][NUM_SEC];
    logic [WORD_SEL_W-1:0]             mh_sec_ofs     [NUM_MSHR][NUM_SEC];
    logic [1:0]                        mh_sec_count   [NUM_MSHR];
    logic [1:0]                        mh_sec_drain   [NUM_MSHR]; // Drain pointer

    // =========================================================================
    // Lookup Pipeline States
    // =========================================================================
    typedef enum logic [3:0] {
        LK_IDLE          = 4'd0,
        LK_TAG_RD        = 4'd1,
        LK_TAG_CMP       = 4'd2,
        LK_HIT_RD        = 4'd3,
        LK_HIT_RD2       = 4'd4,
        LK_RESPOND       = 4'd5,
        LK_EVICT_RD      = 4'd6,   // Blocking miss evict (ifetch/PT only)
        LK_WB_BURST      = 4'd7,   // Blocking miss WB (ifetch/PT only)
        LK_FILL_BURST    = 4'd8,   // Blocking miss fill (ifetch/PT only)
        LK_FILL_INSTALL  = 4'd9,   // Blocking miss install (ifetch/PT only)
        LK_UC_ISSUE      = 4'd10,
        LK_UC_WAIT       = 4'd11,
        LK_IFETCH_XLINE  = 4'd12,
        LK_MSHR_EVICT    = 4'd13,  // Servicing MSHR evict read
        LK_MSHR_INST     = 4'd14   // Servicing MSHR fill install
    } lk_state_t;

    lk_state_t lk_state;

    // =========================================================================
    // Pipeline Registers
    // =========================================================================
    arb_source_t arb_source;
    logic [31:0] arb_addr;
    logic [63:0] arb_wdata;
    logic [7:0]  arb_byte_en;
    logic        arb_wr;
    logic        arb_cacheable;
    logic [CONF_MEM_REQ_ID_W-1:0] arb_req_id;

    // tag_rd eliminated — replaced by tm_rd_data (BRAM registered output)
    logic [NUM_WAYS-1:0]  tag_valid_rd;
    logic [63:0]          data_rd_word;

    logic [NUM_WAYS-1:0] hit_vec;
    logic                any_hit;
    logic [1:0]          hit_way;

    // Blocking miss (ifetch/PT) victim tracking
    logic [1:0]       victim_way;
    logic [TAG_W-1:0] evict_tag;
    logic             evict_dirty;
    logic [63:0]      evict_buf [WORDS_PER_LINE];
    logic [1:0]       evict_rd_cnt;
    logic [1:0]       wb_beat_cnt;
    logic [63:0]      fill_buf  [WORDS_PER_LINE];
    logic [1:0]       fill_beat_cnt;
    logic             fill_rd_issued;

    // Ifetch assembly
    logic [63:0] ifetch_word0;
    logic        ifetch_cross_line;
    logic        ifetch_second_pass;

    // MSHR being serviced by main FSM
    logic [MSHR_ID_W-1:0] lk_mshr_id;
    logic [1:0]           lk_mshr_cnt;  // Beat counter for evict/install

    // Response buffer
    logic     rsp_buf_valid;
    mem_rsp_t rsp_buf;

    // DDRAM ownership
    typedef enum logic [2:0] {
        DD_IDLE   = 3'd0,
        DD_LK_WB  = 3'd1,  // Main FSM blocking writeback
        DD_LK_FILL = 3'd2, // Main FSM blocking fill
        DD_LK_UC  = 3'd3,  // Main FSM uncacheable
        DD_MH     = 3'd4   // MSHR owns DDRAM
    } dd_owner_t;
    dd_owner_t            dd_owner;
    logic [MSHR_ID_W-1:0] dd_mshr_id;   // Which MSHR owns DDRAM

    // =========================================================================
    // MSHR Combinational Logic
    // =========================================================================

    // Free MSHR detection (priority encoder)
    logic [MSHR_ID_W-1:0] mshr_free_id;
    logic                  mshr_any_free;
    always_comb begin
        mshr_any_free = 1'b0;
        mshr_free_id  = '0;
        for (int i = NUM_MSHR-1; i >= 0; i--) begin
            if (mh_state[i] == MH_FREE) begin
                mshr_any_free = 1'b1;
                mshr_free_id  = MSHR_ID_W'(i);
            end
        end
    end

    // MSHR conflict: new request matches set+tag of active MSHR
    wire [31:0] data_req_addr_a20 = apply_a20(data_req.addr, a20_gate);
    logic                  mshr_conflict;        // Any matching MSHR exists (stalls normal path)
    logic                  mshr_sec_room;         // Matching MSHR has secondary queue room
    logic [MSHR_ID_W-1:0]  mshr_conflict_id;     // Which MSHR matches
    always_comb begin
        mshr_conflict    = 1'b0;
        mshr_sec_room    = 1'b0;
        mshr_conflict_id = '0;
        for (int i = 0; i < NUM_MSHR; i++) begin
            if (mh_state[i] != MH_FREE &&
                mh_set_idx[i] == addr_index(data_req_addr_a20) &&
                mh_tag[i]     == addr_tag(data_req_addr_a20)) begin
                mshr_conflict    = 1'b1;
                mshr_conflict_id = MSHR_ID_W'(i);
                // Secondary queue has room AND MSHR is not already draining
                if (mh_sec_count[i] < 2'd3 && mh_state[i] != MH_COMPLETE)
                    mshr_sec_room = 1'b1;
            end
        end
    end

    // MSHR needing install (oldest first = lowest ID)
    logic [MSHR_ID_W-1:0] mshr_inst_id;
    logic                  mshr_inst_pend;
    always_comb begin
        mshr_inst_pend = 1'b0;
        mshr_inst_id   = '0;
        for (int i = NUM_MSHR-1; i >= 0; i--) begin
            if (mh_state[i] == MH_INSTALL_PEND) begin
                mshr_inst_pend = 1'b1;
                mshr_inst_id   = MSHR_ID_W'(i);
            end
        end
    end

    // MSHR needing evict read
    logic [MSHR_ID_W-1:0] mshr_evict_id;
    logic                  mshr_evict_pend;
    always_comb begin
        mshr_evict_pend = 1'b0;
        mshr_evict_id   = '0;
        for (int i = NUM_MSHR-1; i >= 0; i--) begin
            if (mh_state[i] == MH_EVICT_PEND) begin
                mshr_evict_pend = 1'b1;
                mshr_evict_id   = MSHR_ID_W'(i);
            end
        end
    end

    // MSHR wanting DDRAM (WB_REQ or FILL_REQ)
    logic [MSHR_ID_W-1:0] mshr_ddram_req_id;
    logic                  mshr_ddram_req;
    always_comb begin
        mshr_ddram_req = 1'b0;
        mshr_ddram_req_id = '0;
        for (int i = NUM_MSHR-1; i >= 0; i--) begin
            if (mh_state[i] == MH_WB_REQ || mh_state[i] == MH_FILL_REQ) begin
                mshr_ddram_req     = 1'b1;
                mshr_ddram_req_id  = MSHR_ID_W'(i);
            end
        end
    end

    // MSHR completion: any MSHR in MH_COMPLETE (split by source)
    logic [MSHR_ID_W-1:0] mshr_complete_id;
    logic                  mshr_any_complete;      // Any data-source MSHR ready
    logic [MSHR_ID_W-1:0] mshr_nb_complete_id;
    logic                  mshr_nb_ifetch_ready;   // Ifetch-source MSHR ready
    logic                  mshr_nb_pt_ready;       // PT-source MSHR ready
    always_comb begin
        mshr_any_complete   = 1'b0;
        mshr_complete_id    = '0;
        mshr_nb_ifetch_ready = 1'b0;
        mshr_nb_pt_ready     = 1'b0;
        mshr_nb_complete_id  = '0;
        for (int i = NUM_MSHR-1; i >= 0; i--) begin
            if (mh_state[i] == MH_COMPLETE) begin
                if (mh_source[i] == MH_SRC_DATA) begin
                    mshr_any_complete = 1'b1;
                    mshr_complete_id  = MSHR_ID_W'(i);
                end else if (mh_source[i] == MH_SRC_IFETCH) begin
                    mshr_nb_ifetch_ready = 1'b1;
                    mshr_nb_complete_id  = MSHR_ID_W'(i);
                end else if (mh_source[i] == MH_SRC_PT) begin
                    mshr_nb_pt_ready     = 1'b1;
                    mshr_nb_complete_id  = MSHR_ID_W'(i);
                end
            end
        end
    end

    // Credit-based interleaving: after 4 consecutive lookup cycles, yield to MSHR
    logic [2:0] lk_credit;
    wire lk_needs_sram = (lk_state inside {LK_TAG_RD, LK_TAG_CMP, LK_HIT_RD, LK_HIT_RD2});
    wire mshr_needs_sram = mshr_inst_pend || mshr_evict_pend;
    wire mshr_starved = mshr_needs_sram && (lk_credit == 0);

    // =========================================================================
    // Request Acceptance
    // =========================================================================
    wire lk_idle = (lk_state == LK_IDLE);
    // data_req_ready must match exactly the conditions under which LK_IDLE
    // will actually latch the data request. PT and MSHR service branches
    // take priority in LK_IDLE, so ready must be low when those would fire.
    wire data_req_base_ok = lk_idle && !pt_req && !rsp_buf_valid
                            && !mshr_inst_pend && !mshr_evict_pend;
    // Uncacheable (MMIO) requests bypass MSHR checks — they go to LK_UC_ISSUE,
    // never allocate an MSHR, and don't conflict with in-flight cache lines.
    wire data_req_mshr_ok = mshr_any_free && !mshr_conflict && !mshr_starved;
    // Coalescing path: conflict exists but secondary slot available.
    // Coalesced requests bypass the lookup pipeline entirely (no MSHR alloc,
    // no SRAM access), so they only need lk_idle + base conditions.
    // Only loads can coalesce — stores need write-allocate merge at install.
    wire data_req_coalesce_ok = mshr_conflict && mshr_sec_room
                                && data_req.cacheable
                                && (data_req.op == MEM_OP_LD);
    assign data_req_ready = data_req_base_ok &&
                            (data_req_mshr_ok || data_req_coalesce_ok
                             || !data_req.cacheable);

    // =========================================================================
    // Response Delivery Mux
    // =========================================================================
    // Two response sources: lookup pipeline hit (rsp_buf) and MSHR completion.
    // Alternating priority to prevent starvation.
    logic rsp_last_was_lk;

    wire lk_rsp_pending   = rsp_buf_valid;
    wire mshr_rsp_pending = mshr_any_complete;

    // Lookup wins if: last was MSHR, or no MSHR ready
    wire lk_rsp_wins  = lk_rsp_pending && (!mshr_rsp_pending || !rsp_last_was_lk);
    wire mshr_rsp_wins = mshr_rsp_pending && !lk_rsp_wins;

    // Form the response output
    always_comb begin
        if (lk_rsp_wins) begin
            data_rsp_valid = 1'b1;
            data_rsp       = rsp_buf;
        end else if (mshr_rsp_wins) begin
            data_rsp_valid          = 1'b1;
            data_rsp.id             = mh_req_id[mshr_complete_id];
            data_rsp.rdata          = {64'd0, mh_fill_buf[mshr_complete_id][mh_word_ofs[mshr_complete_id]]};
            data_rsp.beat_idx       = 3'd0;
            data_rsp.last           = 1'b1;
            data_rsp.resp           = MEM_RESP_OK;
        end else begin
            data_rsp_valid = 1'b0;
            data_rsp       = '0;
        end
    end

    // =========================================================================
    // Tag Compare (combinational) — uses BRAM output directly
    // =========================================================================
    always_comb begin
        any_hit = 1'b0;
        hit_way = 2'd0;
        for (int w = 0; w < NUM_WAYS; w++)
            hit_vec[w] = tag_valid_rd[w] && (tm_tag(tm_rd_data[w]) == addr_tag(arb_addr));
        for (int w = 0; w < NUM_WAYS; w++) begin
            if (hit_vec[w]) begin
                any_hit = 1'b1;
                hit_way = 2'(w);
            end
        end
    end

    // =========================================================================
    // Performance Counters (sim-visible)
    // =========================================================================
    logic [31:0] ctr_mshr_alloc;
    logic [31:0] ctr_mshr_stall_cyc;
    logic [31:0] ctr_mshr_all_busy;     // P3.MSHR: cycles with all MSHRs active
    logic [31:0] ctr_hit_during_miss;
    logic [31:0] ctr_ddram_wb_bursts;
    logic [31:0] ctr_ddram_fill_bursts;
    logic [31:0] ctr_mshr_coalesce;

    // Are any MSHRs active? (for hit-during-miss counting)
    logic any_mshr_active;
    always_comb begin
        any_mshr_active = 1'b0;
        for (int i = 0; i < NUM_MSHR; i++)
            if (mh_state[i] != MH_FREE) any_mshr_active = 1'b1;
    end

    // =========================================================================
    // BRAM Read Address Logic (combinational)
    // =========================================================================
    // The read address is presented every cycle. The BRAM output reflects the
    // address from the PREVIOUS cycle (1-cycle registered read latency).
    //
    // Address schedule:
    //   LK_TAG_RD / TAG_CMP / HIT_RD / etc  →  addr_index(arb_addr)
    //   LK_MSHR_EVICT / LK_MSHR_INST        →  mh_set_idx[lk_mshr_id]
    //   LK_IDLE (→ MSHR_EVICT)               →  mh_set_idx[mshr_evict_id]
    //   LK_IDLE (→ MSHR_INST)                →  mh_set_idx[mshr_inst_id]
    //
    // LK_IDLE pre-presents the MSHR set index one cycle early so that
    // the BRAM output is valid on the first cycle of MSHR_EVICT/MSHR_INST.
    // For TAG_RD transitions, the address is presented in TAG_RD itself
    // (arb_addr is registered at the IDLE→TAG_RD edge), and the output
    // is consumed in TAG_CMP — so no pre-presentation is needed.
    always_comb begin
        case (lk_state)
            LK_IDLE: begin
                // Pre-present MSHR set index when about to transition
                // to an MSHR service state. Priority matches LK_IDLE FSM.
                if (!pt_req && mshr_inst_pend) begin
                    tm_rd_addr = mh_set_idx[mshr_inst_id];
                    dm_rd_addr = mh_set_idx[mshr_inst_id];
                end else if (!pt_req && !mshr_inst_pend && mshr_evict_pend) begin
                    tm_rd_addr = mh_set_idx[mshr_evict_id];
                    dm_rd_addr = mh_set_idx[mshr_evict_id];
                end else begin
                    tm_rd_addr = addr_index(arb_addr);
                    dm_rd_addr = addr_index(arb_addr);
                end
            end
            LK_MSHR_EVICT,
            LK_MSHR_INST: begin
                tm_rd_addr = mh_set_idx[lk_mshr_id];
                dm_rd_addr = mh_set_idx[lk_mshr_id];
            end
            default: begin
                tm_rd_addr = addr_index(arb_addr);
                dm_rd_addr = addr_index(arb_addr);
            end
        endcase
    end

    // =========================================================================
    // BRAM Write Address + Enable + Data Logic (combinational)
    // =========================================================================
    // Decodes the FSM state to produce BRAM write controls.  Exactly mirrors
    // the original always_ff assignments to data_mem/tag_mem, but expressed
    // as combinational port signals consumed by the BRAM instances.
    always_comb begin
        // Defaults: no writes, address follows read address
        tm_wr_addr = addr_index(arb_addr);
        dm_wr_addr = addr_index(arb_addr);
        for (int w = 0; w < NUM_WAYS; w++) begin
            tm_wr_en[w]   = 1'b0;
            tm_wr_data[w] = '0;
            for (int wd = 0; wd < WORDS_PER_LINE; wd++) begin
                dm_wr_en[w][wd]   = 1'b0;
                dm_wr_data[w][wd] = 64'd0;
            end
        end

        case (lk_state)
            // -----------------------------------------------------------
            // HIT_RD: hit-store writes (SRC_DATA or SRC_PT)
            // -----------------------------------------------------------
            LK_HIT_RD: begin
                if (arb_wr && (arb_source == SRC_DATA || arb_source == SRC_PT)) begin
                    // Data write: merged word
                    dm_wr_en[hit_way][addr_word(arb_addr)]   = 1'b1;
                    dm_wr_data[hit_way][addr_word(arb_addr)] =
                        byte_merge64(data_rd_word, arb_wdata, arb_byte_en);
                    // Tag write: mark dirty
                    tm_wr_en[hit_way]   = 1'b1;
                    tm_wr_data[hit_way] = make_tm_entry(1'b1, addr_tag(arb_addr));
                end
            end

            // -----------------------------------------------------------
            // FILL_INSTALL: blocking miss (ifetch/PT) fill install
            // -----------------------------------------------------------
            LK_FILL_INSTALL: begin
                // Write all 4 fill words into victim way
                for (int wd = 0; wd < WORDS_PER_LINE; wd++) begin
                    dm_wr_en[victim_way][wd]   = 1'b1;
                    dm_wr_data[victim_way][wd] = fill_buf[wd];
                end

                if (arb_wr && arb_source == SRC_PT) begin
                    // Write-allocate merge: overwrite one word with store data
                    dm_wr_data[victim_way][addr_word(arb_addr)] =
                        byte_merge64(fill_buf[addr_word(arb_addr)], arb_wdata, arb_byte_en);
                    tm_wr_en[victim_way]   = 1'b1;
                    tm_wr_data[victim_way] = make_tm_entry(1'b1, addr_tag(arb_addr));
                end else begin
                    tm_wr_en[victim_way]   = 1'b1;
                    tm_wr_data[victim_way] = make_tm_entry(1'b0, addr_tag(arb_addr));
                end
            end

            // -----------------------------------------------------------
            // MSHR_INST: MSHR fill install
            // -----------------------------------------------------------
            LK_MSHR_INST: begin
                tm_wr_addr = mh_set_idx[lk_mshr_id];
                dm_wr_addr = mh_set_idx[lk_mshr_id];

                // Write all 4 fill words into victim way
                for (int wd = 0; wd < WORDS_PER_LINE; wd++) begin
                    dm_wr_en[mh_victim_way[lk_mshr_id]][wd]   = 1'b1;
                    dm_wr_data[mh_victim_way[lk_mshr_id]][wd] = mh_fill_buf[lk_mshr_id][wd];
                end

                if (mh_is_write[lk_mshr_id]) begin
                    // Write-allocate merge: overwrite one word with store data
                    dm_wr_data[mh_victim_way[lk_mshr_id]][mh_word_ofs[lk_mshr_id]] =
                        byte_merge64(
                            mh_fill_buf[lk_mshr_id][mh_word_ofs[lk_mshr_id]],
                            mh_wdata[lk_mshr_id],
                            mh_byte_en[lk_mshr_id]
                        );
                    tm_wr_en[mh_victim_way[lk_mshr_id]]   = 1'b1;
                    tm_wr_data[mh_victim_way[lk_mshr_id]] = make_tm_entry(1'b1, mh_tag[lk_mshr_id]);
                end else begin
                    tm_wr_en[mh_victim_way[lk_mshr_id]]   = 1'b1;
                    tm_wr_data[mh_victim_way[lk_mshr_id]] = make_tm_entry(1'b0, mh_tag[lk_mshr_id]);
                end
            end

            default: ;
        endcase
    end

    // =========================================================================
    // Main FSM + MSHR State Machine (single always_ff for Quartus)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lk_state       <= LK_IDLE;
            ifetch_valid   <= 1'b0;
            ifetch_data    <= 128'd0;
            pt_ack         <= 1'b0;
            pt_rdata       <= 32'd0;
            ddram_rd       <= 1'b0;
            ddram_we       <= 1'b0;
            ddram_addr     <= 29'd0;
            ddram_burstcnt <= 8'd0;
            ddram_din      <= 64'd0;
            ddram_be       <= 8'd0;
            arb_source     <= SRC_NONE;
            arb_req_id     <= '0;
            ifetch_second_pass <= 1'b0;
            wb_beat_cnt    <= 2'd0;
            fill_beat_cnt  <= 2'd0;
            fill_rd_issued <= 1'b0;
            evict_rd_cnt   <= 2'd0;
            rsp_buf_valid  <= 1'b0;
            rsp_buf        <= '0;
            dd_owner       <= DD_IDLE;
            dd_mshr_id     <= '0;
            lk_mshr_id     <= '0;
            lk_mshr_cnt    <= 2'd0;
            lk_credit      <= 3'd4;
            rsp_last_was_lk <= 1'b0;
            ctr_mshr_alloc      <= 32'd0;
            ctr_mshr_stall_cyc  <= 32'd0;
            ctr_mshr_all_busy   <= 32'd0;
            ctr_hit_during_miss <= 32'd0;
            ctr_ddram_wb_bursts <= 32'd0;
            ctr_ddram_fill_bursts <= 32'd0;
            ctr_mshr_coalesce   <= 32'd0;

            for (int s = 0; s < NUM_SETS; s++) begin
                tag_valid[s] <= '0;
                plru_bits[s] <= '0;
            end
            for (int m = 0; m < NUM_MSHR; m++) begin
                mh_state[m]          <= MH_FREE;
                mh_fill_rd_issued[m] <= 1'b0;
                mh_sec_count[m]      <= 2'd0;
                mh_sec_drain[m]      <= 2'd0;
            end
        end else begin
            // Pulse signals
            ifetch_valid <= 1'b0;
            pt_ack       <= 1'b0;
            ddram_rd     <= 1'b0;
            ddram_we     <= 1'b0;

            // Response consumed by upstream
            if (lk_rsp_wins && data_rsp_ready) begin
                rsp_buf_valid   <= 1'b0;
                rsp_last_was_lk <= 1'b1;
            end
            if (mshr_rsp_wins && data_rsp_ready) begin
                if (mh_sec_count[mshr_complete_id] != 2'd0) begin
                    // Drain next secondary: swap its ID/offset into primary fields
                    mh_req_id  [mshr_complete_id] <= mh_sec_id [mshr_complete_id][mh_sec_drain[mshr_complete_id]];
                    mh_word_ofs[mshr_complete_id] <= mh_sec_ofs[mshr_complete_id][mh_sec_drain[mshr_complete_id]];
                    mh_sec_drain[mshr_complete_id] <= mh_sec_drain[mshr_complete_id] + 2'd1;
                    mh_sec_count[mshr_complete_id] <= mh_sec_count[mshr_complete_id] - 2'd1;
                    // Stay in MH_COMPLETE — response mux will pick up new ID/offset next cycle
                end else begin
                    mh_state[mshr_complete_id] <= MH_FREE;
                end
                rsp_last_was_lk <= 1'b0;
            end

            // v2.3: Non-blocking ifetch/PT completion delivery
            // Self-consuming (no upstream handshake — pulse for 1 cycle)
            if (mshr_nb_ifetch_ready) begin
                ifetch_data  <= {mh_fill_buf[mshr_nb_complete_id][mh_word_ofs[mshr_nb_complete_id] + 2'd1],
                                 mh_fill_buf[mshr_nb_complete_id][mh_word_ofs[mshr_nb_complete_id]]};
                ifetch_valid <= 1'b1;
                mh_state[mshr_nb_complete_id] <= MH_FREE;
            end
            if (mshr_nb_pt_ready && !mshr_nb_ifetch_ready) begin
                pt_rdata <= mh_fill_buf[mshr_nb_complete_id][mh_word_ofs[mshr_nb_complete_id]][31:0];
                pt_ack   <= 1'b1;
                mh_state[mshr_nb_complete_id] <= MH_FREE;
            end

            // Credit management for SRAM interleaving
            if (lk_needs_sram && !mshr_starved) begin
                if (lk_credit != 0)
                    lk_credit <= lk_credit - 3'd1;
            end else if (lk_state inside {LK_MSHR_EVICT, LK_MSHR_INST}) begin
                lk_credit <= 3'd4;  // Reset after yielding to MSHR
            end else if (lk_state == LK_IDLE) begin
                lk_credit <= 3'd4;
            end

            // Perf: stall cycles (data_req_valid but not accepted)
            if (data_req_valid && !data_req_ready && lk_idle)
                ctr_mshr_stall_cyc <= ctr_mshr_stall_cyc + 32'd1;
            // P3.MSHR: all-busy utilization
            if (!mshr_any_free && any_mshr_active)
                ctr_mshr_all_busy <= ctr_mshr_all_busy + 32'd1;

            // ===========================================================
            // Lookup Pipeline FSM
            // ===========================================================
            case (lk_state)

                // -------------------------------------------------------
                // IDLE: Arbitrate among PT, MSHR service, data, ifetch
                // -------------------------------------------------------
                LK_IDLE: begin
                    if (pt_req) begin
                        arb_source    <= SRC_PT;
                        arb_addr      <= apply_a20(pt_addr, a20_gate);
                        arb_wdata     <= {32'd0, pt_wdata};
                        arb_byte_en   <= 8'h0F;
                        arb_wr        <= pt_wr;
                        arb_cacheable <= 1'b1;
                        lk_state      <= LK_TAG_RD;
                    end else if (mshr_inst_pend) begin
                        // Service MSHR install request (higher priority than data)
                        lk_mshr_id  <= mshr_inst_id;
                        lk_mshr_cnt <= 2'd0;
                        lk_state    <= LK_MSHR_INST;
                    end else if (mshr_evict_pend) begin
                        // Service MSHR evict read
                        lk_mshr_id  <= mshr_evict_id;
                        lk_mshr_cnt <= 2'd0;
                        lk_state    <= LK_MSHR_EVICT;
                    end else if (data_req_valid && !rsp_buf_valid && data_req_coalesce_ok) begin
                        // Secondary miss coalescing: enqueue into matching MSHR,
                        // no SRAM access needed, stay in IDLE.
                        mh_sec_id [mshr_conflict_id][mh_sec_count[mshr_conflict_id]] <= data_req.id;
                        mh_sec_ofs[mshr_conflict_id][mh_sec_count[mshr_conflict_id]] <= addr_word(data_req_addr_a20);
                        mh_sec_count[mshr_conflict_id] <= mh_sec_count[mshr_conflict_id] + 2'd1;
                        ctr_mshr_coalesce <= ctr_mshr_coalesce + 32'd1;
                        // lk_state stays LK_IDLE
                    end else if (data_req_valid && !rsp_buf_valid
                                 && (data_req_mshr_ok || !data_req.cacheable)) begin
                        arb_source    <= SRC_DATA;
                        arb_addr      <= data_req_addr_a20;
                        arb_wdata     <= data_req.wdata;
                        arb_byte_en   <= data_req.byte_en;
                        arb_wr        <= (data_req.op == MEM_OP_ST);
                        arb_cacheable <= data_req.cacheable;
                        arb_req_id    <= data_req.id;
                        if (!data_req.cacheable)
                            lk_state <= LK_UC_ISSUE;
                        else
                            lk_state <= LK_TAG_RD;
                    end else if (ifetch_req) begin
                        arb_source    <= SRC_IFETCH;
                        arb_addr      <= apply_a20(ifetch_addr, a20_gate);
                        arb_wdata     <= 64'd0;
                        arb_byte_en   <= 8'hFF;
                        arb_wr        <= 1'b0;
                        arb_cacheable <= 1'b1;
                        ifetch_cross_line  <= (ifetch_addr[4:3] == 2'b11);
                        ifetch_second_pass <= 1'b0;
                        lk_state      <= LK_TAG_RD;
                    end
                end

                // -------------------------------------------------------
                // TAG_RD: Wait for BRAM read (1-cycle M10K latency).
                //   Read address was set combinationally (tm_rd_addr/dm_rd_addr).
                //   BRAM outputs (tm_rd_data, dm_rd_data) will be valid
                //   at the start of the next cycle (TAG_CMP).
                // -------------------------------------------------------
                LK_TAG_RD: begin
                    tag_valid_rd <= tag_valid[addr_index(arb_addr)];
                    lk_state <= LK_TAG_CMP;
                end

                // -------------------------------------------------------
                // TAG_CMP: Hit/miss decision
                //   Tag BRAM outputs (tm_rd_data) are valid this cycle.
                //   Data BRAM outputs (dm_rd_data) are valid this cycle.
                // -------------------------------------------------------
                LK_TAG_CMP: begin
                    if (any_hit) begin
                        // --- HIT ---
                        plru_bits[addr_index(arb_addr)] <=
                            plru_update(plru_bits[addr_index(arb_addr)], hit_way);

                        // Perf: hit during miss
                        if (any_mshr_active && arb_source == SRC_DATA)
                            ctr_hit_during_miss <= ctr_hit_during_miss + 32'd1;

                        case (arb_source)
                            SRC_DATA: begin
                                data_rd_word <= dm_rd_data[hit_way][addr_word(arb_addr)];
                                lk_state <= arb_wr ? LK_HIT_RD : LK_RESPOND;
                            end
                            SRC_PT: begin
                                data_rd_word <= dm_rd_data[hit_way][addr_word(arb_addr)];
                                lk_state <= arb_wr ? LK_HIT_RD : LK_RESPOND;
                            end
                            SRC_IFETCH: begin
                                data_rd_word <= dm_rd_data[hit_way][addr_word(arb_addr)];
                                lk_state <= LK_HIT_RD;
                            end
                            default: lk_state <= LK_IDLE;
                        endcase
                    end else begin
                        // --- MISS ---
                        // v2.3: MSHR allocation for data, ifetch (non-cross-line), and PT reads
                        // Falls back to blocking path when no MSHR available, or for
                        // cross-line ifetch / PT writes, or MSHR set+tag conflict.
                        // Check if any active MSHR already owns this cache line
                        // (prevents duplicate set+tag allocation for ifetch/PT).
                        automatic logic arb_mshr_conflict = 1'b0;
                        for (int i = 0; i < NUM_MSHR; i++) begin
                            if (mh_state[i] != MH_FREE &&
                                mh_set_idx[i] == addr_index(arb_addr) &&
                                mh_tag[i]     == addr_tag(arb_addr))
                                arb_mshr_conflict = 1'b1;
                        end

                        if (arb_source == SRC_DATA ||
                            (arb_source == SRC_IFETCH && !ifetch_cross_line && mshr_any_free && !arb_mshr_conflict) ||
                            (arb_source == SRC_PT && !arb_wr && mshr_any_free && !arb_mshr_conflict)) begin
                            // Allocate MSHR (non-blocking)
                            mh_state[mshr_free_id]       <= mh_evict_dirty_tmp ? MH_EVICT_PEND : MH_FILL_REQ;
                            mh_source[mshr_free_id]      <= (arb_source == SRC_IFETCH) ? MH_SRC_IFETCH :
                                                            (arb_source == SRC_PT)     ? MH_SRC_PT     :
                                                                                         MH_SRC_DATA;
                            mh_tag[mshr_free_id]         <= addr_tag(arb_addr);
                            mh_set_idx[mshr_free_id]     <= addr_index(arb_addr);
                            mh_word_ofs[mshr_free_id]    <= addr_word(arb_addr);
                            mh_req_id[mshr_free_id]      <= arb_req_id;
                            mh_is_write[mshr_free_id]    <= arb_wr;
                            mh_wdata[mshr_free_id]       <= arb_wdata;
                            mh_byte_en[mshr_free_id]     <= arb_byte_en;
                            mh_victim_way[mshr_free_id]  <= mh_victim_tmp;
                            mh_evict_dirty[mshr_free_id] <= mh_evict_dirty_tmp;
                            mh_evict_tag[mshr_free_id]   <= tm_tag(tm_rd_data[mh_victim_tmp]);
                            mh_evict_cnt[mshr_free_id]   <= 2'd0;
                            mh_wb_cnt[mshr_free_id]      <= 2'd0;
                            mh_fill_cnt[mshr_free_id]    <= 2'd0;
                            mh_fill_rd_issued[mshr_free_id] <= 1'b0;
                            mh_sec_count[mshr_free_id]   <= 2'd0;
                            mh_sec_drain[mshr_free_id]   <= 2'd0;

                            ctr_mshr_alloc <= ctr_mshr_alloc + 32'd1;
                            lk_state <= LK_IDLE;  // Pipeline freed!
                        end else begin
                            // Blocking path fallback: cross-line ifetch, PT write,
                            // or no MSHR free for ifetch/PT.
                            victim_way  <= select_victim(tag_valid_rd, plru_bits[addr_index(arb_addr)]);
                            evict_tag   <= tm_tag(tm_rd_data[select_victim(tag_valid_rd, plru_bits[addr_index(arb_addr)])]);
                            evict_dirty <= tag_valid_rd[select_victim(tag_valid_rd, plru_bits[addr_index(arb_addr)])] &&
                                           tm_dirty(tm_rd_data[select_victim(tag_valid_rd, plru_bits[addr_index(arb_addr)])]);
                            evict_rd_cnt <= 2'd0;
                            lk_state <= LK_EVICT_RD;
                        end
                    end
                end

                // -------------------------------------------------------
                // HIT_RD: Process hit (SRAM data available in data_rd_word,
                //         BRAM outputs still valid for same set).
                //   Writes are driven by the always_comb BRAM write block.
                // -------------------------------------------------------
                LK_HIT_RD: begin
                    case (arb_source)
                        SRC_DATA: begin
                            if (arb_wr) begin
                                // Data+tag BRAM writes driven by always_comb block
                                rsp_buf_valid    <= 1'b1;
                                rsp_buf.id       <= arb_req_id;
                                rsp_buf.rdata    <= 128'd0;
                                rsp_buf.beat_idx <= 3'd0;
                                rsp_buf.last     <= 1'b1;
                                rsp_buf.resp     <= MEM_RESP_OK;
                                lk_state         <= LK_IDLE;
                            end
                        end
                        SRC_PT: begin
                            if (arb_wr) begin
                                // Data+tag BRAM writes driven by always_comb block
                                pt_ack   <= 1'b1;
                                lk_state <= LK_IDLE;
                            end
                        end
                        SRC_IFETCH: begin
                            if (ifetch_second_pass) begin
                                lk_state <= LK_HIT_RD2;
                            end else begin
                                ifetch_word0 <= data_rd_word;
                                if (ifetch_cross_line) begin
                                    lk_state <= LK_IFETCH_XLINE;
                                end else begin
                                    // All data BRAM outputs still valid (same set from TAG_RD).
                                    // Read word+1 from the BRAM output directly.
                                    data_rd_word <= dm_rd_data[hit_way][addr_word(arb_addr) + 2'd1];
                                    lk_state <= LK_HIT_RD2;
                                end
                            end
                        end
                        default: lk_state <= LK_IDLE;
                    endcase
                end

                LK_HIT_RD2: begin
                    ifetch_data  <= {data_rd_word, ifetch_word0};
                    ifetch_valid <= 1'b1;
                    lk_state     <= LK_IDLE;
                end

                LK_IFETCH_XLINE: begin
                    arb_addr <= {arb_addr[31:OFFSET_W] + 1'b1, {OFFSET_W{1'b0}}};
                    ifetch_second_pass <= 1'b1;
                    lk_state <= LK_TAG_RD;
                end

                // -------------------------------------------------------
                // RESPOND: Deliver read data
                // -------------------------------------------------------
                LK_RESPOND: begin
                    case (arb_source)
                        SRC_DATA: begin
                            rsp_buf_valid    <= 1'b1;
                            rsp_buf.id       <= arb_req_id;
                            rsp_buf.rdata    <= {64'd0, data_rd_word};
                            rsp_buf.beat_idx <= 3'd0;
                            rsp_buf.last     <= 1'b1;
                            rsp_buf.resp     <= MEM_RESP_OK;
                        end
                        SRC_PT: begin
                            pt_rdata <= data_rd_word[31:0];
                            pt_ack   <= 1'b1;
                        end
                        default: ;
                    endcase
                    lk_state <= LK_IDLE;
                end

                // -------------------------------------------------------
                // Blocking miss path (ifetch/PT only)
                // -------------------------------------------------------
                LK_EVICT_RD: begin
                    // BRAM outputs are valid for addr_index(arb_addr) — all
                    // 4 words of victim_way are available every cycle.
                    evict_buf[evict_rd_cnt] <= dm_rd_data[victim_way][evict_rd_cnt];
                    if (evict_rd_cnt == 2'd3) begin
                        if (evict_dirty) begin
                            wb_beat_cnt <= 2'd0;
                            lk_state <= LK_WB_BURST;
                        end else begin
                            fill_beat_cnt  <= 2'd0;
                            fill_rd_issued <= 1'b0;
                            lk_state <= LK_FILL_BURST;
                        end
                    end else
                        evict_rd_cnt <= evict_rd_cnt + 2'd1;
                end

                LK_WB_BURST: begin
                    if (!ddram_busy && (dd_owner == DD_IDLE || dd_owner == DD_LK_WB)) begin
                        dd_owner       <= DD_LK_WB;
                        ddram_addr     <= {evict_tag, addr_index(arb_addr), 2'b00};
                        ddram_burstcnt <= 8'd4;
                        ddram_din      <= evict_buf[wb_beat_cnt];
                        ddram_be       <= 8'hFF;
                        ddram_we       <= 1'b1;
                        if (wb_beat_cnt == 2'd3) begin
                            fill_beat_cnt  <= 2'd0;
                            fill_rd_issued <= 1'b0;
                            lk_state <= LK_FILL_BURST;
                            dd_owner <= DD_IDLE;
                            ctr_ddram_wb_bursts <= ctr_ddram_wb_bursts + 32'd1;
                        end else
                            wb_beat_cnt <= wb_beat_cnt + 2'd1;
                    end
                end

                LK_FILL_BURST: begin
                    if (!fill_rd_issued && !ddram_busy && dd_owner == DD_IDLE) begin
                        dd_owner       <= DD_LK_FILL;
                        ddram_addr     <= arb_addr[31:3] & ~29'd3;
                        ddram_burstcnt <= 8'd4;
                        ddram_rd       <= 1'b1;
                        fill_rd_issued <= 1'b1;
                        ctr_ddram_fill_bursts <= ctr_ddram_fill_bursts + 32'd1;
                    end
                    if (ddram_dout_ready && dd_owner == DD_LK_FILL) begin
                        fill_buf[fill_beat_cnt] <= ddram_dout;
                        if (fill_beat_cnt == 2'd3) begin
                            lk_state <= LK_FILL_INSTALL;
                            dd_owner <= DD_IDLE;
                        end else
                            fill_beat_cnt <= fill_beat_cnt + 2'd1;
                    end
                end

                LK_FILL_INSTALL: begin
                    // Data+tag BRAM writes driven by always_comb block
                    tag_valid[addr_index(arb_addr)][victim_way] <= 1'b1;

                    if (arb_wr && arb_source == SRC_PT) begin
                        pt_ack <= 1'b1;
                    end else begin
                        data_rd_word <= fill_buf[addr_word(arb_addr)];
                    end

                    plru_bits[addr_index(arb_addr)] <=
                        plru_update(plru_bits[addr_index(arb_addr)], victim_way);

                    if (arb_wr)
                        lk_state <= LK_IDLE;
                    else if (arb_source == SRC_IFETCH)
                        lk_state <= LK_TAG_RD;  // Re-lookup installed line
                    else
                        lk_state <= LK_RESPOND;
                end

                // -------------------------------------------------------
                // Uncacheable bypass
                // -------------------------------------------------------
                LK_UC_ISSUE: begin
                    if (!ddram_busy && dd_owner == DD_IDLE) begin
                        dd_owner       <= DD_LK_UC;
                        ddram_addr     <= arb_addr[31:3];
                        ddram_burstcnt <= 8'd1;
                        if (arb_wr) begin
                            ddram_din <= arb_wdata;
                            ddram_be  <= arb_byte_en;
                            ddram_we  <= 1'b1;
                            rsp_buf_valid    <= 1'b1;
                            rsp_buf.id       <= arb_req_id;
                            rsp_buf.rdata    <= 128'd0;
                            rsp_buf.beat_idx <= 3'd0;
                            rsp_buf.last     <= 1'b1;
                            rsp_buf.resp     <= MEM_RESP_OK;
                            dd_owner  <= DD_IDLE;
                            lk_state  <= LK_IDLE;
                        end else begin
                            ddram_rd <= 1'b1;
                            lk_state <= LK_UC_WAIT;
                        end
                    end
                end

                LK_UC_WAIT: begin
                    if (ddram_dout_ready) begin
                        rsp_buf_valid    <= 1'b1;
                        rsp_buf.id       <= arb_req_id;
                        rsp_buf.rdata    <= {64'd0, ddram_dout};
                        rsp_buf.beat_idx <= 3'd0;
                        rsp_buf.last     <= 1'b1;
                        rsp_buf.resp     <= MEM_RESP_OK;
                        dd_owner  <= DD_IDLE;
                        lk_state  <= LK_IDLE;
                    end
                end

                // -------------------------------------------------------
                // MSHR SRAM service: evict read (4 cycles)
                //   BRAM outputs valid for mh_set_idx[lk_mshr_id] — all
                //   4 words of victim way available every cycle.
                // -------------------------------------------------------
                LK_MSHR_EVICT: begin
                    mh_evict_buf[lk_mshr_id][lk_mshr_cnt] <=
                        dm_rd_data[mh_victim_way[lk_mshr_id]][lk_mshr_cnt];
                    if (lk_mshr_cnt == 2'd3) begin
                        mh_state[lk_mshr_id] <= MH_WB_REQ;
                        lk_state <= LK_IDLE;
                    end else
                        lk_mshr_cnt <= lk_mshr_cnt + 2'd1;
                end

                // -------------------------------------------------------
                // MSHR SRAM service: fill install (1 cycle)
                //   Data+tag BRAM writes driven by always_comb block.
                // -------------------------------------------------------
                LK_MSHR_INST: begin
                    tag_valid[mh_set_idx[lk_mshr_id]][mh_victim_way[lk_mshr_id]] <= 1'b1;
                    plru_bits[mh_set_idx[lk_mshr_id]] <=
                        plru_update(plru_bits[mh_set_idx[lk_mshr_id]], mh_victim_way[lk_mshr_id]);

                    mh_state[lk_mshr_id] <= MH_COMPLETE;
                    lk_state <= LK_IDLE;
                end

                default: lk_state <= LK_IDLE;

            endcase

            // ===========================================================
            // MSHR DDRAM Operations (run concurrently with lookup FSM)
            // ===========================================================
            // DDRAM grant to MSHR: only when dd_owner is IDLE and main FSM
            // is not about to use DDRAM
            if (dd_owner == DD_IDLE && mshr_ddram_req &&
                !(lk_state inside {LK_WB_BURST, LK_FILL_BURST, LK_UC_ISSUE, LK_UC_WAIT})) begin
                dd_owner   <= DD_MH;
                dd_mshr_id <= mshr_ddram_req_id;
                // Transition MSHR: REQ → BURST
                if (mh_state[mshr_ddram_req_id] == MH_WB_REQ)
                    mh_state[mshr_ddram_req_id] <= MH_WB_BURST;
                else if (mh_state[mshr_ddram_req_id] == MH_FILL_REQ)
                    mh_state[mshr_ddram_req_id] <= MH_FILL_BURST;
            end

            // MSHR writeback burst
            for (int m = 0; m < NUM_MSHR; m++) begin
                if (mh_state[m] == MH_WB_BURST && dd_owner == DD_MH && dd_mshr_id == MSHR_ID_W'(m)) begin
                    if (!ddram_busy) begin
                        ddram_addr     <= {mh_evict_tag[m], mh_set_idx[m], 2'b00};
                        ddram_burstcnt <= 8'd4;
                        ddram_din      <= mh_evict_buf[m][mh_wb_cnt[m]];
                        ddram_be       <= 8'hFF;
                        ddram_we       <= 1'b1;
                        if (mh_wb_cnt[m] == 2'd3) begin
                            mh_state[m] <= MH_FILL_REQ;
                            dd_owner    <= DD_IDLE;
                            ctr_ddram_wb_bursts <= ctr_ddram_wb_bursts + 32'd1;
                        end else
                            mh_wb_cnt[m] <= mh_wb_cnt[m] + 2'd1;
                    end
                end
            end

            // MSHR fill burst
            for (int m = 0; m < NUM_MSHR; m++) begin
                if (mh_state[m] == MH_FILL_BURST && dd_owner == DD_MH && dd_mshr_id == MSHR_ID_W'(m)) begin
                    if (!mh_fill_rd_issued[m] && !ddram_busy) begin
                        ddram_addr     <= {mh_tag[m], mh_set_idx[m], 2'b00};
                        ddram_burstcnt <= 8'd4;
                        ddram_rd       <= 1'b1;
                        mh_fill_rd_issued[m] <= 1'b1;
                        ctr_ddram_fill_bursts <= ctr_ddram_fill_bursts + 32'd1;
                    end
                    if (ddram_dout_ready) begin
                        mh_fill_buf[m][mh_fill_cnt[m]] <= ddram_dout;
                        if (mh_fill_cnt[m] == 2'd3) begin
                            mh_state[m] <= MH_INSTALL_PEND;
                            dd_owner    <= DD_IDLE;
                        end else
                            mh_fill_cnt[m] <= mh_fill_cnt[m] + 2'd1;
                    end
                end
            end

            // MSHR non-dirty skip: FILL_REQ directly (evict not needed)
            // Already handled at allocation time in TAG_CMP.

        end
    end

    // Victim way and dirty computation for MSHR allocation (combinational)
    wire [1:0] mh_victim_tmp = select_victim(tag_valid_rd, plru_bits[addr_index(arb_addr)]);
    wire mh_evict_dirty_tmp  = tag_valid_rd[mh_victim_tmp] &&
                                tm_dirty(tm_rd_data[mh_victim_tmp]);

    // =========================================================================
    // Assertions (sim-only)
    // =========================================================================
`ifndef SYNTHESIS

    // Tag hit uniqueness
    always @(posedge clk) begin
        if (rst_n && lk_state == LK_TAG_CMP)
            assert ($countones(hit_vec) <= 1)
                else $error("L2_SP: multiple ways hit for addr %08h, hit_vec=%b", arb_addr, hit_vec);
    end

    // At most 1 MSHR accesses DDRAM at a time
    always @(posedge clk) if (rst_n) begin
        automatic int ddram_users = 0;
        for (int i = 0; i < NUM_MSHR; i++)
            if (mh_state[i] inside {MH_WB_BURST, MH_FILL_BURST}) ddram_users++;
        assert (ddram_users <= 1)
            else $error("L2_SP: multiple MSHRs in DDRAM burst state");
    end

    // MSHR set+tag uniqueness (no two MSHRs for same line)
    always @(posedge clk) if (rst_n) begin
        for (int i = 0; i < NUM_MSHR; i++) begin
            for (int j = i+1; j < NUM_MSHR; j++) begin
                if (mh_state[i] != MH_FREE && mh_state[j] != MH_FREE)
                    assert (!(mh_set_idx[i] == mh_set_idx[j] && mh_tag[i] == mh_tag[j]))
                        else $error("L2_SP: MSHRs %0d and %0d have same set+tag", i, j);
            end
        end
    end

    // Fill beat count == 3 on completion (last beat stored at cnt=3, cnt not incremented)
    always @(posedge clk) if (rst_n) begin
        for (int i = 0; i < NUM_MSHR; i++) begin
            if (mh_state[i] == MH_INSTALL_PEND)
                assert (mh_fill_cnt[i] == 2'd3)
                    else $error("L2_SP: MSHR %0d install_pend with fill_cnt=%0d (expected 3)", i, mh_fill_cnt[i]);
        end
    end

    // MH_COMPLETE watchdog: 512-cycle threshold per MSHR
    logic [9:0] mh_complete_cnt [NUM_MSHR];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            for (int i = 0; i < NUM_MSHR; i++) mh_complete_cnt[i] <= 10'd0;
        else
            for (int i = 0; i < NUM_MSHR; i++) begin
                if (mh_state[i] == MH_COMPLETE)
                    mh_complete_cnt[i] <= mh_complete_cnt[i] + 10'd1;
                else
                    mh_complete_cnt[i] <= 10'd0;
                if (mh_complete_cnt[i] == 10'd511)
                    $fatal(1, "L2_SP: MSHR %0d stuck in COMPLETE for 512 cycles", i);
            end
    end

    // Watchdog: no main FSM state stuck for > 1024 cycles
    logic [10:0] watchdog_cnt;
    lk_state_t   watchdog_state;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            watchdog_cnt   <= 11'd0;
            watchdog_state <= LK_IDLE;
        end else begin
            if (lk_state != watchdog_state) begin
                watchdog_cnt   <= 11'd0;
                watchdog_state <= lk_state;
            end else if (lk_state != LK_IDLE) begin
                watchdog_cnt <= watchdog_cnt + 11'd1;
                if (watchdog_cnt == 11'd1023)
                    $fatal(1, "L2_SP: stuck in state %s for 1024 cycles", lk_state.name());
            end
        end
    end

    // Per-MSHR watchdog: no MSHR should be active for > 2048 cycles
    logic [11:0] mh_watchdog [NUM_MSHR];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_MSHR; i++) mh_watchdog[i] <= 12'd0;
        end else begin
            for (int i = 0; i < NUM_MSHR; i++) begin
                if (mh_state[i] == MH_FREE)
                    mh_watchdog[i] <= 12'd0;
                else begin
                    mh_watchdog[i] <= mh_watchdog[i] + 12'd1;
                    if (mh_watchdog[i] == 12'd2047)
                        $fatal(1, "L2_SP: MSHR %0d stuck for 2048 cycles in state %s",
                               i, mh_state[i].name());
                end
            end
        end
    end

    // No simultaneous blocking client acks
    always @(posedge clk) if (rst_n)
        assert ($countones({ifetch_valid, pt_ack}) <= 1)
            else $error("L2_SP: multiple blocking client acks in same cycle");

    // Response buffer not overwritten while valid and not consumed
    logic [CONF_MEM_REQ_ID_W-1:0] rsp_buf_id_prev;
    logic                          rsp_buf_valid_prev;
    logic                          rsp_buf_consumed_prev;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_buf_id_prev       <= '0;
            rsp_buf_valid_prev    <= 1'b0;
            rsp_buf_consumed_prev <= 1'b0;
        end else begin
            rsp_buf_id_prev       <= rsp_buf.id;
            rsp_buf_valid_prev    <= rsp_buf_valid;
            rsp_buf_consumed_prev <= lk_rsp_wins && data_rsp_ready;
        end
    end
    // If rsp_buf was valid last cycle and was NOT consumed, its ID must not change
    always @(posedge clk) if (rst_n) begin
        if (rsp_buf_valid_prev && rsp_buf_valid && !rsp_buf_consumed_prev)
            assert (rsp_buf.id == rsp_buf_id_prev)
                else $error("L2_SP: rsp_buf.id changed (%0h -> %0h) while valid and not consumed",
                            rsp_buf_id_prev, rsp_buf.id);
    end

    // Valid-ready contract: accepted request must transition to expected state
    logic        prev_data_accepted;
    logic        prev_data_cacheable;
    logic        prev_data_coalesced;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_data_accepted  <= 1'b0;
            prev_data_cacheable <= 1'b0;
            prev_data_coalesced <= 1'b0;
        end else begin
            prev_data_accepted  <= data_req_valid && data_req_ready;
            prev_data_cacheable <= data_req.cacheable;
            prev_data_coalesced <= data_req_coalesce_ok;
        end
    end
    always @(posedge clk) if (rst_n) begin
        if (prev_data_accepted && prev_data_cacheable && !prev_data_coalesced)
            assert (lk_state == LK_TAG_RD)
                else $error("L2_SP: cacheable req accepted but next state is %s (expected LK_TAG_RD)",
                            lk_state.name());
        // Coalesced requests don't change lk_state — no transition assertion needed.
        // (prev_data_coalesced covered by exclusion from the cacheable check above.)
        if (prev_data_accepted && !prev_data_cacheable)
            assert (lk_state == LK_UC_ISSUE)
                else $error("L2_SP: uncacheable req accepted but next state is %s (expected LK_UC_ISSUE)",
                            lk_state.name());
    end

    // UC progress-based watchdog: 512 cycles with no progress event
    logic [9:0]    uc_watchdog;
    lk_state_t     uc_state_prev;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uc_watchdog   <= 10'd0;
            uc_state_prev <= LK_IDLE;
        end else begin
            uc_state_prev <= lk_state;
            if (lk_state inside {LK_UC_ISSUE, LK_UC_WAIT}) begin
                // Reset on any progress event
                if (ddram_rd || ddram_dout_ready || (lk_state != uc_state_prev))
                    uc_watchdog <= 10'd0;
                else
                    uc_watchdog <= uc_watchdog + 10'd1;
            end else begin
                uc_watchdog <= 10'd0;
            end
            if (uc_watchdog == 10'd511)
                $fatal(1, "L2_SP: uncacheable bypass stuck for 512 cycles with no progress event");
        end
    end

`endif

endmodule
