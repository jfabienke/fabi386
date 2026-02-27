/*
 * fabi386: x87 Floating-Point Unit (v18.0)
 * -----------------------------------------
 * Pipelined IEEE 754 single-precision FPU with x87 register stack.
 *
 * Architecture:
 *   - 8-entry x87 register stack (ST(0)..ST(7)), 32-bit IEEE 754
 *   - 3-stage pipeline for ADD/SUB (align → compute → normalize+round)
 *   - 2-stage pipeline for MUL    (multiply → normalize+round)
 *   - Multi-cycle FSM for DIV     (24 cycles, non-restoring)
 *   - IEEE 754 special-case handling for NaN, Inf, zero, denormals
 *   - Round-to-nearest-even (default x87 mode)
 *
 * fp_op encoding (active when fp_req=1):
 *   4'h0  FADD   ST(0) += operand
 *   4'h1  FSUB   ST(0) -= operand
 *   4'h2  FMUL   ST(0) *= operand
 *   4'h3  FDIV   ST(0) /= operand
 *   4'h4  FLD    push operand onto stack
 *   4'h5  FST    store ST(0) to result
 *   4'h6  FCOM   compare ST(0) vs operand, set condition codes
 *   4'h7  FTST   compare ST(0) vs 0.0, set condition codes
 *   4'h8  FABS   ST(0) = |ST(0)|
 *   4'h9  FCHS   ST(0) = -ST(0)
 *   4'hA  FXCH   swap ST(0) and ST(1)
 *   4'hB  FILD   push int-to-float(operand) onto stack
 *   4'hC  FIST   store float-to-int(ST(0)) to result
 *   4'hD  (reserved)
 *   4'hE  (reserved)
 *   4'hF  FINIT  reset FPU state
 *
 * fp_status: {C3, C2, C1, C0} x87 condition codes
 *
 * Reference: mor1kx pfpu32 (pipeline structure, IEEE 754 handling)
 */

