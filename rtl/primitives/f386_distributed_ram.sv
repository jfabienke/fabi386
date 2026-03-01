/*
 * fabi386: Distributed (LUT-based) Multi-Port RAM
 * ------------------------------------------------
 * Synthesizes to Cyclone V ALM LUT-RAM fabric.
 * Multi-read achieved via data replication (one copy per read port).
 *
 * Reference: rsd Processor/Src/Primitives/RAM.sv
 *
 * Parameters:
 *   ADDR_WIDTH  — address bits
 *   DATA_WIDTH  — data bits per entry
 *   READ_PORTS  — number of combinational read ports
 *
 * Write port: 1 synchronous write
 * Read ports: READ_PORTS asynchronous (combinational) reads
 */

import f386_pkg::*;

module f386_distributed_ram #(
    parameter int ADDR_WIDTH = 5,
    parameter int DATA_WIDTH = 32,
    parameter int READ_PORTS = 2
)(
    input  logic                    clk,

    // Write port (single, synchronous)
    input  logic                    wr_en,
    input  logic [ADDR_WIDTH-1:0]   wr_addr,
    input  logic [DATA_WIDTH-1:0]   wr_data,

    // Read ports (multiple, asynchronous)
    input  logic [ADDR_WIDTH-1:0]   rd_addr [READ_PORTS],
    output logic [DATA_WIDTH-1:0]   rd_data [READ_PORTS]
);

    localparam int DEPTH = 1 << ADDR_WIDTH;

    // One replicated copy per read port for multi-read synthesis.
    // Quartus infers distributed (LUT) RAM when array is small and
    // reads are combinational.
    (* ramstyle = "logic" *)
    logic [DATA_WIDTH-1:0] mem [READ_PORTS][DEPTH];

    // Synchronous write — replicate across all copies
    always_ff @(posedge clk) begin
        if (wr_en) begin
            for (int p = 0; p < READ_PORTS; p++) begin
                mem[p][wr_addr] <= wr_data;
            end
        end
    end

    // Asynchronous (combinational) reads — one per port
    genvar p;
    generate
        for (p = 0; p < READ_PORTS; p++) begin : gen_rd
            assign rd_data[p] = mem[p][rd_addr[p]];
        end
    endgenerate

    // ---------------------------------------------------------------
    // Debug: parameter sanity check
    // ---------------------------------------------------------------
    initial begin
        assert (ADDR_WIDTH >= 1 && ADDR_WIDTH <= 8)
            else $error("f386_distributed_ram: ADDR_WIDTH out of range");
        assert (READ_PORTS >= 1 && READ_PORTS <= 4)
            else $error("f386_distributed_ram: READ_PORTS out of range");
    end

endmodule
