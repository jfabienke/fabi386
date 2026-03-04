/*
 * fabi386: L2 Split-Phase Cache Testbench Wrapper
 * ------------------------------------------------
 * Wraps f386_l2_cache_sp with a DDRAM model and test control signals.
 * Clock/reset and scenario sequencing driven from C++.
 */

import f386_pkg::*;

module l2_sp_tb (
    input  logic        clk,
    input  logic        rst_n,

    // --- Data port test controls ---
    input  logic        tb_data_req_valid,
    input  logic [31:0] tb_data_addr,
    input  logic [63:0] tb_data_wdata,
    input  logic [7:0]  tb_data_byte_en,
    input  logic        tb_data_wr,
    input  logic        tb_data_cacheable,
    input  logic [5:0]  tb_data_id,
    input  logic        tb_data_rsp_ready,

    // --- Data port observability ---
    output logic        tb_data_req_ready,
    output logic        tb_data_rsp_valid,
    output logic [5:0]  tb_data_rsp_id,
    output logic [63:0] tb_data_rsp_rdata,

    // --- DDRAM model controls ---
    input  logic [3:0]  tb_ddram_latency,   // Fill latency in cycles per beat

    // --- Counters ---
    output logic [31:0] tb_rsp_cnt,
    output logic [5:0]  tb_last_rsp_id,
    output logic [31:0] tb_cycle_cnt
);

    // -----------------------------------------------------------------
    // DUT wires
    // -----------------------------------------------------------------
    logic [31:0]  ifetch_addr;
    logic [127:0] ifetch_data;
    logic         ifetch_valid;
    logic         ifetch_req;

    mem_req_t     data_req;
    logic         data_req_valid;
    logic         data_req_ready;
    mem_rsp_t     data_rsp;
    logic         data_rsp_valid;
    logic         data_rsp_ready;

    logic [31:0]  pt_addr;
    logic [31:0]  pt_wdata;
    logic [31:0]  pt_rdata;
    logic         pt_req;
    logic         pt_wr;
    logic         pt_ack;

    logic [28:0]  ddram_addr;
    logic [7:0]   ddram_burstcnt;
    logic [63:0]  ddram_din;
    logic [7:0]   ddram_be;
    logic         ddram_we;
    logic         ddram_rd;
    logic [63:0]  ddram_dout;
    logic         ddram_dout_ready;
    logic         ddram_busy;

    // Tie off unused ports
    assign ifetch_req  = 1'b0;
    assign ifetch_addr = 32'd0;
    assign pt_req      = 1'b0;
    assign pt_wr       = 1'b0;
    assign pt_addr     = 32'd0;
    assign pt_wdata    = 32'd0;

    // Build mem_req_t from test inputs
    always_comb begin
        data_req           = '0;
        data_req.id        = tb_data_id;
        data_req.op        = tb_data_wr ? MEM_OP_ST : MEM_OP_LD;
        data_req.addr      = tb_data_addr;
        data_req.size      = 2'd2;  // 4B (TODO: expose as tb_data_size for sub-dword tests)
        data_req.byte_en   = tb_data_byte_en;
        data_req.wdata     = tb_data_wdata;
        data_req.burst_len = 3'd0;
        data_req.cacheable = tb_data_cacheable;
        data_req.strong_order = 1'b0;
    end

    assign data_req_valid  = tb_data_req_valid;
    assign data_rsp_ready  = tb_data_rsp_ready;

    // Outputs to C++
    assign tb_data_req_ready = data_req_ready;
    assign tb_data_rsp_valid = data_rsp_valid;
    assign tb_data_rsp_id    = data_rsp.id;
    assign tb_data_rsp_rdata = data_rsp.rdata[63:0];

    // -----------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------
    f386_l2_cache_sp dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .ifetch_addr      (ifetch_addr),
        .ifetch_data      (ifetch_data),
        .ifetch_valid     (ifetch_valid),
        .ifetch_req       (ifetch_req),
        .data_req_valid   (data_req_valid),
        .data_req_ready   (data_req_ready),
        .data_req         (data_req),
        .data_rsp_valid   (data_rsp_valid),
        .data_rsp_ready   (data_rsp_ready),
        .data_rsp         (data_rsp),
        .pt_addr          (pt_addr),
        .pt_wdata         (pt_wdata),
        .pt_rdata         (pt_rdata),
        .pt_req           (pt_req),
        .pt_wr            (pt_wr),
        .pt_ack           (pt_ack),
        .a20_gate         (1'b1),
        .ddram_addr       (ddram_addr),
        .ddram_burstcnt   (ddram_burstcnt),
        .ddram_din        (ddram_din),
        .ddram_be         (ddram_be),
        .ddram_we         (ddram_we),
        .ddram_rd         (ddram_rd),
        .ddram_dout       (ddram_dout),
        .ddram_dout_ready (ddram_dout_ready),
        .ddram_busy       (ddram_busy)
    );

    // -----------------------------------------------------------------
    // DDRAM Model
    // -----------------------------------------------------------------
    // Burst-capable DDRAM model with configurable latency.
    // Supports one outstanding burst at a time.
    // Reads return data = {addr[28:0], beat_idx[2:0], 32'hDD_000000 | addr[15:0]}
    // Writes are accepted and stored in a simple 256-entry assoc memory.

    localparam int DDRAM_STORE_DEPTH = 256;

    logic [28:0] dd_store_addr  [DDRAM_STORE_DEPTH];
    logic [63:0] dd_store_data  [DDRAM_STORE_DEPTH];
    logic        dd_store_valid [DDRAM_STORE_DEPTH];
    int          dd_store_wr_ptr;

    // Read burst state
    logic        dd_rd_active;
    logic [28:0] dd_rd_base_addr;
    logic [7:0]  dd_rd_burstcnt;
    logic [2:0]  dd_rd_beat;
    logic [3:0]  dd_rd_delay;

    // Write burst state
    logic        dd_wr_active;
    logic [2:0]  dd_wr_beat;
    logic [7:0]  dd_wr_burstcnt;
    logic [28:0] dd_wr_base_addr;

    // Busy only during read bursts. Write beats are accepted without backpressure
    // (matches MiSTer DDRAM: write FIFO doesn't stall for burst-4).
    assign ddram_busy = dd_rd_active;

    // Lookup stored data (for reads — returns stored value if written, else pattern)
    function automatic logic [63:0] ddram_lookup(input logic [28:0] addr);
        for (int i = 0; i < DDRAM_STORE_DEPTH; i++) begin
            if (dd_store_valid[i] && dd_store_addr[i] == addr)
                return dd_store_data[i];
        end
        // Default pattern: encode address in data for verification
        return {3'b0, addr, 32'hDD_000000 | {16'd0, addr[15:0]}};
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dd_rd_active     <= 1'b0;
            dd_wr_active     <= 1'b0;
            ddram_dout_ready <= 1'b0;
            ddram_dout       <= 64'd0;
            dd_store_wr_ptr  <= 0;
            for (int i = 0; i < DDRAM_STORE_DEPTH; i++)
                dd_store_valid[i] <= 1'b0;
        end else begin
            ddram_dout_ready <= 1'b0;

            // Accept read burst
            if (ddram_rd && !dd_rd_active && !dd_wr_active) begin
                dd_rd_active    <= 1'b1;
                dd_rd_base_addr <= ddram_addr;
                dd_rd_burstcnt  <= ddram_burstcnt;
                dd_rd_beat      <= 3'd0;
                dd_rd_delay     <= tb_ddram_latency;
            end

            // Accept write burst
            if (ddram_we && !dd_rd_active && !dd_wr_active) begin
                // First beat accepted immediately with the command
                dd_wr_active    <= (ddram_burstcnt > 8'd1);
                dd_wr_base_addr <= ddram_addr;
                dd_wr_burstcnt  <= ddram_burstcnt;
                dd_wr_beat      <= 3'd1;
                // Store first beat
                dd_store_addr[dd_store_wr_ptr]  <= ddram_addr;
                dd_store_data[dd_store_wr_ptr]  <= ddram_din;
                dd_store_valid[dd_store_wr_ptr] <= 1'b1;
                if (dd_store_wr_ptr < DDRAM_STORE_DEPTH - 1)
                    dd_store_wr_ptr <= dd_store_wr_ptr + 1;
            end

            // Continue write burst (subsequent beats)
            if (dd_wr_active && ddram_we) begin
                dd_store_addr[dd_store_wr_ptr]  <= dd_wr_base_addr + {26'd0, dd_wr_beat};
                dd_store_data[dd_store_wr_ptr]  <= ddram_din;
                dd_store_valid[dd_store_wr_ptr] <= 1'b1;
                if (dd_store_wr_ptr < DDRAM_STORE_DEPTH - 1)
                    dd_store_wr_ptr <= dd_store_wr_ptr + 1;
                if ({5'd0, dd_wr_beat} + 8'd1 >= dd_wr_burstcnt)
                    dd_wr_active <= 1'b0;
                else
                    dd_wr_beat <= dd_wr_beat + 3'd1;
            end

            // Read burst delivery with configurable latency
            if (dd_rd_active) begin
                if (dd_rd_delay != 4'd0) begin
                    dd_rd_delay <= dd_rd_delay - 4'd1;
                end else begin
                    ddram_dout_ready <= 1'b1;
                    ddram_dout       <= ddram_lookup(dd_rd_base_addr + {26'd0, dd_rd_beat});
                    if ({5'd0, dd_rd_beat} + 8'd1 >= dd_rd_burstcnt) begin
                        dd_rd_active <= 1'b0;
                    end else begin
                        dd_rd_beat  <= dd_rd_beat + 3'd1;
                        dd_rd_delay <= tb_ddram_latency;
                    end
                end
            end
        end
    end

    // -----------------------------------------------------------------
    // Response counter
    // -----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tb_rsp_cnt     <= 32'd0;
            tb_last_rsp_id <= 6'd0;
            tb_cycle_cnt   <= 32'd0;
        end else begin
            tb_cycle_cnt <= tb_cycle_cnt + 32'd1;
            if (data_rsp_valid && data_rsp_ready) begin
                tb_rsp_cnt     <= tb_rsp_cnt + 32'd1;
                tb_last_rsp_id <= data_rsp.id;
            end
        end
    end

endmodule
