/*
 * fabi386: Shim Flush/Grant/Ack Race Test Wrapper
 * ------------------------------------------------
 * Clock/reset and scenario sequencing are driven from C++.
 * This wrapper exposes counters and key handshake signals while embedding a
 * minimal downstream model that produces data_gnt/data_ack.
 */

import f386_pkg::*;

module shim_flush_race_tb (
    input  logic        clk,
    input  logic        rst_n,

    // Test controls
    input  logic        tb_flush,
    input  logic        tb_req_valid,
    input  logic [31:0] tb_req_addr,
    input  logic [5:0]  tb_req_id,
    input  logic        tb_req_is_store,
    input  logic        tb_dn_busy,
    input  logic        tb_rsp_ready,

    // Observability
    output logic        tb_req_ready,
    output logic        tb_rsp_valid,
    output logic [5:0]  tb_rsp_id,
    output logic [5:0]  tb_last_rsp_id,
    output logic        tb_data_req,
    output logic        tb_data_gnt,
    output logic        tb_data_ack,
    output logic [31:0] tb_grant_cnt,
    output logic [31:0] tb_ack_cnt,
    output logic [31:0] tb_rsp_cnt
);
    // ---------------------------------------------------------------------
    // Shim upstream/downstream signals
    // ---------------------------------------------------------------------
    mem_req_t req;
    mem_rsp_t rsp;
    logic     req_ready;
    logic     rsp_valid;

    logic [31:0] data_addr;
    logic [63:0] data_wdata;
    logic [7:0]  data_byte_en;
    logic        data_req;
    logic        data_wr;
    logic        data_cacheable;
    logic        data_strong_order;
    logic [63:0] data_rdata;
    logic        data_ack;
    logic        data_gnt;

    logic [31:0] ctr_req_total;
    logic [31:0] ctr_rsp_total;
    logic [31:0] ctr_stall_cycles;
    logic [31:0] ctr_drain_events;
    logic [31:0] ctr_fifo_full_cyc;

    // Request builder
    always_comb begin
        req = '0;
        req.id           = tb_req_id;
        req.op           = tb_req_is_store ? MEM_OP_ST : MEM_OP_LD;
        req.addr         = tb_req_addr;
        req.size         = 2'd2;
        req.byte_en      = tb_req_is_store ? 8'hFF : 8'h00;
        req.wdata        = 64'h1122_3344_5566_7788;
        req.burst_len    = 3'd0;
        req.cacheable    = 1'b1;
        req.strong_order = 1'b0;
    end

    f386_lsq_to_memctrl_shim dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .flush            (tb_flush),
        .req_valid        (tb_req_valid),
        .req_ready        (req_ready),
        .req              (req),
        .rsp_valid        (rsp_valid),
        .rsp_ready        (tb_rsp_ready),
        .rsp              (rsp),
        .data_addr        (data_addr),
        .data_wdata       (data_wdata),
        .data_byte_en     (data_byte_en),
        .data_req         (data_req),
        .data_wr          (data_wr),
        .data_cacheable   (data_cacheable),
        .data_strong_order(data_strong_order),
        .data_rdata       (data_rdata),
        .data_ack         (data_ack),
        .data_gnt         (data_gnt),
        .ctr_req_total    (ctr_req_total),
        .ctr_rsp_total    (ctr_rsp_total),
        .ctr_stall_cycles (ctr_stall_cycles),
        .ctr_drain_events (ctr_drain_events),
        .ctr_fifo_full_cyc(ctr_fifo_full_cyc)
    );

    // ---------------------------------------------------------------------
    // Minimal downstream model
    // ---------------------------------------------------------------------
    logic       dn_inflight;
    logic [3:0] dn_ack_countdown;
    localparam int ACK_LAT = 3;

    // Grant pulses when request is accepted by downstream.
    assign data_gnt = rst_n && !dn_inflight && data_req && !tb_dn_busy;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dn_inflight      <= 1'b0;
            dn_ack_countdown <= '0;
            data_ack         <= 1'b0;
            data_rdata       <= 64'd0;
            tb_grant_cnt     <= 32'd0;
            tb_ack_cnt       <= 32'd0;
        end else begin
            data_ack <= 1'b0;

            if (data_gnt) begin
                dn_inflight      <= 1'b1;
                dn_ack_countdown <= ACK_LAT[3:0];
                tb_grant_cnt     <= tb_grant_cnt + 32'd1;
            end

            if (dn_inflight) begin
                if (dn_ack_countdown == 0) begin
                    data_ack     <= 1'b1;
                    data_rdata   <= 64'hABCD_0000_0000_0000 | {32'd0, tb_grant_cnt};
                    dn_inflight  <= 1'b0;
                    tb_ack_cnt   <= tb_ack_cnt + 32'd1;
                end else begin
                    dn_ack_countdown <= dn_ack_countdown - 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tb_rsp_cnt <= 32'd0;
            tb_last_rsp_id <= '0;
        end else if (rsp_valid && tb_rsp_ready) begin
            tb_rsp_cnt <= tb_rsp_cnt + 32'd1;
            tb_last_rsp_id <= rsp.id;
        end
    end

    // ---------------------------------------------------------------------
    // Outputs to C++
    // ---------------------------------------------------------------------
    assign tb_req_ready = req_ready;
    assign tb_rsp_valid = rsp_valid;
    assign tb_rsp_id    = rsp.id;
    assign tb_data_req  = data_req;
    assign tb_data_gnt  = data_gnt;
    assign tb_data_ack  = data_ack;

endmodule
