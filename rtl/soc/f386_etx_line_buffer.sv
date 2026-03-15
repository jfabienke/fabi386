/*
 * fabi386: ETX Display Engine — Double Line Buffer
 * --------------------------------------------------
 * Ping-pong line buffers: 2 x 1920 x 24-bit = 92,160 bits → ~9 M10K.
 * Resource stub for Quartus estimation.
 */

import f386_pkg::*;

module f386_etx_line_buffer (
    input  logic         clk,
    input  logic         rst_n,

    // Write port (from scanout pipe)
    input  logic [10:0]  wr_x,
    input  logic [23:0]  wr_color,
    input  logic         wr_valid,

    // Read port (to video output)
    input  logic [10:0]  rd_x,
    output logic [23:0]  rd_color,

    // Line swap (at end of each scanline)
    input  logic         line_swap
);

    localparam int LINE_W = 1920;
    localparam int ADDR_W = 11;  // $clog2(1920) = 11
    localparam int DATA_W = 24;

    // =========================================================================
    //  Ping-pong select
    // =========================================================================
    logic ping_pong_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ping_pong_r <= 1'b0;
        else if (line_swap)
            ping_pong_r <= ~ping_pong_r;
    end

    // =========================================================================
    //  Line buffer A — 1920 x 24-bit
    // =========================================================================
    logic [ADDR_W-1:0] buf_a_wr_addr, buf_a_rd_addr;
    logic [DATA_W-1:0] buf_a_wr_data, buf_a_rd_data;
    logic              buf_a_wr_en;

    f386_bram_sdp #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) line_buf_a (
        .clk     (clk),
        .wr_addr (buf_a_wr_addr),
        .wr_data (buf_a_wr_data),
        .wr_en   (buf_a_wr_en),
        .rd_addr (buf_a_rd_addr),
        .rd_data (buf_a_rd_data)
    );

    // =========================================================================
    //  Line buffer B — 1920 x 24-bit
    // =========================================================================
    logic [ADDR_W-1:0] buf_b_wr_addr, buf_b_rd_addr;
    logic [DATA_W-1:0] buf_b_wr_data, buf_b_rd_data;
    logic              buf_b_wr_en;

    f386_bram_sdp #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) line_buf_b (
        .clk     (clk),
        .wr_addr (buf_b_wr_addr),
        .wr_data (buf_b_wr_data),
        .wr_en   (buf_b_wr_en),
        .rd_addr (buf_b_rd_addr),
        .rd_data (buf_b_rd_data)
    );

    // =========================================================================
    //  Port routing (ping-pong)
    // =========================================================================
    // ping_pong_r=0: write to A, read from B
    // ping_pong_r=1: write to B, read from A

    assign buf_a_wr_addr = wr_x[ADDR_W-1:0];
    assign buf_a_wr_data = wr_color;
    assign buf_a_wr_en   = wr_valid && !ping_pong_r;
    assign buf_a_rd_addr = rd_x[ADDR_W-1:0];

    assign buf_b_wr_addr = wr_x[ADDR_W-1:0];
    assign buf_b_wr_data = wr_color;
    assign buf_b_wr_en   = wr_valid && ping_pong_r;
    assign buf_b_rd_addr = rd_x[ADDR_W-1:0];

    assign rd_color = ping_pong_r ? buf_a_rd_data : buf_b_rd_data;

endmodule
