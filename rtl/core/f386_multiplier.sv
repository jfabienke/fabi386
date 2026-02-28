/*
 * fabi386: DSP-Backed Multiplier (v1.0)
 * ----------------------------------------
 * Handles 8/16/32-bit signed and unsigned multiplication.
 * Uses Cyclone V DSP blocks for 18×18 multiply, with a
 * soft 32×32 decomposition using 4 DSP multiplies.
 *
 * Supports:
 *   MUL  r/m8   (AL × r/m8   → AX)
 *   MUL  r/m16  (AX × r/m16  → DX:AX)
 *   MUL  r/m32  (EAX × r/m32 → EDX:EAX)
 *   IMUL r/m8   (same but signed)
 *   IMUL r/m16  (same but signed)
 *   IMUL r/m32  (same but signed)
 *
 * 2-cycle pipeline: cycle 1 = DSP multiply, cycle 2 = accumulate partial products.
 * Flags: CF=OF=1 if upper half non-zero (unsigned) or not sign-extension (signed).
 *
 * Reference: Intel 386 manual, Cyclone V DSP User Guide
 */

import f386_pkg::*;

module f386_multiplier (
    input  logic        clk,
    input  logic        rst_n,

    // --- Control ---
    input  logic        start,          // Pulse to begin multiply
    input  logic [1:0]  op_size,        // 00=8-bit, 01=16-bit, 10=32-bit
    input  logic        is_signed,      // IMUL vs MUL

    // --- Operands ---
    input  logic [31:0] op_a,           // Multiplicand (AL/AX/EAX)
    input  logic [31:0] op_b,           // Multiplier   (r/m)

    // --- Results ---
    output logic [63:0] result,         // {high, low}: AH:AL, DX:AX, EDX:EAX
    output logic        done,           // Pulse: result valid
    output logic        overflow_flag   // CF=OF=1 if upper half significant
);

    // Pipeline stage
    logic        stage1_valid;
    logic [1:0]  stage1_size;
    logic        stage1_signed;

    // Sign-extended operands for DSP
    logic signed [17:0] a_lo, b_lo;
    logic signed [17:0] a_hi, b_hi;

    // DSP partial products (registered inside DSP blocks via synthesis attributes)
    // 32×32 = (a_hi*2^16 + a_lo) * (b_hi*2^16 + b_lo)
    //       = a_hi*b_hi*2^32 + (a_hi*b_lo + a_lo*b_hi)*2^16 + a_lo*b_lo
    (* multstyle = "dsp" *) logic signed [35:0] pp_ll;  // a_lo * b_lo
    (* multstyle = "dsp" *) logic signed [35:0] pp_lh;  // a_lo * b_hi
    (* multstyle = "dsp" *) logic signed [35:0] pp_hl;  // a_hi * b_lo
    (* multstyle = "dsp" *) logic signed [35:0] pp_hh;  // a_hi * b_hi

    // Stage 1: decompose and multiply
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage1_valid  <= 1'b0;
            stage1_size   <= 2'b00;
            stage1_signed <= 1'b0;
            pp_ll <= '0;
            pp_lh <= '0;
            pp_hl <= '0;
            pp_hh <= '0;
        end else begin
            stage1_valid <= start;
            if (start) begin
                stage1_size   <= op_size;
                stage1_signed <= is_signed;

                // Split 32-bit operands into 16-bit halves for DSP
                if (is_signed) begin
                    a_lo <= $signed({2'b0, op_a[15:0]});
                    a_hi <= $signed(op_a[31:16]);
                    b_lo <= $signed({2'b0, op_b[15:0]});
                    b_hi <= $signed(op_b[31:16]);
                end else begin
                    a_lo <= {2'b0, op_a[15:0]};
                    a_hi <= {2'b0, op_a[31:16]};
                    b_lo <= {2'b0, op_b[15:0]};
                    b_hi <= {2'b0, op_b[31:16]};
                end

                // DSP multiply (Cyclone V infers 18x18 blocks)
                pp_ll <= $signed({2'b0, op_a[15:0]}) * $signed({2'b0, op_b[15:0]});
                pp_lh <= $signed({2'b0, op_a[15:0]}) * (is_signed ? $signed(op_b[31:16]) :
                                                                     $signed({2'b0, op_b[31:16]}));
                pp_hl <= (is_signed ? $signed(op_a[31:16]) :
                                      $signed({2'b0, op_a[31:16]})) * $signed({2'b0, op_b[15:0]});
                pp_hh <= (is_signed ? $signed(op_a[31:16]) :
                                      $signed({2'b0, op_a[31:16]})) *
                         (is_signed ? $signed(op_b[31:16]) :
                                      $signed({2'b0, op_b[31:16]}));
            end
        end
    end

    // Stage 2: accumulate partial products
    logic [63:0] full_result;
    always_comb begin
        // Schoolbook addition of partial products
        full_result = {{28{pp_hh[35]}}, pp_hh, 32'd0}        // hh << 32
                    + {{28{pp_lh[35]}}, pp_lh, 16'd0}         // lh << 16 (sign-extend to 64)
                    + {{28{pp_hl[35]}}, pp_hl, 16'd0}         // hl << 16
                    + {28'd0, pp_ll};                          // ll
    end

    // Result selection based on operand size
    always_comb begin
        result = '0;
        overflow_flag = 1'b0;

        if (stage1_valid) begin
            case (stage1_size)
                2'b00: begin // 8-bit: result in AX (16 bits)
                    result = {48'd0, full_result[15:0]};
                    if (stage1_signed)
                        overflow_flag = (full_result[15:8] != {8{full_result[7]}});
                    else
                        overflow_flag = (full_result[15:8] != 8'd0);
                end
                2'b01: begin // 16-bit: result in DX:AX (32 bits)
                    result = {32'd0, full_result[31:0]};
                    if (stage1_signed)
                        overflow_flag = (full_result[31:16] != {16{full_result[15]}});
                    else
                        overflow_flag = (full_result[31:16] != 16'd0);
                end
                default: begin // 32-bit: result in EDX:EAX (64 bits)
                    result = full_result;
                    if (stage1_signed)
                        overflow_flag = (full_result[63:32] != {32{full_result[31]}});
                    else
                        overflow_flag = (full_result[63:32] != 32'd0);
                end
            endcase
        end
    end

    assign done = stage1_valid;

endmodule
