/*
 * fabi386: Simple Dual-Port Block RAM (Plain Verilog)
 * ---------------------------------------------------
 * Quartus 17 M10K inference wrapper.
 * Written in plain .v to bypass sv2v — guaranteed inference pattern.
 *
 * Port A: write-only (synchronous)
 * Port B: read-only  (synchronous, 1-cycle latency)
 *
 * Parameters:
 *   ADDR_W — address width (depth = 2^ADDR_W)
 *   DATA_W — data width per entry
 */

module f386_bram_sdp #(
    parameter ADDR_W = 10,
    parameter DATA_W = 64
) (
    input  wire                clk,

    // Write port
    input  wire [ADDR_W-1:0]  wr_addr,
    input  wire [DATA_W-1:0]  wr_data,
    input  wire                wr_en,

    // Read port
    input  wire [ADDR_W-1:0]  rd_addr,
    output reg  [DATA_W-1:0]  rd_data
);

    (* ramstyle = "M10K, no_rw_check" *)
    reg [DATA_W-1:0] mem [0:(1 << ADDR_W)-1];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr];
    end

endmodule
