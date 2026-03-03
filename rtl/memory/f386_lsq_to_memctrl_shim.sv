/*
 * fabi386: LSQ-to-MemCtrl Shim (P2 Step 4)
 * -------------------------------------------
 * Translates a single mem_req_t / mem_rsp_t split-phase channel
 * (from arbiter) into the legacy mem_ctrl data-port protocol (widened
 * to 64-bit in P2).
 *
 * Depth-4 request FIFO sits between upstream (arbiter) and shim FSM:
 *   Arbiter ──> [FIFO depth 4] ──> Shim FSM ──> mem_ctrl data port
 *
 * FSM: IDLE → ISSUE → WAIT_ACK → RESPOND  (happy path)
 *      WAIT_ACK → DRAIN → IDLE            (flush during pending)
 *      RESPOND → IDLE                     (normal or flush)
 *
 * Policy decision D1: standalone shim, single client, no RETRY.
 */

import f386_pkg::*;

module f386_lsq_to_memctrl_shim (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         flush,

    // --- Split-phase upstream (from arbiter) ---
    input  logic         req_valid,
    output logic         req_ready,
    input  mem_req_t     req,

    output logic         rsp_valid,
    input  logic         rsp_ready,
    output mem_rsp_t     rsp,

    // --- Legacy downstream (widened mem_ctrl data port) ---
    output logic [31:0]  data_addr,
    output logic [63:0]  data_wdata,
    output logic [7:0]   data_byte_en,
    output logic         data_req,
    output logic         data_wr,
    input  logic [63:0]  data_rdata,
    input  logic         data_ack,

    // --- Performance Counters ---
    output logic [31:0]  ctr_req_total,
    output logic [31:0]  ctr_rsp_total,
    output logic [31:0]  ctr_stall_cycles,
    output logic [31:0]  ctr_drain_events,
    output logic [31:0]  ctr_fifo_full_cyc
);

    // =========================================================
    // FSM States
    // =========================================================
    typedef enum logic [2:0] {
        S_IDLE     = 3'd0,
        S_ISSUE    = 3'd1,
        S_WAIT_ACK = 3'd2,
        S_RESPOND  = 3'd3,
        S_DRAIN    = 3'd4
    } shim_state_t;

    shim_state_t state_q, state_d;

    // =========================================================
    // Depth-2 Request FIFO
    // =========================================================
    localparam int FIFO_DEPTH = CONF_LSQ_OUTSTANDING_DEPTH;  // 4
    localparam int FIFO_PTR_W = $clog2(FIFO_DEPTH);          // 2

    // FIFO entry: packed subset of mem_req_t needed by FSM
    typedef struct packed {
        logic [31:0]                   addr;
        logic [63:0]                   wdata;
        logic [7:0]                    byte_en;
        logic                          wr;
        logic [CONF_MEM_REQ_ID_W-1:0] id;
    } fifo_entry_t;

    fifo_entry_t fifo_mem [FIFO_DEPTH];
    logic [FIFO_PTR_W-1:0] fifo_wr_ptr, fifo_rd_ptr;
    logic [FIFO_PTR_W:0]   fifo_count;

    wire fifo_full  = (fifo_count == FIFO_DEPTH[FIFO_PTR_W:0]);
    wire fifo_empty = (fifo_count == 0);

    // Upstream ready: accept when FIFO not full and not flushing
    assign req_ready = !fifo_full && !flush;

    // FIFO write
    wire fifo_wr_en = req_valid && req_ready;

    // FIFO read: pop when FSM is IDLE and FIFO not empty
    wire fifo_rd_en = (state_q == S_IDLE) && !fifo_empty && !flush;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
            fifo_count  <= '0;
        end else if (flush) begin
            // Discard un-issued entries on flush
            fifo_wr_ptr <= fifo_rd_ptr;
            fifo_count  <= '0;
        end else begin
            case ({fifo_wr_en, fifo_rd_en})
                2'b10: begin  // write only
                    fifo_wr_ptr <= fifo_wr_ptr + FIFO_PTR_W'(1);
                    fifo_count  <= fifo_count + (FIFO_PTR_W+1)'(1);
                end
                2'b01: begin  // read only
                    fifo_rd_ptr <= fifo_rd_ptr + FIFO_PTR_W'(1);
                    fifo_count  <= fifo_count - (FIFO_PTR_W+1)'(1);
                end
                2'b11: begin  // simultaneous read+write
                    fifo_wr_ptr <= fifo_wr_ptr + FIFO_PTR_W'(1);
                    fifo_rd_ptr <= fifo_rd_ptr + FIFO_PTR_W'(1);
                    // count unchanged
                end
                default: ;
            endcase
        end
    end

    // FIFO data write
    always_ff @(posedge clk) begin
        if (fifo_wr_en) begin
            fifo_mem[fifo_wr_ptr].addr    <= req.addr;
            fifo_mem[fifo_wr_ptr].wdata   <= req.wdata;
            fifo_mem[fifo_wr_ptr].byte_en <= req.byte_en;
            fifo_mem[fifo_wr_ptr].wr      <= (req.op == MEM_OP_ST);
            fifo_mem[fifo_wr_ptr].id      <= req.id;
        end
    end

    // FIFO read port
    wire fifo_entry_t fifo_head = fifo_mem[fifo_rd_ptr];

    // =========================================================
    // Latched Request Fields (from FIFO pop)
    // =========================================================
    logic [31:0]                     lat_addr;
    logic [63:0]                     lat_wdata;
    logic [7:0]                      lat_byte_en;
    logic                            lat_wr;
    logic [CONF_MEM_REQ_ID_W-1:0]   lat_id;

    // Latched read response
    logic [63:0]                     lat_rdata;

    // =========================================================
    // FSM
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state_q <= S_IDLE;
        else
            state_q <= state_d;
    end

    always_comb begin
        state_d = state_q;

        case (state_q)
            S_IDLE: begin
                if (fifo_rd_en)
                    state_d = S_ISSUE;
            end

            S_ISSUE: begin
                if (flush)
                    state_d = S_DRAIN;  // flush during issue — consume ack, no response
                else
                    state_d = S_WAIT_ACK;
            end

            S_WAIT_ACK: begin
                if (data_ack && flush)
                    state_d = S_IDLE;
                else if (data_ack)
                    state_d = S_RESPOND;
                else if (flush)
                    state_d = S_DRAIN;
            end

            S_DRAIN: begin
                if (data_ack)
                    state_d = S_IDLE;
            end

            S_RESPOND: begin
                if (flush || rsp_ready)
                    state_d = S_IDLE;
            end

            default: state_d = S_IDLE;
        endcase
    end

    // =========================================================
    // Request Latch (from FIFO pop)
    // =========================================================
    always_ff @(posedge clk) begin
        if (fifo_rd_en) begin
            lat_addr    <= fifo_head.addr;
            lat_wdata   <= fifo_head.wdata;
            lat_byte_en <= fifo_head.byte_en;
            lat_wr      <= fifo_head.wr;
            lat_id      <= fifo_head.id;
        end
    end

    // Latch read data on ack
    always_ff @(posedge clk) begin
        if (state_q == S_WAIT_ACK && data_ack)
            lat_rdata <= data_rdata;
    end

    // =========================================================
    // Response Output
    // =========================================================
    always_comb begin
        rsp           = '0;
        rsp_valid     = 1'b0;

        if (state_q == S_RESPOND) begin
            rsp_valid       = 1'b1;
            rsp.id          = lat_id;
            rsp.resp        = MEM_RESP_OK;
            rsp.last        = 1'b1;
            rsp.beat_idx    = 3'd0;
            rsp.rdata       = {64'd0, lat_rdata};
        end
    end

    // =========================================================
    // Downstream (mem_ctrl) Outputs
    // =========================================================
    assign data_req     = (state_q == S_ISSUE);
    assign data_addr    = lat_addr;
    assign data_wdata   = lat_wdata;
    assign data_byte_en = lat_byte_en;
    assign data_wr      = lat_wr;

    // =========================================================
    // Performance Counters (saturating 32-bit)
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctr_req_total    <= 32'd0;
            ctr_rsp_total    <= 32'd0;
            ctr_stall_cycles <= 32'd0;
            ctr_drain_events <= 32'd0;
            ctr_fifo_full_cyc<= 32'd0;
        end else begin
            // S_ISSUE transition = request issued to mem_ctrl
            if (state_q == S_IDLE && state_d == S_ISSUE && ctr_req_total != 32'hFFFF_FFFF)
                ctr_req_total <= ctr_req_total + 32'd1;

            // Response consumed by upstream
            if (state_q == S_RESPOND && rsp_ready && !flush && ctr_rsp_total != 32'hFFFF_FFFF)
                ctr_rsp_total <= ctr_rsp_total + 32'd1;

            // Upstream stall: has request but we can't accept
            if (req_valid && !req_ready && ctr_stall_cycles != 32'hFFFF_FFFF)
                ctr_stall_cycles <= ctr_stall_cycles + 32'd1;

            // Drain event: flush during WAIT_ACK
            if (state_q == S_WAIT_ACK && flush && !data_ack && ctr_drain_events != 32'hFFFF_FFFF)
                ctr_drain_events <= ctr_drain_events + 32'd1;

            // FIFO full cycle
            if (fifo_full && ctr_fifo_full_cyc != 32'hFFFF_FFFF)
                ctr_fifo_full_cyc <= ctr_fifo_full_cyc + 32'd1;
        end
    end

endmodule
