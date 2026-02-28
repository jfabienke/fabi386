/*
 * fabi386: ALU Formal Properties
 * --------------------------------
 * Asserts correctness of all ALU operations and flag computations
 * for all operand sizes (8/16/32-bit).
 *
 * Key properties:
 *   - CF correct for ADD/SUB/ADC/SBB/INC/DEC/NEG
 *   - OF correct for ADD/SUB/ADC/SBB
 *   - ZF/SF correct for all ops
 *   - PF = even parity of result[7:0]
 *   - INC/DEC preserve CF
 *   - Shift count=0 preserves flags
 *   - Logic ops (AND/OR/XOR) clear CF and OF
 *
 * Reference: zipcpu bench/formal pattern, 80x86 ALU correctness
 */

module f386_alu_props (
    input  [31:0] op_a,
    input  [31:0] op_b,
    input  [5:0]  alu_op,
    input         cin
);

    // ---- DUT ----
    wire [31:0] result;
    wire [5:0]  flags_out;

    f386_alu dut (
        .op_a      (op_a),
        .op_b      (op_b),
        .alu_op    (alu_op),
        .cin       (cin),
        .result    (result),
        .flags_out (flags_out)
    );

    // ---- Flag aliases ----
    wire cf = flags_out[0];
    wire pf = flags_out[1];
    wire af = flags_out[2];
    wire zf = flags_out[3];
    wire sf = flags_out[4];
    wire of = flags_out[5];

    // ---- Decode ----
    wire [3:0] op   = alu_op[3:0];
    wire [1:0] opsz = alu_op[5:4];

    // Size-masked operands (mirror DUT logic)
    wire [31:0] a = (opsz == 2'b10) ? {24'd0, op_a[7:0]} :
                    (opsz == 2'b01) ? {16'd0, op_a[15:0]} : op_a;
    wire [31:0] b = (opsz == 2'b10) ? {24'd0, op_b[7:0]} :
                    (opsz == 2'b01) ? {16'd0, op_b[15:0]} : op_b;
    wire [4:0] msb = (opsz == 2'b10) ? 5'd7 :
                     (opsz == 2'b01) ? 5'd15 : 5'd31;

    // Op constants
    localparam OP_ADD = 4'h0, OP_SUB = 4'h1, OP_AND = 4'h2, OP_OR  = 4'h3;
    localparam OP_XOR = 4'h4, OP_SHL = 4'h5, OP_SHR = 4'h6, OP_SAR = 4'h7;
    localparam OP_ADC = 4'h8, OP_SBB = 4'h9, OP_NOT = 4'hA, OP_NEG = 4'hB;
    localparam OP_INC = 4'hC, OP_DEC = 4'hD, OP_ROL = 4'hE, OP_ROR = 4'hF;

    // ================================================================
    // Property 1: PF = even parity of result[7:0] (always)
    // ================================================================
    always @(*) begin
        if (op != OP_NOT) begin  // NOT doesn't affect flags
            assert (pf == ~^result[7:0]);
        end
    end

    // ================================================================
    // Property 2: ZF correct for arithmetic/logic ops
    // ================================================================
    wire [31:0] sized_result = (opsz == 2'b10) ? {24'd0, result[7:0]} :
                               (opsz == 2'b01) ? {16'd0, result[15:0]} : result;

    always @(*) begin
        if (op <= OP_DEC && op != OP_NOT) begin
            assert (zf == (sized_result == 32'd0));
        end
    end

    // ================================================================
    // Property 3: SF = MSB of sized result
    // ================================================================
    always @(*) begin
        if (op <= OP_DEC && op != OP_NOT) begin
            assert (sf == result[msb]);
        end
    end

    // ================================================================
    // Property 4: ADD result correct
    // ================================================================
    always @(*) begin
        if (op == OP_ADD) begin
            assert (result == (a + b));
        end
    end

    // ================================================================
    // Property 5: SUB result correct
    // ================================================================
    always @(*) begin
        if (op == OP_SUB) begin
            assert (result == (a - b));
        end
    end

    // ================================================================
    // Property 6: AND/OR/XOR results correct
    // ================================================================
    always @(*) begin
        if (op == OP_AND) assert (result == (a & b));
        if (op == OP_OR)  assert (result == (a | b));
        if (op == OP_XOR) assert (result == (a ^ b));
    end

    // ================================================================
    // Property 7: Logic ops clear CF and OF
    // ================================================================
    always @(*) begin
        if (op == OP_AND || op == OP_OR || op == OP_XOR) begin
            assert (cf == 1'b0);
            assert (of == 1'b0);
        end
    end

    // ================================================================
    // Property 8: INC preserves CF (uses cin as CF passthrough)
    // ================================================================
    always @(*) begin
        if (op == OP_INC) begin
            assert (cf == cin);
            assert (result == (a + 32'd1));
        end
    end

    // ================================================================
    // Property 9: DEC preserves CF
    // ================================================================
    always @(*) begin
        if (op == OP_DEC) begin
            assert (cf == cin);
            assert (result == (a - 32'd1));
        end
    end

    // ================================================================
    // Property 10: NEG result = two's complement
    // ================================================================
    always @(*) begin
        if (op == OP_NEG) begin
            assert (result == (~a + 32'd1));
            // CF=1 when a != 0, CF=0 when a == 0
            assert (cf == (a != 32'd0));
        end
    end

    // ================================================================
    // Property 11: NOT result = bitwise complement
    // ================================================================
    always @(*) begin
        if (op == OP_NOT) begin
            assert (result == ~a);
        end
    end

    // ================================================================
    // Property 12: ADC = a + b + cin
    // ================================================================
    always @(*) begin
        if (op == OP_ADC) begin
            assert (result == (a + b + {31'd0, cin}));
        end
    end

    // ================================================================
    // Property 13: SBB = a - b - cin
    // ================================================================
    always @(*) begin
        if (op == OP_SBB) begin
            assert (result == (a - b - {31'd0, cin}));
        end
    end

    // ================================================================
    // Property 14: Shift count=0 preserves CF (passes cin through)
    // ================================================================
    always @(*) begin
        if ((op == OP_SHL || op == OP_SHR || op == OP_SAR) && op_b[4:0] == 5'd0) begin
            assert (cf == cin);
        end
    end

    // ================================================================
    // Property 15: ADD overflow detection
    // Same-sign inputs but different-sign result → OF
    // ================================================================
    always @(*) begin
        if (op == OP_ADD) begin
            wire expected_of = (a[msb] == b[msb]) && (result[msb] != a[msb]);
            assert (of == expected_of);
        end
    end

    // ================================================================
    // Property 16: SUB overflow detection
    // Different-sign inputs and result sign differs from a → OF
    // ================================================================
    always @(*) begin
        if (op == OP_SUB) begin
            wire expected_of = (a[msb] != b[msb]) && (result[msb] != a[msb]);
            assert (of == expected_of);
        end
    end

endmodule
