/*
 * fabi386: Load-Store Queue (LSQ) v2.0 — Byte-Granular Forwarding
 * -----------------------------------------------------------------
 * 8 load queue + 8 store queue entries with byte-level store-to-load
 * forwarding.  Enforces TSO memory ordering.
 *
 * Architecture (2-cycle lookup, for 140 MHz Fmax):
 *   Cycle 1: Address CAM match (compare incoming load addr against SQ)
 *            + byte-enable overlap check
 *   Cycle 2: Data forwarding mux / memory request issue
 *
 * Upgrade from v1.0:
 *   - 4+4 → 8+8 entries (parameterized via CONF_LSQ_LQ/SQ_ENTRIES)
 *   - Byte-enable tracking per store (4 bits: byte lanes 0-3)
 *   - Byte-granular forwarding: partial forwarding from multiple stores
 *   - Memory dependency predictor port (for speculative load ordering)
 *   - D-cache port (replaces direct memory bus when CONF_ENABLE_DCACHE=1)
 *
 * Key design decisions:
 *   - Byte-enable CAM: each store carries a 4-bit byte_en mask.
 *     A load matches if addr[31:2] == sq_addr[31:2] AND the store
 *     covers ALL bytes the load needs (byte_en overlap is complete).
 *   - Youngest-match forwarding: walk SQ from head to tail, last
 *     match wins (youngest store older than load).
 *   - Partial forwarding: if no single store covers all bytes, fall
 *     through to cache/memory. (Full multi-store merge deferred to P2.)
 *   - Stores commit only at retirement (TSO correctness).
 *
 * Reference: rsd MemoryDependencyPredictor.sv, BOOM lsu.scala
 */

import f386_pkg::*;