module f386_fpu_spatial (
    input         clk,
    input         reset_n,

    input  [31:0] fp_a,       // Operand A (typically ST(0) value)
    input  [31:0] fp_b,       // Operand B (memory or ST(i) value)
    input  [3:0]  fp_op,
    input         fp_req,

    output reg [31:0] fp_res,
    output reg        fp_done,
    output wire       fp_busy,    // High while FPU is processing (not idle)
    output reg [3:0]  fp_status   // {C3, C2, C1, C0}
);

    // =================================================================
    // Operation Codes
    // =================================================================
    localparam OP_FADD  = 4'h0;
    localparam OP_FSUB  = 4'h1;
    localparam OP_FMUL  = 4'h2;
    localparam OP_FDIV  = 4'h3;
    localparam OP_FLD   = 4'h4;
    localparam OP_FST   = 4'h5;
    localparam OP_FCOM  = 4'h6;
    localparam OP_FTST  = 4'h7;
    localparam OP_FABS  = 4'h8;
    localparam OP_FCHS  = 4'h9;
    localparam OP_FXCH  = 4'hA;
    localparam OP_FILD  = 4'hB;
    localparam OP_FIST  = 4'hC;
    localparam OP_FINIT = 4'hF;

    // =================================================================
    // IEEE 754 Constants
    // =================================================================
    localparam [7:0]  EXP_BIAS  = 8'd127;
    localparam [7:0]  EXP_INF   = 8'hFF;
    localparam [31:0] POS_ZERO  = 32'h00000000;
    localparam [31:0] NEG_ZERO  = 32'h80000000;
    localparam [31:0] POS_INF   = 32'h7F800000;
    localparam [31:0] NEG_INF   = 32'hFF800000;
    localparam [31:0] QUIET_NAN = 32'h7FC00000;

    // =================================================================
    // x87 Register Stack
    // =================================================================
    reg [31:0] st_reg [0:7];
    reg [2:0]  st_top;
    reg [1:0]  st_tag [0:7];   // 00=valid, 01=zero, 10=special, 11=empty

    // =================================================================
    // IEEE 754 Field Extraction (combinational)
    // =================================================================
    wire        a_sign  = fp_a[31];
    wire [7:0]  a_exp   = fp_a[30:23];
    wire [22:0] a_frac  = fp_a[22:0];
    wire [23:0] a_mant  = {|a_exp, a_frac};   // Restore implicit 1
    wire        a_zero  = (a_exp == 8'd0) && (a_frac == 23'd0);
    wire        a_inf   = (a_exp == EXP_INF)  && (a_frac == 23'd0);
    wire        a_nan   = (a_exp == EXP_INF)  && (a_frac != 23'd0);

    wire        b_sign  = fp_b[31];
    wire [7:0]  b_exp   = fp_b[30:23];
    wire [22:0] b_frac  = fp_b[22:0];
    wire [23:0] b_mant  = {|b_exp, b_frac};
    wire        b_zero  = (b_exp == 8'd0) && (b_frac == 23'd0);
    wire        b_inf   = (b_exp == EXP_INF)  && (b_frac == 23'd0);
    wire        b_nan   = (b_exp == EXP_INF)  && (b_frac != 23'd0);

    // =================================================================
    // Integer-to-Float Conversion (combinational)
    // =================================================================
    // Reference: mor1kx pfpu32_i2f.v — casez priority encoder for LZC
    reg [31:0] i2f_result;
    reg [31:0] i2f_abs;
    reg        i2f_sign_r;
    reg [4:0]  i2f_lzc;
    reg [31:0] i2f_shifted;
    reg [7:0]  i2f_exp;

    always @(*) begin
        i2f_sign_r = fp_b[31];
        i2f_abs    = i2f_sign_r ? (~fp_b + 32'd1) : fp_b;

        // Leading zero count via priority encoder (finds MSB position)
        casez (i2f_abs)
            32'b1???????????????????????????????: i2f_lzc = 5'd0;
            32'b01??????????????????????????????: i2f_lzc = 5'd1;
            32'b001?????????????????????????????: i2f_lzc = 5'd2;
            32'b0001????????????????????????????: i2f_lzc = 5'd3;
            32'b00001???????????????????????????: i2f_lzc = 5'd4;
            32'b000001??????????????????????????: i2f_lzc = 5'd5;
            32'b0000001?????????????????????????: i2f_lzc = 5'd6;
            32'b00000001????????????????????????: i2f_lzc = 5'd7;
            32'b000000001???????????????????????: i2f_lzc = 5'd8;
            32'b0000000001??????????????????????: i2f_lzc = 5'd9;
            32'b00000000001?????????????????????: i2f_lzc = 5'd10;
            32'b000000000001????????????????????: i2f_lzc = 5'd11;
            32'b0000000000001???????????????????: i2f_lzc = 5'd12;
            32'b00000000000001??????????????????: i2f_lzc = 5'd13;
            32'b000000000000001?????????????????: i2f_lzc = 5'd14;
            32'b0000000000000001????????????????: i2f_lzc = 5'd15;
            32'b00000000000000001???????????????: i2f_lzc = 5'd16;
            32'b000000000000000001??????????????: i2f_lzc = 5'd17;
            32'b0000000000000000001?????????????: i2f_lzc = 5'd18;
            32'b00000000000000000001????????????: i2f_lzc = 5'd19;
            32'b000000000000000000001???????????: i2f_lzc = 5'd20;
            32'b0000000000000000000001??????????: i2f_lzc = 5'd21;
            32'b00000000000000000000001?????????: i2f_lzc = 5'd22;
            32'b000000000000000000000001????????: i2f_lzc = 5'd23;
            32'b0000000000000000000000001???????: i2f_lzc = 5'd24;
            32'b00000000000000000000000001??????: i2f_lzc = 5'd25;
            32'b000000000000000000000000001?????: i2f_lzc = 5'd26;
            32'b0000000000000000000000000001????: i2f_lzc = 5'd27;
            32'b00000000000000000000000000001???: i2f_lzc = 5'd28;
            32'b000000000000000000000000000001??: i2f_lzc = 5'd29;
            32'b0000000000000000000000000000001?: i2f_lzc = 5'd30;
            32'b00000000000000000000000000000001: i2f_lzc = 5'd31;
            default:                              i2f_lzc = 5'd0;
        endcase

        // Shift MSB to bit 31, then drop it (implicit 1)
        i2f_shifted = i2f_abs << i2f_lzc;
        i2f_exp     = 8'd158 - {3'd0, i2f_lzc};

        if (fp_b == 32'd0)
            i2f_result = POS_ZERO;
        else
            i2f_result = {i2f_sign_r, i2f_exp, i2f_shifted[30:8]};
    end

    // =================================================================
    // Float-to-Integer Conversion (combinational)
    // =================================================================
    // Reference: mor1kx pfpu32_f2i.v — exponent-driven shift + clamp
    reg [31:0] f2i_result;
    reg [7:0]  f2i_shift;
    reg [31:0] f2i_unsigned;

    always @(*) begin
        f2i_result   = 32'd0;
        f2i_shift    = 8'd0;
        f2i_unsigned = 32'd0;

        if (a_nan || a_inf) begin
            f2i_result = a_sign ? 32'h80000000 : 32'h7FFFFFFF;
        end else if (a_zero || (a_exp < EXP_BIAS)) begin
            f2i_result = 32'd0;
        end else begin
            f2i_shift = a_exp - EXP_BIAS;
            if (f2i_shift > 8'd30) begin
                f2i_result = a_sign ? 32'h80000000 : 32'h7FFFFFFF;
            end else begin
                if (f2i_shift >= 8'd23)
                    f2i_unsigned = {8'd0, a_mant} << (f2i_shift - 8'd23);
                else
                    f2i_unsigned = {8'd0, a_mant} >> (8'd23 - f2i_shift);

                f2i_result = a_sign ? (~f2i_unsigned + 32'd1) : f2i_unsigned;
            end
        end
    end

    // =================================================================
    // Comparison Logic (combinational)
    // =================================================================
    // x87 condition codes for FCOM/FTST:
    //   C3=1, C0=0        : ST(0) == operand (or both zero)
    //   C3=0, C0=1        : ST(0) < operand
    //   C3=0, C0=0        : ST(0) > operand
    //   C3=1, C2=1, C0=1  : Unordered (NaN)
    reg [3:0] cmp_status;
    reg       cmp_a_lt_b;

    always @(*) begin
        cmp_status = 4'b0000;
        cmp_a_lt_b = 1'b0;

        if (a_nan || b_nan) begin
            cmp_status = 4'b1101;   // C3=1, C2=1, C0=1  (unordered)
        end else if ((a_zero && b_zero) ||
                     (fp_a == fp_b) ||
                     ({1'b0, fp_a[30:0]} == 31'd0 && {1'b0, fp_b[30:0]} == 31'd0)) begin
            cmp_status = 4'b1000;   // Equal: C3=1
        end else begin
            if (a_sign != b_sign)
                cmp_a_lt_b = a_sign;
            else if (a_sign == 1'b0)
                cmp_a_lt_b = ({a_exp, a_frac} < {b_exp, b_frac});
            else
                cmp_a_lt_b = ({a_exp, a_frac} > {b_exp, b_frac});

            cmp_status = cmp_a_lt_b ? 4'b0001 : 4'b0000;
        end
    end

    // =================================================================
    // Pipeline State Machine
    // =================================================================
    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_ADDSUB_2 = 3'd1;  // ADD/SUB stage 2: mantissa op
    localparam [2:0] S_ADDSUB_3 = 3'd2;  // ADD/SUB stage 3: normalize+round
    localparam [2:0] S_MUL_NORM = 3'd3;  // MUL: normalize+round
    localparam [2:0] S_DIV_ITER = 3'd4;  // DIV: iterative division
    localparam [2:0] S_DIV_NORM = 3'd5;  // DIV: normalize quotient
    localparam [2:0] S_DONE     = 3'd6;  // Write result

    reg [2:0] state;

    assign fp_busy = (state != S_IDLE);

    // =================================================================
    // Pipeline Registers
    // =================================================================
    reg        p_sign;
    reg [9:0]  p_exp;            // Extra bits for overflow/underflow detection

    // ADD/SUB pipeline
    reg        p_eff_sub;
    reg [23:0] p_large_mant;     // Larger-magnitude mantissa (unshifted)
    reg [27:0] p_small_mant;     // Smaller-magnitude mantissa (shifted + GRS)
    reg [27:0] p_mant_sum;       // Result of mantissa add/sub

    // MUL pipeline
    reg [47:0] p_product;        // 24×24 raw product (DSP inferred)

    // DIV pipeline
    reg [23:0] p_quotient;
    reg [24:0] p_remainder;      // Extra bit for trial subtraction
    reg [23:0] p_divisor;
    reg [4:0]  p_div_count;

    // Result register
    reg [31:0] p_result;

    // =================================================================
    // Normalize + Round Helper (combinational)
    // =================================================================
    // Used by ADD/SUB stage 3 and MUL stage 2.
    // Input: 28-bit mantissa {1.fraction, guard, round, sticky}, 10-bit exponent
    // Output: packed IEEE 754 result
    //
    // Reference: mor1kx pfpu32_rnd.v — guard/round/sticky + round-to-nearest-even

    // Normalize inputs: muxed combinationally from current pipeline state
    reg [31:0] norm_result;
    reg [27:0] norm_mant_in;
    reg [9:0]  norm_exp_in;
    reg        norm_sign_in;

    // Mux normalize inputs based on state (combinational)
    always @(*) begin
        norm_mant_in = 28'd0;
        norm_exp_in  = 10'd0;
        norm_sign_in = 1'b0;

        case (state)
            S_ADDSUB_3: begin
                norm_mant_in = p_mant_sum;
                norm_exp_in  = p_exp;
                norm_sign_in = p_sign;
            end
            S_MUL_NORM: begin
                if (p_product[47]) begin
                    norm_mant_in = {p_product[47:21], |p_product[20:0]};
                    norm_exp_in  = p_exp + 10'd1;
                end else begin
                    norm_mant_in = {p_product[46:20], |p_product[19:0]};
                    norm_exp_in  = p_exp;
                end
                norm_sign_in = p_sign;
            end
            S_DIV_NORM: begin
                if (!p_quotient[23] && |p_quotient) begin
                    norm_mant_in = {p_quotient[22:0], |p_remainder, 4'd0};
                    norm_exp_in  = p_exp - 10'd1;
                end else begin
                    norm_mant_in = {p_quotient, 4'd0};
                    norm_exp_in  = p_exp;
                end
                norm_sign_in = p_sign;
            end
            default: ;
        endcase
    end

    reg [27:0] n_mant;
    reg [9:0]  n_exp;
    reg [4:0]  n_lzc;

    always @(*) begin
        n_mant = norm_mant_in;
        n_exp  = norm_exp_in;
        n_lzc  = 5'd0;
        norm_result = POS_ZERO;

        if (n_mant == 28'd0) begin
            norm_result = {norm_sign_in, 31'd0};
        end else begin
            // Carry-out from addition: bit 27 set
            if (n_mant[27]) begin
                n_mant = {n_mant[27:1], n_mant[0]};  // Sticky OR into LSB
                n_exp  = n_exp + 10'd1;
            end else begin
                // Leading zero count via priority encoder on bits [26:0]
                // Finds position of highest set bit; LZC = distance from bit 26
                casez (n_mant[26:0])
                    27'b1??????????????????????????: n_lzc = 5'd0;
                    27'b01?????????????????????????: n_lzc = 5'd1;
                    27'b001????????????????????????: n_lzc = 5'd2;
                    27'b0001???????????????????????: n_lzc = 5'd3;
                    27'b00001??????????????????????: n_lzc = 5'd4;
                    27'b000001?????????????????????: n_lzc = 5'd5;
                    27'b0000001????????????????????: n_lzc = 5'd6;
                    27'b00000001???????????????????: n_lzc = 5'd7;
                    27'b000000001??????????????????: n_lzc = 5'd8;
                    27'b0000000001?????????????????: n_lzc = 5'd9;
                    27'b00000000001????????????????: n_lzc = 5'd10;
                    27'b000000000001???????????????: n_lzc = 5'd11;
                    27'b0000000000001??????????????: n_lzc = 5'd12;
                    27'b00000000000001?????????????: n_lzc = 5'd13;
                    27'b000000000000001????????????: n_lzc = 5'd14;
                    27'b0000000000000001???????????: n_lzc = 5'd15;
                    27'b00000000000000001??????????: n_lzc = 5'd16;
                    27'b000000000000000001?????????: n_lzc = 5'd17;
                    27'b0000000000000000001????????: n_lzc = 5'd18;
                    27'b00000000000000000001???????: n_lzc = 5'd19;
                    27'b000000000000000000001??????: n_lzc = 5'd20;
                    27'b0000000000000000000001?????: n_lzc = 5'd21;
                    27'b00000000000000000000001????: n_lzc = 5'd22;
                    27'b000000000000000000000001???: n_lzc = 5'd23;
                    27'b0000000000000000000000001??: n_lzc = 5'd24;
                    27'b00000000000000000000000001?: n_lzc = 5'd25;
                    27'b000000000000000000000000001: n_lzc = 5'd26;
                    default:                         n_lzc = 5'd27;
                endcase

                // Shift left to normalize, but don't underflow exponent
                if ({5'd0, n_lzc} < n_exp) begin
                    n_mant = n_mant << n_lzc;
                    n_exp  = n_exp - {5'd0, n_lzc};
                end else if (n_exp > 10'd1) begin
                    n_mant = n_mant << (n_exp[4:0] - 5'd1);
                    n_exp  = 10'd0;  // Denormalized
                end
            end

            // Round to nearest even: guard=bit3, round=bit2, sticky=bits[1:0]
            // Reference: mor1kx pfpu32_rnd.v — rnd_up = r&s | g&r&~s
            if (n_mant[3] && (n_mant[4] || |n_mant[2:0])) begin
                n_mant = n_mant + 28'd16;  // Increment at bit 4 (above GRS)
                if (n_mant[27]) begin
                    n_mant = n_mant >> 1;
                    n_exp  = n_exp + 10'd1;
                end
            end

            // Pack: overflow → Inf, underflow handled by denorm above
            if (n_exp >= 10'd255)
                norm_result = {norm_sign_in, POS_INF[30:0]};
            else
                norm_result = {norm_sign_in, n_exp[7:0], n_mant[26:4]};
        end
    end

    // =================================================================
    // Exponent difference and alignment (combinational, used by IDLE)
    // =================================================================
    wire [8:0]  exp_diff_ab  = {1'b0, a_exp} - {1'b0, b_exp};
    wire [8:0]  exp_diff_ba  = {1'b0, b_exp} - {1'b0, a_exp};
    wire        a_mag_ge_b   = ({a_exp, a_frac} >= {b_exp, b_frac});

    // Pre-compute shifted mantissa for the smaller operand
    // Guard, Round, Sticky bits occupy the low 4 bits of 28-bit field
    // Reference: mor1kx pfpu32_addsub.v Stage 1 — alignment barrel shift
    reg [27:0] aligned_small;
    reg        align_sticky;
    reg [7:0]  align_shift;

    always @(*) begin
        aligned_small = 28'd0;
        align_sticky  = 1'b0;
        align_shift   = a_mag_ge_b ? exp_diff_ab[7:0] : exp_diff_ba[7:0];

        if (align_shift > 8'd27) begin
            aligned_small = 28'd0;
            align_sticky  = a_mag_ge_b ? |b_mant : |a_mant;
        end else begin
            if (a_mag_ge_b) begin
                aligned_small = {b_mant, 4'b0000} >> align_shift;
                align_sticky  = |( ({b_mant, 4'b0000}) << (8'd28 - align_shift) );
            end else begin
                aligned_small = {a_mant, 4'b0000} >> align_shift;
                align_sticky  = |( ({a_mant, 4'b0000}) << (8'd28 - align_shift) );
            end
        end
    end

    // =================================================================
    // Main FSM
    // =================================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state     <= S_IDLE;
            fp_done   <= 1'b0;
            fp_res    <= 32'd0;
            fp_status <= 4'd0;
            st_top    <= 3'd0;
            p_result  <= 32'd0;
            p_sign    <= 1'b0;
            p_exp     <= 10'd0;
            p_eff_sub <= 1'b0;
            p_large_mant <= 24'd0;
            p_small_mant <= 28'd0;
            p_mant_sum   <= 28'd0;
            p_product    <= 48'd0;
            p_quotient   <= 24'd0;
            p_remainder  <= 25'd0;
            p_divisor    <= 24'd0;
            p_div_count  <= 5'd0;
            begin : rst_loop
                integer ri;
                for (ri = 0; ri < 8; ri = ri + 1) begin
                    st_reg[ri] <= 32'd0;
                    st_tag[ri] <= 2'b11;
                end
            end
        end else begin
            fp_done <= 1'b0;

            case (state)

            // =========================================================
            // IDLE: Decode fp_op and either complete or start pipeline
            // =========================================================
            S_IDLE: begin
                if (fp_req) begin
                    case (fp_op)

                    // --- Single-cycle operations ---

                    OP_FLD: begin
                        st_top <= st_top - 3'd1;
                        st_reg[st_top - 3'd1] <= fp_b;
                        st_tag[st_top - 3'd1] <= b_zero ? 2'b01 : 2'b00;
                        fp_res  <= fp_b;
                        fp_done <= 1'b1;
                    end

                    OP_FST: begin
                        fp_res  <= st_reg[st_top];
                        fp_done <= 1'b1;
                    end

                    OP_FABS: begin
                        st_reg[st_top] <= {1'b0, fp_a[30:0]};
                        fp_res  <= {1'b0, fp_a[30:0]};
                        fp_done <= 1'b1;
                    end

                    OP_FCHS: begin
                        st_reg[st_top] <= {~fp_a[31], fp_a[30:0]};
                        fp_res  <= {~fp_a[31], fp_a[30:0]};
                        fp_done <= 1'b1;
                    end

                    OP_FXCH: begin
                        st_reg[st_top]        <= st_reg[st_top + 3'd1];
                        st_reg[st_top + 3'd1] <= st_reg[st_top];
                        st_tag[st_top]        <= st_tag[st_top + 3'd1];
                        st_tag[st_top + 3'd1] <= st_tag[st_top];
                        fp_res  <= st_reg[st_top + 3'd1];
                        fp_done <= 1'b1;
                    end

                    OP_FCOM: begin
                        fp_status <= cmp_status;
                        fp_res    <= fp_a;
                        fp_done   <= 1'b1;
                    end

                    OP_FTST: begin
                        if (a_nan)
                            fp_status <= 4'b1101;   // Unordered
                        else if (a_zero)
                            fp_status <= 4'b1000;   // Equal to zero
                        else if (a_sign)
                            fp_status <= 4'b0001;   // Less than zero
                        else
                            fp_status <= 4'b0000;   // Greater than zero
                        fp_res  <= fp_a;
                        fp_done <= 1'b1;
                    end

                    OP_FILD: begin
                        st_top <= st_top - 3'd1;
                        st_reg[st_top - 3'd1] <= i2f_result;
                        st_tag[st_top - 3'd1] <= (fp_b == 32'd0) ? 2'b01 : 2'b00;
                        fp_res  <= i2f_result;
                        fp_done <= 1'b1;
                    end

                    OP_FIST: begin
                        fp_res  <= f2i_result;
                        fp_done <= 1'b1;
                    end

                    OP_FINIT: begin
                        st_top    <= 3'd0;
                        fp_status <= 4'd0;
                        fp_res    <= 32'd0;
                        fp_done   <= 1'b1;
                        begin : finit_loop
                            integer fi;
                            for (fi = 0; fi < 8; fi = fi + 1) begin
                                st_reg[fi] <= 32'd0;
                                st_tag[fi] <= 2'b11;
                            end
                        end
                    end

                    // --- FADD / FSUB: 3 pipeline stages ---
                    // Reference: mor1kx pfpu32_addsub.v — 3-stage pipeline
                    //   Stage 1 (here):   Detect specials, align exponents
                    //   Stage 2:          Mantissa add/sub
                    //   Stage 3:          Normalize + round

                    OP_FADD, OP_FSUB: begin
                        // Effective operation after sign absorption
                        p_eff_sub <= (fp_op == OP_FSUB) ? (a_sign == b_sign)
                                                        : (a_sign != b_sign);

                        // Special cases — resolve immediately
                        if (a_nan || b_nan) begin
                            p_result <= QUIET_NAN;
                            state    <= S_DONE;
                        end else if (a_inf && b_inf) begin
                            if ((fp_op == OP_FSUB) ? (a_sign == b_sign)
                                                   : (a_sign != b_sign))
                                p_result <= QUIET_NAN;    // Inf - Inf
                            else
                                p_result <= fp_a;         // Inf + Inf
                            state <= S_DONE;
                        end else if (a_inf) begin
                            p_result <= fp_a;
                            state    <= S_DONE;
                        end else if (b_inf) begin
                            p_result <= (fp_op == OP_FSUB) ? {~b_sign, fp_b[30:0]}
                                                           : fp_b;
                            state    <= S_DONE;
                        end else if (a_zero && b_zero) begin
                            p_result <= POS_ZERO;
                            state    <= S_DONE;
                        end else if (b_zero) begin
                            p_result <= fp_a;
                            state    <= S_DONE;
                        end else if (a_zero) begin
                            p_result <= (fp_op == OP_FSUB) ? {~b_sign, fp_b[30:0]}
                                                           : fp_b;
                            state    <= S_DONE;
                        end else begin
                            // Stage 1: Align exponents
                            if (a_mag_ge_b) begin
                                p_sign       <= a_sign;
                                p_exp        <= {2'b00, a_exp};
                                p_large_mant <= a_mant;
                            end else begin
                                p_sign       <= (fp_op == OP_FSUB) ? ~b_sign : b_sign;
                                p_exp        <= {2'b00, b_exp};
                                p_large_mant <= b_mant;
                            end
                            p_small_mant <= {aligned_small[27:1],
                                            aligned_small[0] | align_sticky};
                            state <= S_ADDSUB_2;
                        end
                    end

                    // --- FMUL: 2 pipeline stages ---
                    // Reference: mor1kx pfpu32_muldiv.v — 4×16-bit partial products
                    //   Stage 1 (here):   Detect specials, launch 24×24 multiply
                    //   Stage 2:          Normalize + round

                    OP_FMUL: begin
                        if (a_nan || b_nan) begin
                            p_result <= QUIET_NAN;
                            state    <= S_DONE;
                        end else if ((a_inf && b_zero) || (b_inf && a_zero)) begin
                            p_result <= QUIET_NAN;    // Inf × 0
                            state    <= S_DONE;
                        end else if (a_inf || b_inf) begin
                            p_result <= {a_sign ^ b_sign, POS_INF[30:0]};
                            state    <= S_DONE;
                        end else if (a_zero || b_zero) begin
                            p_result <= {a_sign ^ b_sign, 31'd0};
                            state    <= S_DONE;
                        end else begin
                            p_sign    <= a_sign ^ b_sign;
                            p_exp     <= {2'b00, a_exp} + {2'b00, b_exp}
                                         - {2'b00, EXP_BIAS};
                            p_product <= a_mant * b_mant;  // Synthesis infers DSP
                            state     <= S_MUL_NORM;
                        end
                    end

                    // --- FDIV: multi-cycle non-restoring ---
                    // Reference: mor1kx pfpu32_muldiv.v — Goldschmidt iterative
                    //   We use simpler non-restoring division (24 iterations)

                    OP_FDIV: begin
                        if (a_nan || b_nan) begin
                            p_result <= QUIET_NAN;
                            state    <= S_DONE;
                        end else if (a_inf && b_inf) begin
                            p_result <= QUIET_NAN;    // Inf / Inf
                            state    <= S_DONE;
                        end else if (a_inf) begin
                            p_result <= {a_sign ^ b_sign, POS_INF[30:0]};
                            state    <= S_DONE;
                        end else if (b_zero) begin
                            p_result <= a_zero ? QUIET_NAN                         // 0/0
                                               : {a_sign ^ b_sign, POS_INF[30:0]}; // x/0
                            state    <= S_DONE;
                        end else if (a_zero) begin
                            p_result <= {a_sign ^ b_sign, 31'd0};
                            state    <= S_DONE;
                        end else if (b_inf) begin
                            p_result <= {a_sign ^ b_sign, 31'd0};
                            state    <= S_DONE;
                        end else begin
                            p_sign      <= a_sign ^ b_sign;
                            p_exp       <= {2'b00, a_exp} - {2'b00, b_exp}
                                           + {2'b00, EXP_BIAS};
                            p_quotient  <= 24'd0;
                            p_remainder <= {1'b0, a_mant};
                            p_divisor   <= b_mant;
                            p_div_count <= 5'd24;
                            state       <= S_DIV_ITER;
                        end
                    end

                    default: begin
                        fp_res  <= fp_a;
                        fp_done <= 1'b1;
                    end

                    endcase
                end
            end

            // =========================================================
            // ADD/SUB Stage 2: Mantissa add/subtract
            // =========================================================
            S_ADDSUB_2: begin
                if (p_eff_sub)
                    p_mant_sum <= {p_large_mant, 4'b0000} - p_small_mant;
                else
                    p_mant_sum <= {p_large_mant, 4'b0000} + p_small_mant;
                state <= S_ADDSUB_3;
            end

            // =========================================================
            // ADD/SUB Stage 3: Normalize + Round (via combinational helper)
            // =========================================================
            S_ADDSUB_3: begin
                p_result <= norm_result;
                state    <= S_DONE;
            end

            // =========================================================
            // MUL: Normalize + Round
            // =========================================================
            S_MUL_NORM: begin
                p_result <= norm_result;
                state    <= S_DONE;
            end

            // =========================================================
            // DIV: Iterative non-restoring division
            // =========================================================
            S_DIV_ITER: begin
                if (p_div_count == 5'd0) begin
                    // Division complete — latch quotient, then normalize next cycle
                    state <= S_DIV_NORM;
                end else begin
                    // One bit of quotient per cycle
                    if (p_remainder >= {1'b0, p_divisor}) begin
                        p_quotient  <= {p_quotient[22:0], 1'b1};
                        p_remainder <= (p_remainder - {1'b0, p_divisor}) << 1;
                    end else begin
                        p_quotient  <= {p_quotient[22:0], 1'b0};
                        p_remainder <= p_remainder << 1;
                    end
                    p_div_count <= p_div_count - 5'd1;
                end
            end

            // =========================================================
            // DIV: Normalize quotient (1 cycle after iteration completes)
            // =========================================================
            S_DIV_NORM: begin
                p_result <= norm_result;
                state    <= S_DONE;
            end

            // =========================================================
            // DONE: Write result to stack and output
            // =========================================================
            S_DONE: begin
                fp_res  <= p_result;
                fp_done <= 1'b1;

                // Update ST(0) for arithmetic ops
                st_reg[st_top] <= p_result;
                if (p_result[30:0] == 31'd0)
                    st_tag[st_top] <= 2'b01;    // Zero
                else if (p_result[30:23] == EXP_INF)
                    st_tag[st_top] <= 2'b10;    // Special (Inf/NaN)
                else
                    st_tag[st_top] <= 2'b00;    // Valid

                state <= S_IDLE;
            end

            default: state <= S_IDLE;

            endcase
        end
    end

endmodule
