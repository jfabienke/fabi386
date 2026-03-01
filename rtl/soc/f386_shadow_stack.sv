/*
 * fabi386: Hardware Shadow Stack Monitor (v18.0)
 * ------------------------------------------------
 * Independently tracks CALL/RET pairs to build a hardware-verified
 * call graph. Triggers stack_fault when a RET target does not match
 * the expected return address from the shadow stack.
 *
 * 512-entry LIFO backed by BRAM inference. Tracks near CALL (E8),
 * indirect CALL (FF /2), near RET (C3), and far RET (CB/CA).
 *
 * Adapted from Neo-386 Pro n386_shadow_stack.
 */

import f386_pkg::*;

module f386_shadow_stack_monitor (
    input  logic         clk,
    input  logic         reset_n,

    // Decoder / retirement interface
    input  logic [31:0]  curr_pc,
    input  logic [7:0]   opcode,
    input  logic [7:0]   modrm,        // ModRM byte for FF /2 detection
    input  logic [7:0]   instr_len,    // Instruction length for return address calc
    input  logic         instr_valid,

    // Actual return target (sampled from stack read during RET execution)
    input  logic [31:0]  actual_ret_target,
    input  logic         ret_target_valid,

    // Result
    output logic         stack_fault,
    output logic [31:0]  expected_ret,  // For telemetry: what we expected
    output logic [8:0]   depth          // Current call depth
);

    // 512-entry shadow LIFO (infers BRAM on Cyclone V)
    logic [31:0] shadow_mem [511:0];
    logic [8:0]  sp_ptr;

    assign depth = sp_ptr;

    // Detect x86 CALL and RET instructions
    // E8 xx xx xx xx  = CALL rel32 (5 bytes)
    // FF /2           = CALL r/m32 (indirect, ModRM[5:3]==010)
    // 9A xx...        = CALL far ptr (inter-segment)
    // C3              = RET near
    // CB              = RETF (far return)
    // CA xx xx        = RETF imm16
    wire is_call_near     = instr_valid && (opcode == 8'hE8);
    wire is_call_indirect = instr_valid && (opcode == 8'hFF) && (modrm[5:3] == 3'b010);
    wire is_call_far      = instr_valid && (opcode == 8'h9A);
    wire is_call          = is_call_near || is_call_indirect || is_call_far;
    wire is_ret           = instr_valid && (opcode == 8'hC3 || opcode == 8'hCB || opcode == 8'hCA);

    // Return address = PC + instruction length
    wire [31:0] computed_ret_addr = curr_pc + {24'd0, instr_len};

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sp_ptr      <= 9'd0;
            stack_fault <= 1'b0;
            expected_ret <= 32'd0;
        end else begin
            stack_fault <= 1'b0;

            // CALL: push return address onto shadow stack
            if (is_call && sp_ptr < 9'd511) begin
                shadow_mem[sp_ptr] <= computed_ret_addr;
                sp_ptr <= sp_ptr + 9'd1;
            end

            // RET: pop and validate against actual return target
            if (is_ret && sp_ptr > 9'd0) begin
                sp_ptr       <= sp_ptr - 9'd1;
                expected_ret <= shadow_mem[sp_ptr - 9'd1];

                // Compare when the actual target is available
                if (ret_target_valid) begin
                    stack_fault <= (actual_ret_target != shadow_mem[sp_ptr - 9'd1]);
                end
            end
        end
    end

endmodule
