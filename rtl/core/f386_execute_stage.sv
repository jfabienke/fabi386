/*
 * fabi386: Execute Stage Controller
 * Routes instructions to ALU, SIMD, and FPU units.
 * Manages pipeline stalls for multi-cycle operations (FPU/Microcode).
 */

import f386_pkg::*;

module f386_execute_stage (
    input  logic         clk,
    input  logic         reset_n,

    // Interface from Dispatcher (U-Pipe)
    input  instr_info_t  u_instr,
    input  logic [31:0]  u_op_a,
    input  logic [31:0]  u_op_b,
    input  logic         u_valid,
    output logic         u_ready, // Signal to dispatcher to hold

    // Interface from Dispatcher (V-Pipe)
    input  instr_info_t  v_instr,
    input  logic [31:0]  v_op_a,
    input  logic [31:0]  v_op_b,
    input  logic         v_valid,
    output logic         v_ready,

    // Output to Writeback
    output logic [31:0]  wb_data_u,
    output logic [31:0]  wb_data_v,
    output logic [5:0]   wb_flags,
    output logic         wb_we_u,
    output logic         wb_we_v
);

    // --- 1. Functional Unit Instantiation ---

    // Primary ALU (U-Pipe)
    logic [31:0] alu_res;
    logic [5:0]  alu_flags;
    f386_alu alu_inst (
        .op_a(u_op_a),
        .op_b(u_op_b),
        .alu_op(u_instr.opcode[4:0]), // Simplified mapping
        .cin(1'b0), // From EFLAGS
        .result(alu_res),
        .flags_out(alu_flags)
    );

    // SIMD Unit (V-Pipe / Graphics)
    logic [31:0] simd_res;
    f386_alu_simd simd_inst (
        .op_a(v_op_a),
        .op_b(v_op_b),
        .simd_ctrl(v_instr.opcode[3:0]),
        .result(simd_res)
    );

    // Spatial FPU (Shared/U-Pipe)
    logic [31:0] fpu_res;
    logic        fpu_done;
    logic        fpu_busy;
    logic [3:0]  fpu_status;
    f386_fpu_spatial fpu_inst (
        .clk(clk), .reset_n(reset_n),
        .fp_a(u_op_a), .fp_b(u_op_b),
        .fp_op(u_instr.opcode[3:0]),
        .fp_req(u_valid && u_instr.op_category == OP_FLOAT),
        .fp_res(fpu_res),
        .fp_done(fpu_done),
        .fp_busy(fpu_busy),
        .fp_status(fpu_status)
    );

    // --- 2. Routing and Stall Logic ---

    always_comb begin
        // Default: Ready to accept new instructions
        u_ready = 1'b1;
        v_ready = 1'b1;
        wb_we_u = 1'b0;
        wb_we_v = 1'b0;
        wb_data_u = 32'h0;
        wb_data_v = 32'h0;
        wb_flags  = 6'h0;

        // U-Pipe Execution
        if (u_valid) begin
            case (u_instr.op_category)
                OP_ALU_REG, OP_ALU_IMM: begin
                    wb_data_u = alu_res;
                    wb_flags  = alu_flags;
                    wb_we_u   = 1'b1;
                end
                OP_FLOAT: begin
                    if (fpu_busy || !fpu_done) begin
                        u_ready = 1'b0; // Stall pipeline while FPU is busy
                    end else begin
                        wb_data_u = fpu_res;
                        wb_we_u   = 1'b1;
                    end
                end
                default: ; // Other ops handled by BIU or Microcode sequencer
            endcase
        end

        // V-Pipe Execution (Only if U-Pipe isn't stalling)
        if (v_valid && u_ready) begin
            case (v_instr.op_category)
                OP_ALU_REG, OP_ALU_IMM: begin
                    // V-Pipe can use the SIMD unit for parallel graphics tasks
                    wb_data_v = (v_instr.opcode[7:4] == 4'hF) ? simd_res : v_op_a; // Sample mux
                    wb_we_v   = 1'b1;
                end
                default: ;
            endcase
        end
    end

endmodule