module f386_lsq (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         flush,

    // --- Dispatch Interface (from ROB) ---
    input  logic         ld_dispatch_valid,
    input  rob_id_t      ld_dispatch_rob_tag,
    input  logic         st_dispatch_valid,
    input  rob_id_t      st_dispatch_rob_tag,
    output lq_idx_t      ld_dispatch_idx,
    output sq_idx_t      st_dispatch_idx,
    output logic         lq_full,
    output logic         sq_full,

    // --- Address from AGU (cycle 1 input) ---
    input  logic         agu_ld_valid,
    input  lq_idx_t      agu_ld_idx,
    input  logic [31:0]  agu_ld_addr,
    input  logic [1:0]   agu_ld_size,        // 0=byte, 1=word, 2=dword
    input  logic [3:0]   agu_ld_byte_en,     // Byte lanes needed
    input  logic         agu_ld_signed,      // 1=sign-extend, 0=zero-extend

    input  logic         agu_st_valid,
    input  sq_idx_t      agu_st_idx,
    input  logic [31:0]  agu_st_addr,
    input  logic [31:0]  agu_st_data,
    input  logic [1:0]   agu_st_size,
    input  logic [3:0]   agu_st_byte_en,     // Byte lanes written

    // --- CDB Load Result (cycle 2 output) ---
    output logic         ld_cdb_valid,
    output rob_id_t      ld_cdb_tag,
    output logic [31:0]  ld_cdb_data,

    // --- Retirement Interface ---
    input  logic         retire_st_valid,
    input  sq_idx_t      retire_st_idx,

    // --- D-Cache Interface (when CONF_ENABLE_DCACHE=1) ---
    output logic         dcache_req_valid,
    output logic [31:0]  dcache_req_addr,
    output logic [31:0]  dcache_req_wdata,
    output logic [3:0]   dcache_req_byte_en,
    output logic         dcache_req_wr,
    input  logic         dcache_req_ready,
    input  logic         dcache_resp_valid,
    input  logic [31:0]  dcache_resp_data,

    // --- Split-Phase Memory Interface (when CONF_ENABLE_DCACHE=0) ---
    output logic         mem_req_valid,
    input  logic         mem_req_ready,
    output mem_req_t     mem_req_out,
    input  logic         mem_rsp_valid,
    output logic         mem_rsp_ready,
    input  mem_rsp_t     mem_rsp_in,

    // --- Memory Dependency Predictor ---
    output logic         mdp_violation,      // Memory ordering violation detected
    output logic [31:0]  mdp_violation_pc    // PC of the violated load
);

    localparam int LQ_N = CONF_LSQ_LQ_ENTRIES;  // 8
    localparam int SQ_N = CONF_LSQ_SQ_ENTRIES;  // 8

    // =========================================================
    // Helper Functions
    // =========================================================

    // Sign/zero extension for sub-dword scalar loads
    function automatic logic [31:0] sign_zero_extend(
        input logic [31:0] data, input logic [1:0] size, input logic is_signed
    );
        case (size)
            2'd0: sign_zero_extend = is_signed ? {{24{data[7]}},  data[7:0]}
                                               : {24'd0,          data[7:0]};
            2'd1: sign_zero_extend = is_signed ? {{16{data[15]}}, data[15:0]}
                                               : {16'd0,          data[15:0]};
            default: sign_zero_extend = data;
        endcase
    endfunction

    // Misalignment check: does access cross 64-bit boundary?
    function automatic logic crosses_64b(input logic [1:0] size, input logic [2:0] ofs);
        logic [3:0] nbytes;
        case (size)
            2'd0: nbytes = 4'd1;
            2'd1: nbytes = 4'd2;
            2'd2: nbytes = 4'd4;
            default: nbytes = 4'd8;
        endcase
        crosses_64b = ({1'b0, ofs} + nbytes) > 4'd8;
    endfunction

    // =========================================================
    // Load Queue Storage
    // =========================================================
    logic [LQ_N-1:0]  lq_valid;
    logic [LQ_N-1:0]  lq_addr_valid;
    logic [LQ_N-1:0]  lq_executed;
    logic [31:0]       lq_addr    [LQ_N];
    logic [1:0]        lq_size    [LQ_N];
    logic [3:0]        lq_byte_en [LQ_N];
    rob_id_t           lq_rob_tag [LQ_N];
    logic [31:0]       lq_data    [LQ_N];
    // Note: lq_signed intentionally omitted — sign info flows through
    // ld_pipe_signed_r → ld_wait_signed → extraction. LQ replay, if
    // added later, should re-derive from lq_size + opcode.

    lq_idx_t lq_head, lq_tail;
    logic [LQ_ID_WIDTH:0] lq_count;

    // =========================================================
    // Store Queue Storage
    // =========================================================
    logic [SQ_N-1:0]  sq_valid;
    logic [SQ_N-1:0]  sq_addr_valid;
    logic [SQ_N-1:0]  sq_data_valid;
    logic [SQ_N-1:0]  sq_committed;
    logic [31:0]       sq_addr    [SQ_N];
    logic [31:0]       sq_data    [SQ_N];
    logic [1:0]        sq_size    [SQ_N];
    logic [3:0]        sq_byte_en [SQ_N];
    rob_id_t           sq_rob_tag [SQ_N];

    sq_idx_t sq_head, sq_tail;
    logic [SQ_ID_WIDTH:0] sq_count;

    // =========================================================
    // Queue Full / Dispatch
    // =========================================================
    assign lq_full = (lq_count >= LQ_N[LQ_ID_WIDTH:0]);
    assign sq_full = (sq_count >= SQ_N[SQ_ID_WIDTH:0]);
    assign ld_dispatch_idx = lq_tail;
    assign st_dispatch_idx = sq_tail;

    // Default MDP signals
    assign mdp_violation    = 1'b0;  // TODO: detect ordering violations at execute
    assign mdp_violation_pc = 32'd0;

    // =========================================================
    // Load Queue Dispatch + AGU Writeback
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            lq_valid      <= '0;
            lq_addr_valid <= '0;
            lq_executed   <= '0;
            lq_head       <= '0;
            lq_tail       <= '0;
            lq_count      <= '0;
        end else begin
            // Dispatch new load
            if (ld_dispatch_valid && !lq_full) begin
                lq_valid[lq_tail]      <= 1'b1;
                lq_addr_valid[lq_tail] <= 1'b0;
                lq_executed[lq_tail]   <= 1'b0;
                lq_rob_tag[lq_tail]    <= ld_dispatch_rob_tag;
                lq_tail                <= lq_tail + lq_idx_t'(1);
                lq_count               <= lq_count + (LQ_ID_WIDTH+1)'(1);
            end

            // AGU address writeback
            if (agu_ld_valid && lq_valid[agu_ld_idx]) begin
                lq_addr[agu_ld_idx]       <= agu_ld_addr;
                lq_size[agu_ld_idx]       <= agu_ld_size;
                lq_byte_en[agu_ld_idx]    <= agu_ld_byte_en;
                lq_addr_valid[agu_ld_idx] <= 1'b1;
            end

            // Retire (dequeue) completed loads
            if (lq_valid[lq_head] && lq_executed[lq_head]) begin
                lq_valid[lq_head] <= 1'b0;
                lq_head           <= lq_head + lq_idx_t'(1);
                lq_count          <= lq_count - (LQ_ID_WIDTH+1)'(1);
            end
        end
    end

    // =========================================================
    // Store Queue Dispatch + AGU Writeback + Retire + Drain
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            sq_valid      <= '0;
            sq_addr_valid <= '0;
            sq_data_valid <= '0;
            sq_committed  <= '0;
            sq_head       <= '0;
            sq_tail       <= '0;
            sq_count      <= '0;
        end else begin
            // Dispatch new store
            if (st_dispatch_valid && !sq_full) begin
                sq_valid[sq_tail]      <= 1'b1;
                sq_addr_valid[sq_tail] <= 1'b0;
                sq_data_valid[sq_tail] <= 1'b0;
                sq_committed[sq_tail]  <= 1'b0;
                sq_rob_tag[sq_tail]    <= st_dispatch_rob_tag;
                sq_tail                <= sq_tail + sq_idx_t'(1);
                sq_count               <= sq_count + (SQ_ID_WIDTH+1)'(1);
            end

            // AGU address + data writeback
            if (agu_st_valid && sq_valid[agu_st_idx]) begin
                sq_addr[agu_st_idx]       <= agu_st_addr;
                sq_data[agu_st_idx]       <= agu_st_data;
                sq_size[agu_st_idx]       <= agu_st_size;
                sq_byte_en[agu_st_idx]    <= agu_st_byte_en;
                sq_addr_valid[agu_st_idx] <= 1'b1;
                sq_data_valid[agu_st_idx] <= 1'b1;
            end

            // Mark store as committed at retirement
            if (retire_st_valid && sq_valid[retire_st_idx])
                sq_committed[retire_st_idx] <= 1'b1;

            // Dequeue committed store after cache/memory write completes
            if (store_drain_ack && sq_valid[sq_head] && sq_committed[sq_head]) begin
                sq_valid[sq_head] <= 1'b0;
                sq_head           <= sq_head + sq_idx_t'(1);
                sq_count          <= sq_count - (SQ_ID_WIDTH+1)'(1);
            end
        end
    end

    // =========================================================
    // Byte-Granular Store-to-Load Forwarding (Cycle 1: CAM)
    // =========================================================
    // For each SQ entry, check:
    //   1. addr[31:2] matches (same dword)
    //   2. Store's byte_en covers ALL bytes the load needs
    // Walk all entries; last (youngest) full match wins.

    logic        fwd_hit;
    logic [31:0] fwd_data;

    always_comb begin
        fwd_hit  = 1'b0;
        fwd_data = 32'd0;

        for (int i = 0; i < SQ_N; i++) begin
            if (sq_valid[i] && sq_addr_valid[i] && sq_data_valid[i] &&
                agu_ld_valid && lq_valid[agu_ld_idx]) begin

                // Dword address match
                if (sq_addr[i][31:2] == agu_ld_addr[31:2]) begin
                    // Byte-lane coverage check: store must cover all load bytes
                    logic [3:0] needed;
                    needed = agu_ld_byte_en;

                    if ((sq_byte_en[i] & needed) == needed) begin
                        // Full coverage — forward with byte-lane merge
                        fwd_hit = 1'b1;
                        // Merge only the bytes the store wrote
                        for (int b = 0; b < 4; b++) begin
                            if (sq_byte_en[i][b])
                                fwd_data[b*8 +: 8] = sq_data[i][b*8 +: 8];
                        end
                    end
                    // Partial match (store covers some but not all bytes):
                    // Don't forward — fall through to cache/memory.
                    // Multi-store merge deferred to Phase P2.
                end
            end
        end
    end

    // =========================================================
    // Load Execution Pipeline (Cycle 2)
    // =========================================================
    // Stage 1 (registered): capture CAM results
    logic        ld_pipe_valid_r;
    lq_idx_t     ld_pipe_idx_r;
    logic [31:0] ld_pipe_addr_r;
    logic [1:0]  ld_pipe_size_r;
    logic [3:0]  ld_pipe_byte_en_r;
    logic        ld_pipe_signed_r;
    logic        ld_pipe_fwd_hit_r;
    logic [31:0] ld_pipe_fwd_data_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush) begin
            ld_pipe_valid_r <= 1'b0;
        end else begin
            ld_pipe_valid_r     <= agu_ld_valid && lq_valid[agu_ld_idx];
            ld_pipe_idx_r       <= agu_ld_idx;
            ld_pipe_addr_r      <= agu_ld_addr;
            ld_pipe_size_r      <= agu_ld_size;
            ld_pipe_byte_en_r   <= agu_ld_byte_en;
            ld_pipe_signed_r    <= agu_ld_signed;
            ld_pipe_fwd_hit_r   <= fwd_hit;
            ld_pipe_fwd_data_r  <= fwd_data;
        end
    end

    // Stage 2: Forward or issue cache/memory read
    typedef enum logic [1:0] {
        LD_IDLE = 2'd0,
        LD_WAIT = 2'd1,
        LD_DONE = 2'd2
    } ld_state_t;

    ld_state_t   ld_state;
    logic [31:0] ld_result;
    lq_idx_t     ld_result_idx;

    // Latched registers for LD_WAIT — prevent AGU overwrite of pipeline regs
    logic [31:0] ld_wait_addr;
    logic [1:0]  ld_wait_size;
    logic [3:0]  ld_wait_byte_en;
    logic        ld_wait_signed;

    // Store drain acknowledge
    logic store_drain_ack;

    // Cache vs memory response mux
    logic        mem_resp_valid;
    logic [31:0] mem_resp_data;

    // =========================================================
    // Store Drain Condition
    // =========================================================
    logic drain_store;
    assign drain_store = sq_valid[sq_head] && sq_committed[sq_head] &&
                         sq_addr_valid[sq_head] && sq_data_valid[sq_head] &&
                         (ld_state == LD_IDLE);

    // =========================================================
    // Load Execution FSM + Backend (generate-split: dcache vs mem)
    // =========================================================
    generate
        if (CONF_ENABLE_DCACHE) begin : gen_dcache_path
            // ---- D-Cache Path (unchanged) ----
            assign mem_resp_valid = dcache_resp_valid;
            assign mem_resp_data  = dcache_resp_data;
            assign store_drain_ack = dcache_req_ready && drain_store;

            always_comb begin
                dcache_req_valid   = 1'b0;
                dcache_req_addr    = 32'd0;
                dcache_req_wdata   = 32'd0;
                dcache_req_byte_en = 4'd0;
                dcache_req_wr      = 1'b0;

                if (ld_state == LD_WAIT) begin
                    dcache_req_valid   = 1'b1;
                    dcache_req_addr    = ld_wait_addr;
                    dcache_req_wr      = 1'b0;
                    dcache_req_byte_en = ld_wait_byte_en;
                end else if (drain_store) begin
                    dcache_req_valid   = 1'b1;
                    dcache_req_addr    = sq_addr[sq_head];
                    dcache_req_wdata   = sq_data[sq_head];
                    dcache_req_byte_en = sq_byte_en[sq_head];
                    dcache_req_wr      = 1'b1;
                end
            end

            // Tie off split-phase memory interface
            assign mem_req_valid = 1'b0;
            assign mem_req_out   = '0;
            assign mem_rsp_ready = 1'b0;

            // Load execution FSM (dcache path — same structure, dcache response)
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n || flush) begin
                    ld_state     <= LD_IDLE;
                    ld_cdb_valid <= 1'b0;
                end else begin
                    ld_cdb_valid <= 1'b0;

                    case (ld_state)
                        LD_IDLE: begin
                            if (ld_pipe_valid_r) begin
                                if (ld_pipe_fwd_hit_r) begin
                                    automatic logic [4:0]  fwd_shift   = {ld_pipe_addr_r[1:0], 3'b000};
                                    automatic logic [31:0] fwd_shifted  = ld_pipe_fwd_data_r >> fwd_shift;
                                    automatic logic [31:0] fwd_extended = sign_zero_extend(fwd_shifted,
                                                                            ld_pipe_size_r, ld_pipe_signed_r);
                                    ld_result     <= fwd_extended;
                                    ld_result_idx <= ld_pipe_idx_r;
                                    ld_cdb_valid  <= 1'b1;
                                    ld_cdb_tag    <= lq_rob_tag[ld_pipe_idx_r];
                                    ld_cdb_data   <= fwd_extended;
                                    lq_data[ld_pipe_idx_r]     <= fwd_extended;
                                    lq_executed[ld_pipe_idx_r] <= 1'b1;
                                end else begin
                                    ld_state        <= LD_WAIT;
                                    ld_result_idx   <= ld_pipe_idx_r;
                                    ld_wait_addr    <= ld_pipe_addr_r;
                                    ld_wait_size    <= ld_pipe_size_r;
                                    ld_wait_byte_en <= ld_pipe_byte_en_r;
                                    ld_wait_signed  <= ld_pipe_signed_r;
                                end
                            end
                        end

                        LD_WAIT: begin
                            if (mem_resp_valid) begin
                                ld_result    <= mem_resp_data;
                                ld_cdb_valid <= 1'b1;
                                ld_cdb_tag   <= lq_rob_tag[ld_result_idx];
                                ld_cdb_data  <= mem_resp_data;
                                lq_data[ld_result_idx]     <= mem_resp_data;
                                lq_executed[ld_result_idx] <= 1'b1;
                                ld_state     <= LD_IDLE;
                            end
                        end

                        default: ld_state <= LD_IDLE;
                    endcase
                end
            end

        end else begin : gen_mem_path
            // ---- Split-Phase Memory Path (new backend FSM) ----

            // Backend FSM states
            typedef enum logic [1:0] {
                BE_IDLE    = 2'd0,
                BE_LD_RSP  = 2'd1,
                BE_ST_RSP  = 2'd2,
                BE_DRAIN   = 2'd3
            } be_state_t;

            be_state_t be_state_q, be_state_d;

            // Backend response signals → bridge to LD_WAIT FSM
            logic        be_resp_valid;
            logic [31:0] be_resp_data;
            logic        store_drain_ack_be;

            assign mem_resp_valid  = be_resp_valid;
            assign mem_resp_data   = be_resp_data;
            assign store_drain_ack = store_drain_ack_be;

            // Response handshake — driven from registered state (no comb loop)
            assign mem_rsp_ready = (be_state_q != BE_IDLE);

            // Request/response fire signals
            wire req_fire = mem_req_valid && mem_req_ready;
            wire rsp_fire = mem_rsp_valid && mem_rsp_ready;

            // ---- Store alignment: addr[2] dword-half selection ----
            wire [63:0] st_wdata_aligned = sq_addr[sq_head][2]
                ? {sq_data[sq_head], 32'd0}
                : {32'd0, sq_data[sq_head]};
            wire [7:0]  st_byte_en_aligned = sq_addr[sq_head][2]
                ? {sq_byte_en[sq_head], 4'h0}
                : {4'h0, sq_byte_en[sq_head]};

            // ---- Load extraction from 64-bit raw beat ----
            wire [63:0] raw_beat       = mem_rsp_in.rdata[63:0];
            wire [5:0]  ld_shift_amt   = {ld_wait_addr[2:0], 3'b000};
            wire [63:0] ld_shifted64   = raw_beat >> ld_shift_amt;
            wire [31:0] ld_shifted     = ld_shifted64[31:0];
            wire [31:0] extracted      = sign_zero_extend(ld_shifted, ld_wait_size,
                                                          ld_wait_signed);

            // ---- Request formation (combinational, in BE_IDLE) ----
            always_comb begin
                mem_req_valid = 1'b0;
                mem_req_out   = '0;

                if (be_state_q == BE_IDLE) begin
                    if (ld_state == LD_WAIT) begin
                        mem_req_valid       = 1'b1;
                        mem_req_out.id      = '0;
                        mem_req_out.op      = MEM_OP_LD;
                        mem_req_out.addr    = ld_wait_addr;
                        mem_req_out.size    = ld_wait_size;
                        mem_req_out.byte_en = 8'h00;
                        mem_req_out.wdata   = 64'd0;
                    end else if (drain_store) begin
                        mem_req_valid       = 1'b1;
                        mem_req_out.id      = '0;
                        mem_req_out.op      = MEM_OP_ST;
                        mem_req_out.addr    = sq_addr[sq_head];
                        mem_req_out.size    = sq_size[sq_head];
                        mem_req_out.byte_en = st_byte_en_aligned;
                        mem_req_out.wdata   = st_wdata_aligned;
                    end
                end
            end

            // ---- Backend state transition logic ----
            always_comb begin
                be_state_d = be_state_q;

                case (be_state_q)
                    BE_IDLE: begin
                        if (req_fire) begin
                            if (ld_state == LD_WAIT)
                                be_state_d = BE_LD_RSP;
                            else
                                be_state_d = BE_ST_RSP;
                        end
                    end

                    BE_LD_RSP: begin
                        if (flush && !rsp_fire)
                            be_state_d = BE_DRAIN;
                        else if (rsp_fire)
                            be_state_d = BE_IDLE;
                    end

                    BE_ST_RSP: begin
                        if (flush && !rsp_fire)
                            be_state_d = BE_DRAIN;
                        else if (rsp_fire)
                            be_state_d = BE_IDLE;
                    end

                    BE_DRAIN: begin
                        if (rsp_fire)
                            be_state_d = BE_IDLE;
                    end
                endcase
            end

            // ---- Backend registered state + response extraction ----
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    be_state_q         <= BE_IDLE;
                    be_resp_valid      <= 1'b0;
                    be_resp_data       <= 32'd0;
                    store_drain_ack_be <= 1'b0;
                end else if (flush) begin
                    be_state_q         <= be_state_d;  // May transition to BE_DRAIN
                    be_resp_valid      <= 1'b0;
                    be_resp_data       <= 32'd0;
                    store_drain_ack_be <= 1'b0;
                end else begin
                    be_state_q         <= be_state_d;
                    be_resp_valid      <= 1'b0;
                    store_drain_ack_be <= 1'b0;

                    case (be_state_q)
                        BE_LD_RSP: begin
                            if (rsp_fire) begin
                                `ifndef SYNTHESIS
                                assert (mem_rsp_in.id == '0)
                                    else $error("LSQ: unexpected rsp id=%0d (expected 0)",
                                                mem_rsp_in.id);
                                `endif
                                case (mem_rsp_in.resp)
                                    MEM_RESP_OK: begin
                                        be_resp_valid <= 1'b1;
                                        be_resp_data  <= extracted;
                                    end
                                    MEM_RESP_RETRY: begin
                                        // Return to BE_IDLE; LD_WAIT re-requests next cycle
                                    end
                                    default: begin // MEM_RESP_FAULT, MEM_RESP_MISALIGN
                                        // Complete with poison data to unblock LD_WAIT.
                                        // Exception unit (when wired) kills via ROB before retire.
                                        be_resp_valid <= 1'b1;
                                        be_resp_data  <= 32'hDEAD_BEEF;
                                        `ifndef SYNTHESIS
                                        $fatal(1, "LSQ: fatal resp %s on load addr=%08h",
                                               mem_rsp_in.resp.name(), ld_wait_addr);
                                        `endif
                                    end
                                endcase
                            end
                        end

                        BE_ST_RSP: begin
                            if (rsp_fire) begin
                                `ifndef SYNTHESIS
                                assert (mem_rsp_in.id == '0)
                                    else $error("LSQ: unexpected rsp id=%0d on store",
                                                mem_rsp_in.id);
                                `endif
                                case (mem_rsp_in.resp)
                                    MEM_RESP_OK: begin
                                        store_drain_ack_be <= 1'b1;
                                    end
                                    MEM_RESP_RETRY: begin
                                        // Do NOT ack — store stays at sq_head, will re-drain
                                    end
                                    default: begin // MEM_RESP_FAULT, MEM_RESP_MISALIGN
                                        // Ack the drain to unblock SQ progress.
                                        // Exception unit (when wired) kills via ROB before retire.
                                        store_drain_ack_be <= 1'b1;
                                        `ifndef SYNTHESIS
                                        $fatal(1, "LSQ: fatal resp %s on store addr=%08h",
                                               mem_rsp_in.resp.name(), sq_addr[sq_head]);
                                        `endif
                                    end
                                endcase
                            end
                        end

                        BE_DRAIN: begin
                            // Silently discard stale response after flush
                        end

                        default: ;
                    endcase
                end
            end

            // ---- Load execution FSM ----
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n || flush) begin
                    ld_state     <= LD_IDLE;
                    ld_cdb_valid <= 1'b0;
                end else begin
                    ld_cdb_valid <= 1'b0;

                    case (ld_state)
                        LD_IDLE: begin
                            if (ld_pipe_valid_r) begin
                                if (ld_pipe_fwd_hit_r) begin
                                    automatic logic [4:0]  fwd_shift   = {ld_pipe_addr_r[1:0], 3'b000};
                                    automatic logic [31:0] fwd_shifted  = ld_pipe_fwd_data_r >> fwd_shift;
                                    automatic logic [31:0] fwd_extended = sign_zero_extend(fwd_shifted,
                                                                            ld_pipe_size_r, ld_pipe_signed_r);
                                    ld_result     <= fwd_extended;
                                    ld_result_idx <= ld_pipe_idx_r;
                                    ld_cdb_valid  <= 1'b1;
                                    ld_cdb_tag    <= lq_rob_tag[ld_pipe_idx_r];
                                    ld_cdb_data   <= fwd_extended;
                                    lq_data[ld_pipe_idx_r]     <= fwd_extended;
                                    lq_executed[ld_pipe_idx_r] <= 1'b1;
                                end else begin
                                    ld_state        <= LD_WAIT;
                                    ld_result_idx   <= ld_pipe_idx_r;
                                    ld_wait_addr    <= ld_pipe_addr_r;
                                    ld_wait_size    <= ld_pipe_size_r;
                                    ld_wait_byte_en <= ld_pipe_byte_en_r;
                                    ld_wait_signed  <= ld_pipe_signed_r;
                                end
                            end
                        end

                        LD_WAIT: begin
                            if (mem_resp_valid) begin
                                ld_result    <= mem_resp_data;
                                ld_cdb_valid <= 1'b1;
                                ld_cdb_tag   <= lq_rob_tag[ld_result_idx];
                                ld_cdb_data  <= mem_resp_data;
                                lq_data[ld_result_idx]     <= mem_resp_data;
                                lq_executed[ld_result_idx] <= 1'b1;
                                ld_state     <= LD_IDLE;
                            end
                        end

                        default: ld_state <= LD_IDLE;
                    endcase
                end
            end

            // Tie off D-cache interface
            assign dcache_req_valid   = 1'b0;
            assign dcache_req_addr    = 32'd0;
            assign dcache_req_wdata   = 32'd0;
            assign dcache_req_byte_en = 4'd0;
            assign dcache_req_wr      = 1'b0;

            // =========================================================
            // Assertions (simulation only)
            // =========================================================
            `ifndef SYNTHESIS
            // Misalignment check at load issue
            always_ff @(posedge clk) if (rst_n) begin
                if (ld_pipe_valid_r && !ld_pipe_fwd_hit_r) begin
                    assert (!crosses_64b(ld_pipe_size_r, ld_pipe_addr_r[2:0]))
                        else $fatal(1, "LSQ: load crosses 64-bit boundary addr=%08h size=%0d",
                                     ld_pipe_addr_r, ld_pipe_size_r);
                end
            end

            // Store drain invariants — full dword-lane enforcement
            always_ff @(posedge clk) if (rst_n && drain_store) begin : store_drain_checks
                automatic logic [1:0] st_ofs = sq_addr[sq_head][1:0];
                // Reject cross-dword stores: byte at any offset is fine,
                // word must have addr[1:0] <= 2, dword must have addr[1:0] == 0.
                case (sq_size[sq_head])
                    2'd0: ; // byte — all offsets valid
                    2'd1: assert (st_ofs <= 2'd2)
                              else $fatal(1, "LSQ: word store crosses dword boundary addr[1:0]=%0d",
                                           st_ofs);
                    2'd2: assert (st_ofs == 2'd0)
                              else $fatal(1, "LSQ: dword store misaligned addr[1:0]=%0d", st_ofs);
                    default: ; // caught by size!=3 assert below
                endcase
                // Compute expected mask with 5-bit intermediate to detect truncation
                begin
                    logic [4:0] wide_mask;
                    logic [3:0] expected_mask;
                    case (sq_size[sq_head])
                        2'd0: wide_mask = 5'b00001 << st_ofs;
                        2'd1: wide_mask = 5'b00011 << st_ofs;
                        2'd2: wide_mask = 5'b01111;
                        default: wide_mask = 5'b01111;
                    endcase
                    assert (wide_mask[4] == 1'b0)
                        else $fatal(1, "LSQ: store byte_en overflows dword lane size=%0d addr[1:0]=%0d",
                                     sq_size[sq_head], st_ofs);
                    expected_mask = wide_mask[3:0];
                    assert (sq_byte_en[sq_head] == expected_mask)
                        else $fatal(1, "LSQ: sq_byte_en=%04b != expected %04b for size=%0d addr[1:0]=%0d",
                                     sq_byte_en[sq_head], expected_mask,
                                     sq_size[sq_head], st_ofs);
                end
                assert (sq_byte_en[sq_head] != 4'h0)
                    else $fatal(1, "LSQ: store drain with empty byte_en");
                assert (sq_size[sq_head] != 2'd3)
                    else $fatal(1, "LSQ: 8-byte store not supported in this phase");
            end
            `endif

        end
    endgenerate

endmodule
