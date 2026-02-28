/*
 * fabi386: Block RAM (M10K) Wrapper
 * ----------------------------------
 * Infers Cyclone V M10K embedded memory blocks.
 * Single-port or simple dual-port with byte-enable support.
 *
 * Reference: rsd Processor/Src/Primitives/RAM.sv
 *
 * Key synthesis attributes for Cyclone V:
 *   - ramstyle = "M10K, no_rw_check" — force M10K inference, no R/W collision check
 *   - READ_DURING_WRITE_MODE = "DONT_CARE" — allows maximum Fmax
 *
 * Parameters:
 *   ADDR_WIDTH  — address bits
 *   DATA_WIDTH  — data bits per entry
 *   INIT_FILE   — optional hex file for initialization ("" = zero-init)
 */

module f386_block_ram #(
    parameter int    ADDR_WIDTH = 10,
    parameter int    DATA_WIDTH = 32,
    parameter string INIT_FILE  = ""
)(
    input  logic                    clk,

    // Port A: Read/Write
    input  logic                    a_wr_en,
    input  logic [ADDR_WIDTH-1:0]   a_addr,
    input  logic [DATA_WIDTH-1:0]   a_wdata,
    output logic [DATA_WIDTH-1:0]   a_rdata,

    // Port B: Read-only (simple dual-port)
    input  logic [ADDR_WIDTH-1:0]   b_addr,
    output logic [DATA_WIDTH-1:0]   b_rdata
);

    localparam int DEPTH = 1 << ADDR_WIDTH;

    // Force M10K inference, suppress read-during-write hazard checking
    // for maximum Fmax. Callers must ensure no simultaneous R/W to same address
    // or accept don't-care behavior.
    (* ramstyle = "M10K, no_rw_check" *)
    logic [DATA_WIDTH-1:0] mem [DEPTH];

    // Optional initialization from hex file
    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    // Port A: synchronous read + write
    always_ff @(posedge clk) begin
        if (a_wr_en)
            mem[a_addr] <= a_wdata;
        a_rdata <= mem[a_addr];
    end

    // Port B: synchronous read-only
    always_ff @(posedge clk) begin
        b_rdata <= mem[b_addr];
    end

endmodule
