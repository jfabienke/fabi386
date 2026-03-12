/*
 * fabi386: MMIO IO Path (P2 Step 2b)
 * ------------------------------------
 * In-order, strongly-ordered path for MMIO loads. Stores stay in LSQ
 * store queue (TSO: all stores drain through one ordering point).
 *
 * TSO serialization: MMIO loads can only fire when `sq_empty` — they
 * must not pass older stores (D3 policy).
 *
 * FSM: IO_IDLE → IO_ISSUE → IO_WAIT → IO_CDB  (happy path)
 *      IO_WAIT → IO_DRAIN → IO_IDLE           (flush during pending)
 *
 * Load data extraction mirrors LSQ byte-level shift (f386_lsq.sv:487-492):
 *   shifted = rdata >> {addr[2:0], 3'b000};  sign_zero_extend(shifted[31:0])
 */

import f386_pkg::*;

module f386_mmio_io_path (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         flush,

    // --- Upstream: MMIO load request (from AGU in core_top) ---
    input  logic         ld_req_valid,
    output logic         ld_req_ready,
    input  logic [31:0]  ld_req_addr,
    input  logic [1:0]   ld_req_size,
    input  logic         ld_req_signed,
    input  rob_id_t      ld_req_rob_tag,
    input  lq_idx_t      ld_req_lq_idx,

    // --- TSO ordering: gate issue on SQ empty ---
    input  logic         sq_empty,

    // --- CDB output (load result) ---
    output logic         ld_cdb_valid,
    output rob_id_t      ld_cdb_tag,
    output logic [31:0]  ld_cdb_data,
    output lq_idx_t      ld_cdb_lq_idx,
    output logic         ld_cdb_fault,
    output logic [7:0]   ld_cdb_exc_vector,    // P3.EXC.a
    output logic [31:0]  ld_cdb_exc_code,
    output logic         ld_cdb_exc_has_error,

    // --- Downstream: split-phase memory interface ---
    output logic         mem_req_valid,
    input  logic         mem_req_ready,
    output mem_req_t     mem_req_out,
    input  logic         mem_rsp_valid,
    output logic         mem_rsp_ready,
    input  mem_rsp_t     mem_rsp_in
);

    // =========================================================
    // Sign/zero extension (replicated from LSQ for locality)
    // =========================================================
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

    // =========================================================
    // FSM States
    // =========================================================
    typedef enum logic [2:0] {
        IO_IDLE  = 3'd0,
        IO_ISSUE = 3'd1,
        IO_WAIT  = 3'd2,
        IO_CDB   = 3'd3,
        IO_DRAIN = 3'd4
    } io_state_t;

    io_state_t state_q, state_d;

    // =========================================================
    // Latched Request Fields
    // =========================================================
    logic [31:0]  lat_addr;
    logic [1:0]   lat_size;
    logic         lat_signed;
    rob_id_t      lat_rob_tag;
    lq_idx_t      lat_lq_idx;

    // Latched response data
    logic [63:0]  lat_rdata;
    logic         lat_fault;
    logic         lat_fault_is_pf;  // P3.EXC.a: distinguish #PF from #GP

    // =========================================================
    // Load data extraction (byte-level shift, mirrors LSQ)
    // =========================================================
    wire [5:0]  ld_shift_amt = {lat_addr[2:0], 3'b000};
    wire [63:0] ld_shifted64 = lat_rdata >> ld_shift_amt;
    wire [31:0] extracted    = sign_zero_extend(ld_shifted64[31:0], lat_size, lat_signed);

    // =========================================================
    // Upstream ready: accept only when IDLE, SQ empty, not flushing
    // =========================================================
    assign ld_req_ready = (state_q == IO_IDLE) && sq_empty && !flush;

    // =========================================================
    // FSM Transition Logic
    // =========================================================
    always_comb begin
        state_d = state_q;

        case (state_q)
            IO_IDLE: begin
                if (ld_req_valid && ld_req_ready)
                    state_d = IO_ISSUE;
            end

            IO_ISSUE: begin
                if (flush)
                    state_d = IO_IDLE;
                else if (mem_req_valid && mem_req_ready)
                    state_d = IO_WAIT;
            end

            IO_WAIT: begin
                if (flush && !mem_rsp_valid)
                    state_d = IO_DRAIN;
                else if (mem_rsp_valid)
                    state_d = flush ? IO_IDLE : IO_CDB;
            end

            IO_CDB: begin
                state_d = IO_IDLE;
            end

            IO_DRAIN: begin
                if (mem_rsp_valid)
                    state_d = IO_IDLE;
            end

            default: state_d = IO_IDLE;
        endcase
    end

    // =========================================================
    // FSM Register
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state_q <= IO_IDLE;
        else
            state_q <= state_d;
    end

    // =========================================================
    // Request Latch
    // =========================================================
    always_ff @(posedge clk) begin
        if (state_q == IO_IDLE && ld_req_valid && ld_req_ready) begin
            lat_addr    <= ld_req_addr;
            lat_size    <= ld_req_size;
            lat_signed  <= ld_req_signed;
            lat_rob_tag <= ld_req_rob_tag;
            lat_lq_idx  <= ld_req_lq_idx;
        end
    end

    // =========================================================
    // Response Latch + Fault Detection
    // =========================================================
    always_ff @(posedge clk) begin
        if (state_q == IO_WAIT && mem_rsp_valid) begin
            lat_rdata       <= mem_rsp_in.rdata[63:0];
            lat_fault       <= (mem_rsp_in.resp == MEM_RESP_FAULT) ||
                               (mem_rsp_in.resp == MEM_RESP_MISALIGN);
            lat_fault_is_pf <= (mem_rsp_in.resp == MEM_RESP_FAULT);
        end
    end

    // =========================================================
    // Downstream Memory Request
    // =========================================================
    always_comb begin
        mem_req_valid = 1'b0;
        mem_req_out   = '0;

        if (state_q == IO_ISSUE && !flush) begin
            mem_req_valid            = 1'b1;
            mem_req_out.id           = '0;
            mem_req_out.id[CONF_LSQ_PEND_ID_W] = 1'b1;  // Client bit = 1 (IO path)
            mem_req_out.op           = MEM_OP_LD;
            mem_req_out.addr         = lat_addr;
            mem_req_out.size         = lat_size;
            mem_req_out.byte_en      = 8'h00;
            mem_req_out.wdata        = 64'd0;
            mem_req_out.cacheable    = 1'b0;
            mem_req_out.strong_order = 1'b1;
        end
    end

    // Response handshake
    assign mem_rsp_ready = (state_q == IO_WAIT) || (state_q == IO_DRAIN);

    // =========================================================
    // CDB Output (one cycle in IO_CDB)
    // =========================================================
    assign ld_cdb_valid       = (state_q == IO_CDB);
    assign ld_cdb_tag         = lat_rob_tag;
    assign ld_cdb_data        = lat_fault ? 32'hDEAD_BEEF : extracted;
    assign ld_cdb_lq_idx      = lat_lq_idx;
    assign ld_cdb_fault       = lat_fault;
    assign ld_cdb_exc_vector   = lat_fault ? (lat_fault_is_pf ? EXC_PF : EXC_GP) : 8'd0;
    assign ld_cdb_exc_code     = 32'd0;
    assign ld_cdb_exc_has_error = lat_fault;

    // =========================================================
    // Assertions (simulation only)
    // =========================================================
    `ifndef SYNTHESIS
    // RETRY watchdog — detect stuck IO requests
    logic [10:0] watchdog_ctr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            watchdog_ctr <= '0;
        end else if (flush) begin
            watchdog_ctr <= '0;
        end else if (state_q == IO_IDLE || state_q == IO_CDB) begin
            watchdog_ctr <= '0;
        end else if (mem_rsp_valid || (mem_req_valid && mem_req_ready)) begin
            watchdog_ctr <= '0;
        end else begin
            watchdog_ctr <= watchdog_ctr + 11'd1;
            assert (watchdog_ctr < 11'd1024)
                else $fatal(1, "IO_PATH: RETRY watchdog fired -- no progress for 1024 cycles in state %0d",
                             state_q);
        end
    end

    // Flush assertion: IO path must reach IO_IDLE after flush settles
    // (may take 1 extra cycle if IO_DRAIN absorbs stale response)
    logic [1:0] flush_ctr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            flush_ctr <= '0;
        else if (flush)
            flush_ctr <= 2'd1;
        else if (flush_ctr != 0 && flush_ctr < 2'd3)
            flush_ctr <= flush_ctr + 2'd1;
        else
            flush_ctr <= '0;
    end

    always_ff @(posedge clk) if (rst_n && flush_ctr == 2'd3) begin
        assert (state_q == IO_IDLE)
            else $error("IO_PATH: not IDLE 2 cycles after flush (state=%0d)", state_q);
    end
    `endif

endmodule
