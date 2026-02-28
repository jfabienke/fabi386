/*
 * fabi386: 8237 DMA Controller Stub - v1.0
 * ------------------------------------------
 * Minimal stub for the dual 8237A DMA controllers found in the AT.
 * Returns 0x00 on all reads and silently ignores all writes.
 *
 * I/O port ranges handled:
 *   0x00-0x0F  DMA Controller 1 (channels 0-3, 8-bit)
 *   0x80-0x8F  DMA Page Registers
 *   0xC0-0xDF  DMA Controller 2 (channels 4-7, 16-bit)
 *
 * DOS and the BIOS probe these ports during POST. Returning 0x00
 * causes DMA to appear "idle / complete" and prevents hangs.
 * Actual DMA transfers use PIO through the IDE controller.
 * Full 8237 DMA emulation is deferred to Phase P2.
 */

import f386_pkg::*;

module f386_dma_stub (
    input  logic        clk,
    input  logic        rst_n,

    // I/O port interface
    input  logic [15:0] io_addr,
    input  logic [7:0]  io_wdata,
    output logic [7:0]  io_rdata,
    input  logic        io_wr,
    input  logic        io_rd,
    input  logic        io_cs
);

    // All reads return 0x00, all writes are ignored.
    // The io_cs signal is asserted by the SoC address decoder when
    // io_addr falls within any of the three DMA port ranges.

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            io_rdata <= 8'h00;
        end else begin
            if (io_cs && io_rd)
                io_rdata <= 8'h00;
        end
    end

    // Writes are intentionally ignored (no register state to maintain).
    // Synthesis will optimize away the io_wdata and io_wr connections.

endmodule
