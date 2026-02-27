/*
 * fabi386: Integer ALU (v17.0)
 * ----------------------------
 * Performs 32-bit arithmetic and logic operations for the U/V pipes.
 */

module f386_alu (
    input  [31:0] op_a,
    input  [31:0] op_b,
    input  [5:0]  alu_op,
    input         cin,
    output reg [31:0] result,
    output [5:0]  flags_out
);

    always @(*) begin
        case (alu_op[3:0])
            4'h0: result = op_a + op_b;      // ADD
            4'h1: result = op_a - op_b;      // SUB
            4'h2: result = op_a & op_b;      // AND
            4'h3: result = op_a | op_b;      // OR
            4'h4: result = op_a ^ op_b;      // XOR
            4'h5: result = op_a << op_b[4:0]; // SHL
            default: result = 32'h0;
        endcase
    end

    // EFLAGS generation logic (ZF, SF, CF, OF, AF, PF)
    assign flags_out[0] = (result == 0);     // Zero Flag
    assign flags_out[1] = result[31];        // Sign Flag
    // ... etc

endmodule
