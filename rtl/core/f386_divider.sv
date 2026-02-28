/*
 * fabi386: Non-Restoring Divider (v1.0)
 * -----------------------------------------
 * Handles 8-bit and 16/32-bit signed/unsigned division.
 *
 * Non-restoring algorithm: iterates N cycles (8 for byte, 16 for word,
 * 32 for dword), followed by a restore and optional sign-fix step.
 *
 * Supports:
 *   DIV  r/m8   (AX / r/m8     → AL=quot, AH=rem)
 *   DIV  r/m16  (DX:AX / r/m16 → AX=quot, DX=rem)
 *   DIV  r/m32  (EDX:EAX / r/m32 → EAX=quot, EDX=rem)
 *   IDIV r/m8   (same but signed)
 *   IDIV r/m16  (same but signed)
 *   IDIV r/m32  (same but signed)
 *
 * Raises #DE on divide-by-zero or overflow (quotient doesn't fit).
 *
 * Reference: 80x86 Divider.sv (non-restoring), Intel 386 manual
 */

import f386_pkg::*;

module f386_divider (
    input  logic        clk,
    input  logic        rst_n,

    // --- Control ---
    input  logic        start,          // Pulse to begin division
    input  logic [1:0]  op_size,        // 00=8-bit, 01=16-bit, 10=32-bit
    input  logic        is_signed,      // IDIV vs DIV

    // --- Operands ---
    input  logic [63:0] dividend,       // {high, low}: AH:AL, DX:AX, or EDX:EAX
    input  logic [31:0] divisor,        // r/m operand

    // --- Results ---
    output logic [31:0] quotient,
    output logic [31:0] remainder,

    // --- Status ---
    output logic        busy,
    output logic        done,           // Pulse: result valid
    output logic        divide_error    // #DE: div-by-zero or overflow
);

    typedef enum logic [1:0] {
        S_IDLE,
        S_WORKING,
        S_RESTORE,
        S_FIX_SIGN
    } state_t;

    state_t state, state_next;

    // Internal working registers
    logic [63:0] P;                     // Partial remainder + quotient
    logic [31:0] D;                     // Shifted divisor
    logic [5:0]  idx;                   // Bit counter
    logic [31:0] quot_work;             // Working quotient

    // Magnitude computation (for signed)
    wire [63:0] dividend_mag = is_signed ?
        (dividend[63] ? (~dividend + 64'd1) : dividend) : dividend;
    wire [31:0] divisor_mag  = is_signed ?
        (divisor[31]  ? (~divisor  + 32'd1) : divisor)  : divisor;

    // Sign tracking
    logic        dividend_neg;
    logic        signs_differ;

    // Max quotient bits per size
    wire [5:0] max_bits = (op_size == 2'b00) ? 6'd8 :
                          (op_size == 2'b01) ? 6'd16 : 6'd32;

    // Overflow detection
    wire div_by_zero = (divisor == 32'd0);

    // Shifted divisor based on operand size
    wire [63:0] divisor_shifted =
        (op_size == 2'b00) ? {32'd0, divisor_mag[7:0],  24'd0} :
        (op_size == 2'b01) ? {16'd0, divisor_mag[15:0], 32'd0} :
                             {divisor_mag, 32'd0};

    wire overflow_check =
        (op_size == 2'b00) ? (dividend_mag[15:0]  >= {divisor_mag[7:0],  8'd0}) :
        (op_size == 2'b01) ? (dividend_mag[31:0]  >= {divisor_mag[15:0], 16'd0}) :
                             (dividend_mag[63:32] >= divisor_mag);

    wire raise_error = div_by_zero || (is_signed ? 1'b0 : overflow_check);

    assign busy = (state != S_IDLE) || start;

    // FSM next state
    always_comb begin
        state_next = state;
        case (state)
            S_IDLE:     if (start && !raise_error) state_next = S_WORKING;
            S_WORKING:  if (idx == 6'd0) state_next = S_RESTORE;
            S_RESTORE:  state_next = is_signed ? S_FIX_SIGN : S_IDLE;
            S_FIX_SIGN: state_next = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            done         <= 1'b0;
            divide_error <= 1'b0;
            P            <= '0;
            D            <= '0;
            idx          <= '0;
            quot_work    <= '0;
            quotient     <= '0;
            remainder    <= '0;
            dividend_neg <= 1'b0;
            signs_differ <= 1'b0;
        end else begin
            state <= state_next;
            done  <= 1'b0;

            case (state)
                S_IDLE: begin
                    divide_error <= 1'b0;
                    if (start) begin
                        if (raise_error) begin
                            divide_error <= 1'b1;
                            done         <= 1'b1;
                        end else begin
                            P         <= {32'd0, is_signed ? dividend_mag[31:0] : dividend[31:0]};
                            D         <= divisor_shifted[63:32]; // Upper half for subtract
                            idx       <= max_bits - 1'b1;
                            quot_work <= '0;
                            dividend_neg <= is_signed && dividend[63];
                            signs_differ <= is_signed && (dividend[63] ^ divisor[31]);
                        end
                    end
                end

                S_WORKING: begin
                    // Non-restoring step: shift left, then add or subtract D
                    if (!P[63]) begin
                        // P positive: subtract D, set quotient bit
                        quot_work[idx] <= 1'b1;
                        P <= (P << 1) - {D, 32'd0};
                    end else begin
                        // P negative: add D, quotient bit stays 0
                        P <= (P << 1) + {D, 32'd0};
                    end
                    idx <= idx - 1'b1;
                end

                S_RESTORE: begin
                    // Restore quotient from non-restoring form
                    // NR quotient q_nr: actual = q_nr - ~q_nr (= 2*q_nr - 2^N + 1)
                    if (P[63]) begin
                        // Negative remainder: restore by adding D back
                        P <= P + {D, 32'd0};
                        quot_work <= quot_work - (~quot_work) - 32'd1;
                    end else begin
                        quot_work <= quot_work - (~quot_work);
                    end

                    if (!is_signed) begin
                        // Unsigned: extract results based on size
                        quotient  <= quot_result(quot_work, P, op_size, 1'b0);
                        remainder <= rem_result(P, op_size);
                        done      <= 1'b1;
                    end
                end

                S_FIX_SIGN: begin
                    // Apply correct signs for signed division
                    if (signs_differ)
                        quotient <= ~quot_work + 32'd1;
                    else
                        quotient <= quot_work;

                    if (dividend_neg)
                        remainder <= rem_negate(P, op_size);
                    else
                        remainder <= rem_result(P, op_size);

                    // Check for signed overflow (quotient too large for destination)
                    if (signs_differ)
                        divide_error <= signed_overflow_check(~quot_work + 32'd1, op_size);
                    else
                        divide_error <= signed_overflow_check(quot_work, op_size);

                    done <= 1'b1;
                end
            endcase
        end
    end

    // Helper: extract quotient based on operand size
    function automatic logic [31:0] quot_result(
        input logic [31:0] q, input logic [63:0] p,
        input logic [1:0] sz, input logic neg
    );
        case (sz)
            2'b00:   return {24'd0, q[7:0]};
            2'b01:   return {16'd0, q[15:0]};
            default: return q;
        endcase
    endfunction

    // Helper: extract remainder based on operand size
    function automatic logic [31:0] rem_result(input logic [63:0] p, input logic [1:0] sz);
        case (sz)
            2'b00:   return {24'd0, p[39:32]};
            2'b01:   return {16'd0, p[47:32]};
            default: return p[63:32];
        endcase
    endfunction

    // Helper: negate remainder
    function automatic logic [31:0] rem_negate(input logic [63:0] p, input logic [1:0] sz);
        logic [31:0] r;
        r = rem_result(p, sz);
        return ~r + 32'd1;
    endfunction

    // Helper: check signed overflow
    function automatic logic signed_overflow_check(input logic [31:0] q, input logic [1:0] sz);
        case (sz)
            2'b00:   return (q[7]  && q[7:0]  != 8'h80);   // -128 is valid
            2'b01:   return (q[15] && q[15:0] != 16'h8000);
            default: return (q[31] && q        != 32'h8000_0000);
        endcase
    endfunction

endmodule
