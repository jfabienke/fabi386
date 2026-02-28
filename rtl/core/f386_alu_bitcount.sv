/*
 * fabi386: Bit-Count Execution Unit
 * Phase P1.8: Pentium-Era ISA Extensions
 *
 * Combinational module implementing:
 *   00 = POPCNT  — population count (parallel tree)
 *   01 = LZCNT   — leading zero count (priority encoder)
 *   10 = TZCNT   — trailing zero count (priority encoder on reversed input)
 *
 * Operand size controlled by opsz:
 *   00 = 8-bit,  01 = 16-bit,  10/11 = 32-bit
 *
 * Flags: ZF set if result==0; CF set if source==0 (LZCNT/TZCNT only);
 *        OF/SF/AF/PF cleared.
 */

import f386_pkg::*;

module f386_alu_bitcount (
    input  logic [31:0] op_a,
    input  logic [1:0]  bitcount_op,   // 00=POPCNT, 01=LZCNT, 10=TZCNT
    input  logic [1:0]  opsz,          // 00=8, 01=16, 10/11=32
    output logic [31:0] result,
    output logic [5:0]  flags_out      // {OF, SF, ZF, AF, PF, CF}
);

    // Effective operand (masked to size)
    logic [31:0] src;
    always_comb begin
        case (opsz)
            2'b00:   src = {24'h0, op_a[7:0]};
            2'b01:   src = {16'h0, op_a[15:0]};
            default: src = op_a;
        endcase
    end

    // Operand width for LZCNT/TZCNT normalization
    logic [5:0] op_width;
    always_comb begin
        case (opsz)
            2'b00:   op_width = 6'd8;
            2'b01:   op_width = 6'd16;
            default: op_width = 6'd32;
        endcase
    end

    // --- POPCNT: parallel tree population count ---
    logic [5:0] popcnt_res;
    always_comb begin
        popcnt_res = 6'd0;
        for (int i = 0; i < 32; i++) begin
            popcnt_res = popcnt_res + {5'd0, src[i]};
        end
    end

    // --- LZCNT: leading zero count via priority scan from MSB ---
    logic [5:0] lzcnt_res;
    logic        lz_found;
    always_comb begin
        lzcnt_res = op_width;  // Default: all zeros → result = width
        lz_found  = 1'b0;
        for (int i = 31; i >= 0; i--) begin
            if (!lz_found && src[i]) begin
                lzcnt_res = op_width - 6'(i) - 6'd1;
                lz_found  = 1'b1;
            end
        end
    end

    // --- TZCNT: trailing zero count via priority scan from LSB ---
    logic [5:0] tzcnt_res;
    logic        tz_found;
    always_comb begin
        tzcnt_res = op_width;  // Default: all zeros → result = width
        tz_found  = 1'b0;
        for (int i = 0; i < 32; i++) begin
            if (!tz_found && src[i]) begin
                tzcnt_res = 6'(i);
                tz_found  = 1'b1;
            end
        end
    end

    // --- Result mux ---
    logic [5:0] raw_result;
    always_comb begin
        case (bitcount_op)
            2'b00:   raw_result = popcnt_res;
            2'b01:   raw_result = lzcnt_res;
            2'b10:   raw_result = tzcnt_res;
            default: raw_result = 6'd0;
        endcase
    end

    assign result = {26'd0, raw_result};

    // --- Flags ---
    // flags_out = {OF, SF, ZF, AF, PF, CF}
    wire zf = (raw_result == 6'd0);
    wire cf = (bitcount_op != 2'b00) && (src == 32'd0);  // CF=1 if source==0 (LZCNT/TZCNT)

    assign flags_out = {1'b0, 1'b0, zf, 1'b0, 1'b0, cf};

endmodule
