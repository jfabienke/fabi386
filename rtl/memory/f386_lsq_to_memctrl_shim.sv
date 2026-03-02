/*
 * fabi386: LSQ-to-MemCtrl Shim (P2 Step 2a)
 * -------------------------------------------
 * Translates a single mem_req_t / mem_rsp_t split-phase channel
 * (from LSQ) into the legacy mem_ctrl data-port protocol (widened
 * to 64-bit in P2).
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

    // --- Split-phase upstream (from LSQ) ---
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
    input  logic         data_ack
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
    // Latched Request Fields
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
                if (req_valid && !flush)
                    state_d = S_ISSUE;
            end

            S_ISSUE: begin
                state_d = S_WAIT_ACK;
            end

            S_WAIT_ACK: begin
                if (data_ack && flush)
                    state_d = S_IDLE;     // Ack consumed, no stale ack to drain
                else if (data_ack)
                    state_d = S_RESPOND;
                else if (flush)
                    state_d = S_DRAIN;    // No ack yet — must absorb stale ack
            end

            S_DRAIN: begin
                // Absorb stale ack before returning to idle
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
    // Request Latch
    // =========================================================
    always_ff @(posedge clk) begin
        if (state_q == S_IDLE && req_valid && !flush) begin
            lat_addr    <= req.addr;
            lat_wdata   <= req.wdata;
            lat_byte_en <= req.byte_en;
            lat_wr      <= (req.op == MEM_OP_ST);
            lat_id      <= req.id;
        end
    end

    // Latch read data on ack
    always_ff @(posedge clk) begin
        if (state_q == S_WAIT_ACK && data_ack)
            lat_rdata <= data_rdata;
    end

    // =========================================================
    // Upstream Handshake
    // =========================================================
    assign req_ready = (state_q == S_IDLE) && !flush;

    // Response output
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
    // Assert data_req for exactly one cycle in S_ISSUE
    assign data_req     = (state_q == S_ISSUE);
    assign data_addr    = lat_addr;
    assign data_wdata   = lat_wdata;
    assign data_byte_en = lat_byte_en;
    assign data_wr      = lat_wr;

endmodule
