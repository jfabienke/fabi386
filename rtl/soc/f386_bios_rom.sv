/*
 * fabi386: Diagnostics BIOS ROM
 * ------------------------------
 * 16 KB read-only memory mapped at physical 0xFC000..0xFFFFF. Populated
 * at elaboration time from asm/diagnostic.hex (assembled via NASM).
 *
 * Interface is a single-cycle synchronous read port, 64 bits wide — the
 * same natural access width as the DDRAM backend. This matches the byte-
 * address-to-word-address convention used by f386_mem_sys_to_ddram
 * (29-bit word address = byte_addr[31:3]).
 *
 * BRAM sizing: 2048 × 64 bits = 16 Kbit of data → 2 M10K blocks inferred
 * by Quartus (a single M10K is 10 Kbit).
 */

module f386_bios_rom (
    input  logic         clk,
    input  logic [10:0]  rd_addr,      // 2048 entries of 64-bit each
    output logic [63:0]  rd_data
);

    localparam int DEPTH  = 2048;       // 16 KB / 8 B/word
    localparam int ADDR_W = 11;         // $clog2(2048)

    (* ramstyle = "M10K, no_rw_check" *)
    logic [63:0] mem [0:DEPTH-1];

    initial begin
        $readmemh("asm/diagnostic.hex", mem);
    end

    always_ff @(posedge clk) begin
        rd_data <= mem[rd_addr];
    end

endmodule
