/*
 * fabi386: Integer ALU (v18.0)
 * ----------------------------
 * Performs 8/16/32-bit arithmetic and logic operations for the U/V pipes.
 *
 * flags_out layout (matches x86 EFLAGS bit positions):
 *   [0] CF — Carry Flag
 *   [1] PF — Parity Flag    (even parity of result[7:0])
 *   [2] AF — Auxiliary Flag  (half-carry out of bit 3)
 *   [3] ZF — Zero Flag
 *   [4] SF — Sign Flag
 *   [5] OF — Overflow Flag
 *
 * alu_op encoding:
 *   [3:0] — operation select
 *   [5:4] — operand size: 00=32-bit, 01=16-bit, 10=8-bit, 11=reserved
 */

module f386_alu (
    input  [31:0] op_a,
    input  [31:0] op_b,
    input  [5:0]  alu_op,
    input         cin,        // Carry-in (from EFLAGS CF for ADC/SBB)
    output [31:0] result,
    output [5:0]  flags_out
);

    // --- Operation Decode ---
    wire [3:0] op    = alu_op[3:0];
    wire [1:0] opsz  = alu_op[5:4];

    // --- Size-Masked Operands ---
    reg [31:0] a, b;
    reg [4:0]  msb;  // Bit position of the sign bit (7, 15, or 31)

    always @(*) begin
        case (opsz)
            2'b10: begin  // 8-bit
                a   = {24'd0, op_a[7:0]};
                b   = {24'd0, op_b[7:0]};
                msb = 5'd7;
            end
            2'b01: begin  // 16-bit
                a   = {16'd0, op_a[15:0]};
                b   = {16'd0, op_b[15:0]};
                msb = 5'd15;
            end
            default: begin  // 32-bit
                a   = op_a;
                b   = op_b;
                msb = 5'd31;
            end
        endcase
    end

    // --- 33-bit Adder for Carry/Overflow ---
    wire [32:0] add_result = {1'b0, a} + {1'b0, b};
    wire [32:0] sub_result = {1'b0, a} - {1'b0, b};
    wire [32:0] adc_result = {1'b0, a} + {1'b0, b} + {32'd0, cin};
    wire [32:0] sbb_result = {1'b0, a} - {1'b0, b} - {32'd0, cin};

    // --- Half-carry (AF): carry out of bit 3 ---
    wire af_add = (a[3:0] + b[3:0]) > 5'hF;
    wire af_adc = (a[3:0] + b[3:0] + {3'd0, cin}) > 5'hF;
    wire af_sub = a[3:0] < b[3:0];
    wire af_sbb = a[3:0] < (b[3:0] + {3'd0, cin});

    // --- Operation Constants ---
    localparam OP_ADD  = 4'h0;
    localparam OP_SUB  = 4'h1;
    localparam OP_AND  = 4'h2;
    localparam OP_OR   = 4'h3;
    localparam OP_XOR  = 4'h4;
    localparam OP_SHL  = 4'h5;
    localparam OP_SHR  = 4'h6;
    localparam OP_SAR  = 4'h7;
    localparam OP_ADC  = 4'h8;
    localparam OP_SBB  = 4'h9;
    localparam OP_NOT  = 4'hA;
    localparam OP_NEG  = 4'hB;
    localparam OP_INC  = 4'hC;
    localparam OP_DEC  = 4'hD;
    localparam OP_ROL  = 4'hE;
    localparam OP_ROR  = 4'hF;

    // Shift amount clamped to 0-31
    wire [4:0] shamt = op_b[4:0];

    // Signed operand A for SAR
    wire signed [31:0] a_signed = a;

    // --- ALU Core ---
    reg [31:0] raw_result;
    reg [32:0] shl_wide;   // 33-bit shift result for SHL carry capture
    reg [4:0]  rol_count;  // Size-masked rotate count
    reg [4:0]  ror_count;
    reg        cf_raw;
    reg        af_raw;
    reg        of_raw;

    always @(*) begin
        raw_result = 32'd0;
        shl_wide   = 33'd0;
        rol_count  = 5'd0;
        ror_count  = 5'd0;
        cf_raw     = 1'b0;
        af_raw     = 1'b0;
        of_raw     = 1'b0;

        case (op)
            // ---- Arithmetic ----
            OP_ADD: begin
                raw_result = add_result[31:0];
                cf_raw     = add_result[msb + 1];
                af_raw     = af_add;
                of_raw     = (a[msb] == b[msb]) && (raw_result[msb] != a[msb]);
            end

            OP_ADC: begin
                raw_result = adc_result[31:0];
                cf_raw     = adc_result[msb + 1];
                af_raw     = af_adc;
                of_raw     = (a[msb] == b[msb]) && (raw_result[msb] != a[msb]);
            end

            OP_SUB: begin
                raw_result = sub_result[31:0];
                cf_raw     = sub_result[msb + 1];  // Borrow
                af_raw     = af_sub;
                of_raw     = (a[msb] != b[msb]) && (raw_result[msb] != a[msb]);
            end

            OP_SBB: begin
                raw_result = sbb_result[31:0];
                cf_raw     = sbb_result[msb + 1];
                af_raw     = af_sbb;
                of_raw     = (a[msb] != b[msb]) && (raw_result[msb] != a[msb]);
            end

            OP_INC: begin
                raw_result = a + 32'd1;
                cf_raw     = cin;  // INC preserves CF
                af_raw     = (a[3:0] == 4'hF);
                of_raw     = (a[msb] == 1'b0) && (raw_result[msb] == 1'b1);
            end

            OP_DEC: begin
                raw_result = a - 32'd1;
                cf_raw     = cin;  // DEC preserves CF
                af_raw     = (a[3:0] == 4'h0);
                of_raw     = (a[msb] == 1'b1) && (raw_result[msb] == 1'b0);
            end

            OP_NEG: begin
                raw_result = ~a + 32'd1;
                cf_raw     = (a != 32'd0);
                af_raw     = (a[3:0] != 4'h0);
                of_raw     = (a[msb] == 1'b1) && (raw_result[msb] == 1'b1);
            end

            // ---- Logic (CF=0, OF=0, AF undefined per Intel spec) ----
            OP_AND: begin
                raw_result = a & b;
            end

            OP_OR: begin
                raw_result = a | b;
            end

            OP_XOR: begin
                raw_result = a ^ b;
            end

            OP_NOT: begin
                raw_result = ~a;
                cf_raw     = cin;  // NOT affects no flags
                af_raw     = 1'b0;
                of_raw     = 1'b0;
            end

            // ---- Shifts ----
            OP_SHL: begin
                // Use 33-bit shift to capture the carry-out cleanly
                shl_wide   = {1'b0, a} << shamt;
                raw_result = shl_wide[31:0];
                cf_raw     = (shamt != 5'd0) ? shl_wide[msb + 1] : cin;
                of_raw     = (shamt == 5'd1) ? (raw_result[msb] ^ cf_raw) : 1'b0;
            end

            OP_SHR: begin
                raw_result = a >> shamt;
                cf_raw     = (shamt != 5'd0) ? a[shamt - 5'd1] : cin;
                of_raw     = (shamt == 5'd1) ? a[msb] : 1'b0;
            end

            OP_SAR: begin
                raw_result = a_signed >>> shamt;
                cf_raw     = (shamt != 5'd0) ? a[shamt - 5'd1] : cin;
                of_raw     = 1'b0;  // Always 0 for SAR
            end

            // ---- Rotates (size-aware) ----
            // x86 masks rotate count: mod 8 for 8-bit, mod 16 for 16-bit, mod 32 for 32-bit
            OP_ROL: begin
                case (opsz)
                    2'b10: begin  // 8-bit
                        rol_count  = {2'd0, shamt[2:0]};  // mod 8
                        raw_result = {24'd0,
                                      a[7:0] << rol_count[2:0] |
                                      a[7:0] >> (3'd8 - rol_count[2:0])};
                    end
                    2'b01: begin  // 16-bit
                        rol_count  = {1'd0, shamt[3:0]};  // mod 16
                        raw_result = {16'd0,
                                      a[15:0] << rol_count[3:0] |
                                      a[15:0] >> (4'd16 - rol_count[3:0])};
                    end
                    default: begin  // 32-bit
                        rol_count  = shamt;
                        raw_result = (a << shamt) | (a >> (6'd32 - {1'b0, shamt}));
                    end
                endcase
                cf_raw = (shamt != 5'd0) ? raw_result[0] : cin;
                of_raw = (shamt == 5'd1) ? (raw_result[msb] ^ raw_result[0]) : 1'b0;
            end

            OP_ROR: begin
                case (opsz)
                    2'b10: begin  // 8-bit
                        ror_count  = {2'd0, shamt[2:0]};
                        raw_result = {24'd0,
                                      a[7:0] >> ror_count[2:0] |
                                      a[7:0] << (3'd8 - ror_count[2:0])};
                    end
                    2'b01: begin  // 16-bit
                        ror_count  = {1'd0, shamt[3:0]};
                        raw_result = {16'd0,
                                      a[15:0] >> ror_count[3:0] |
                                      a[15:0] << (4'd16 - ror_count[3:0])};
                    end
                    default: begin  // 32-bit
                        ror_count  = shamt;
                        raw_result = (a >> shamt) | (a << (6'd32 - {1'b0, shamt}));
                    end
                endcase
                cf_raw = (shamt != 5'd0) ? raw_result[msb] : cin;
                // OF for ROR count=1: old MSB XOR new MSB
                of_raw = (shamt == 5'd1) ? (a[msb] ^ raw_result[msb]) : 1'b0;
            end

            default: begin
                raw_result = 32'd0;
            end
        endcase
    end

    // --- Size Masking on Result ---
    reg [31:0] sized_result;
    always @(*) begin
        case (opsz)
            2'b10:   sized_result = {24'd0, raw_result[7:0]};
            2'b01:   sized_result = {16'd0, raw_result[15:0]};
            default: sized_result = raw_result;
        endcase
    end

    assign result = sized_result;

    // --- Parity Flag ---
    // PF is computed on the low 8 bits regardless of operand size
    wire pf = ~^raw_result[7:0];  // Even parity: XOR-reduce then invert

    // --- Sign Flag ---
    wire sf = raw_result[msb];

    // --- Zero Flag ---
    reg zf;
    always @(*) begin
        case (opsz)
            2'b10:   zf = (raw_result[7:0]  == 8'd0);
            2'b01:   zf = (raw_result[15:0] == 16'd0);
            default: zf = (raw_result[31:0] == 32'd0);
        endcase
    end

    // --- Flag Output ---
    // [0] CF  [1] PF  [2] AF  [3] ZF  [4] SF  [5] OF
    assign flags_out[0] = cf_raw;
    assign flags_out[1] = pf;
    assign flags_out[2] = af_raw;
    assign flags_out[3] = zf;
    assign flags_out[4] = sf;
    assign flags_out[5] = of_raw;

endmodule
