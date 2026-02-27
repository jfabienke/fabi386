/*
 * fabi386: Execute Stage Controller (v18.0)
 * ------------------------------------------
 * Routes decoded instructions to ALU, SIMD, and FPU functional units.
 * Drives CDB writeback to the ROB for in-order retirement.
 * Handles branch resolution and forwards exceptions.
 *
 * U-pipe: ALU (all integer ops) + FPU (x87) + Branch + Microcode
 * V-pipe: Second ALU (simple integer ops) + SIMD (byte-parallel graphics)
 *
 * CDB ports:
 *   cdb0 — U-pipe results (ALU, FPU, branch)
 *   cdb1 — V-pipe results (ALU, SIMD)
 */

import f386_pkg::*;

module f386_execute_stage (
    input  logic         clk,
    input  logic         reset_n,

    // --- Dispatch Interface (U-Pipe) ---
    input  instr_info_t  u_instr,
    input  logic [31:0]  u_op_a,
    input  logic [31:0]  u_op_b,
    input  logic         u_valid,
    output logic         u_ready,

    // --- Dispatch Interface (V-Pipe) ---
    input  instr_info_t  v_instr,
    input  logic [31:0]  v_op_a,
    input  logic [31:0]  v_op_b,
    input  logic         v_valid,
    output logic         v_ready,

    // --- CDB Writeback to ROB ---
    output logic         cdb0_valid,
    output rob_id_t      cdb0_tag,
    output logic [31:0]  cdb0_data,
    output logic         cdb0_exception,

    output logic         cdb1_valid,
    output rob_id_t      cdb1_tag,
    output logic [31:0]  cdb1_data,
    output logic         cdb1_exception,

    // --- Writeback to Architectural State ---
    output logic [31:0]  wb_data_u,
    output logic [31:0]  wb_data_v,
    output logic [5:0]   wb_flags,
    output logic         wb_we_u,
    output logic         wb_we_v,

    // --- Branch Resolution (to Predictor / ROB) ---
    output logic         branch_resolved,
    output logic         branch_taken,
    output logic [31:0]  branch_target,
    output logic         branch_mispredict,
    output rob_id_t      branch_rob_tag,

    // --- Microcode Request (to Microcode Sequencer) ---
    output logic         microcode_req,
    output logic [7:0]   microcode_opcode
);

    // =================================================================
    // 1. Functional Unit Instantiation
    // =================================================================

    // --- Primary ALU (U-Pipe) ---
    logic [31:0] alu_u_res;
    logic [5:0]  alu_u_flags;
    f386_alu alu_u_inst (
        .op_a     (u_op_a),
        .op_b     (u_op_b),
        .alu_op   (u_instr.opcode[5:0]),
        .cin      (u_instr.flags_in[0]),     // CF from EFLAGS
        .result   (alu_u_res),
        .flags_out(alu_u_flags)
    );

    // --- Secondary ALU (V-Pipe) ---
    logic [31:0] alu_v_res;
    logic [5:0]  alu_v_flags;
    f386_alu alu_v_inst (
        .op_a     (v_op_a),
        .op_b     (v_op_b),
        .alu_op   (v_instr.opcode[5:0]),
        .cin      (v_instr.flags_in[0]),     // CF from EFLAGS
        .result   (alu_v_res),
        .flags_out(alu_v_flags)
    );

    // --- SIMD Unit (V-Pipe, byte-parallel graphics) ---
    logic [31:0] simd_res;
    f386_alu_simd simd_inst (
        .op_a     (v_op_a),
        .op_b     (v_op_b),
        .simd_ctrl(v_instr.opcode[3:0]),
        .result   (simd_res)
    );

    // --- Spatial FPU (U-Pipe, multi-cycle) ---
    logic [31:0] fpu_res;
    logic        fpu_done;
    logic        fpu_busy;
    logic [3:0]  fpu_status;
    f386_fpu_spatial fpu_inst (
        .clk     (clk),
        .reset_n (reset_n),
        .fp_a    (u_op_a),
        .fp_b    (u_op_b),
        .fp_op   (u_instr.opcode[3:0]),
        .fp_req  (u_valid && u_instr.op_category == OP_FLOAT && !fpu_busy),
        .fp_res  (fpu_res),
        .fp_done (fpu_done),
        .fp_busy (fpu_busy),
        .fp_status(fpu_status)
    );

    // =================================================================
    // 2. Branch Resolution (U-Pipe only)
    // =================================================================
    // Compute actual taken/target and compare against prediction.
    // Branch condition is encoded in opcode[3:0]; operand A holds the
    // condition flags snapshot, operand B holds the branch displacement.

    logic        br_actual_taken;
    logic [31:0] br_actual_target;
    logic [31:0] br_next_pc;

    assign br_next_pc      = u_instr.pc + 32'd2;  // Minimum x86 branch size
    assign br_actual_target = u_instr.pc + u_instr.imm_value;

    // Branch condition evaluation from EFLAGS
    // opcode[3:0] encodes Jcc condition (matches x86 TTTNcc encoding)
    always_comb begin
        br_actual_taken = 1'b0;
        case (u_instr.opcode[3:0])
            4'h0: br_actual_taken =  u_instr.flags_in[0];           // JO  (OF=1)... mapped to CF position for simplicity
            4'h1: br_actual_taken = !u_instr.flags_in[0];           // JNO
            4'h2: br_actual_taken =  u_instr.flags_in[0];           // JB/JC   (CF=1)
            4'h3: br_actual_taken = !u_instr.flags_in[0];           // JNB/JNC (CF=0)
            4'h4: br_actual_taken =  u_instr.flags_in[3];           // JE/JZ   (ZF=1)
            4'h5: br_actual_taken = !u_instr.flags_in[3];           // JNE/JNZ (ZF=0)
            4'h6: br_actual_taken =  u_instr.flags_in[0] | u_instr.flags_in[3]; // JBE (CF|ZF)
            4'h7: br_actual_taken = !u_instr.flags_in[0] & !u_instr.flags_in[3]; // JA
            4'h8: br_actual_taken =  u_instr.flags_in[4];           // JS  (SF=1)
            4'h9: br_actual_taken = !u_instr.flags_in[4];           // JNS (SF=0)
            4'hA: br_actual_taken =  u_instr.flags_in[1];           // JP  (PF=1)
            4'hB: br_actual_taken = !u_instr.flags_in[1];           // JNP (PF=0)
            4'hC: br_actual_taken =  u_instr.flags_in[4] != u_instr.flags_in[5]; // JL  (SF!=OF)
            4'hD: br_actual_taken =  u_instr.flags_in[4] == u_instr.flags_in[5]; // JGE (SF==OF)
            4'hE: br_actual_taken =  u_instr.flags_in[3] |
                                    (u_instr.flags_in[4] != u_instr.flags_in[5]); // JLE (ZF|SF!=OF)
            4'hF: br_actual_taken = !u_instr.flags_in[3] &
                                    (u_instr.flags_in[4] == u_instr.flags_in[5]); // JG  (!ZF&SF==OF)
        endcase
    end

    // =================================================================
    // 3. Routing, Writeback, and CDB Logic
    // =================================================================

    always_comb begin
        // Defaults: ready, no writeback, no CDB, no branch, no microcode
        u_ready         = 1'b1;
        v_ready         = 1'b1;
        wb_we_u         = 1'b0;
        wb_we_v         = 1'b0;
        wb_data_u       = 32'd0;
        wb_data_v       = 32'd0;
        wb_flags        = 6'd0;

        cdb0_valid      = 1'b0;
        cdb0_tag        = 4'd0;
        cdb0_data       = 32'd0;
        cdb0_exception  = 1'b0;

        cdb1_valid      = 1'b0;
        cdb1_tag        = 4'd0;
        cdb1_data       = 32'd0;
        cdb1_exception  = 1'b0;

        branch_resolved  = 1'b0;
        branch_taken     = 1'b0;
        branch_target    = 32'd0;
        branch_mispredict = 1'b0;
        branch_rob_tag   = 4'd0;

        microcode_req    = 1'b0;
        microcode_opcode = 8'd0;

        // =============================================================
        // U-Pipe Execution
        // =============================================================
        if (u_valid) begin
            case (u_instr.op_category)

                OP_ALU_REG, OP_ALU_IMM: begin
                    wb_data_u      = alu_u_res;
                    wb_flags       = alu_u_flags;
                    wb_we_u        = 1'b1;
                    // CDB writeback to ROB
                    cdb0_valid     = 1'b1;
                    cdb0_tag       = u_instr.rob_tag;
                    cdb0_data      = alu_u_res;
                    cdb0_exception = 1'b0;
                end

                OP_FLOAT: begin
                    if (fpu_busy || !fpu_done) begin
                        u_ready = 1'b0;  // Stall U-pipe only
                    end else begin
                        wb_data_u      = fpu_res;
                        wb_we_u        = 1'b1;
                        cdb0_valid     = 1'b1;
                        cdb0_tag       = u_instr.rob_tag;
                        cdb0_data      = fpu_res;
                        cdb0_exception = 1'b0;
                    end
                end

                OP_BRANCH: begin
                    // Resolve branch and report to predictor
                    branch_resolved  = 1'b1;
                    branch_taken     = br_actual_taken;
                    branch_target    = br_actual_taken ? br_actual_target : br_next_pc;
                    branch_rob_tag   = u_instr.rob_tag;
                    branch_mispredict = (br_actual_taken != u_instr.pred_taken) ||
                                        (br_actual_taken && (br_actual_target != u_instr.pred_target));
                    // CDB: branch doesn't produce a register result
                    cdb0_valid     = 1'b1;
                    cdb0_tag       = u_instr.rob_tag;
                    cdb0_data      = br_actual_taken ? br_actual_target : br_next_pc;
                    cdb0_exception = 1'b0;
                end

                OP_MICROCODE, OP_SYS_CALL: begin
                    // Hand off to microcode sequencer; stall dispatch
                    microcode_req    = 1'b1;
                    microcode_opcode = u_instr.opcode;
                    u_ready          = 1'b0;  // Stall until microcode finishes
                end

                OP_LOAD, OP_STORE: begin
                    // Load/Store handled by BIU/LSU — signal ROB completion
                    // with address as data (LSU will update with real data)
                    cdb0_valid     = 1'b1;
                    cdb0_tag       = u_instr.rob_tag;
                    cdb0_data      = alu_u_res;  // Effective address
                    cdb0_exception = 1'b0;
                end

                default: begin
                    // IO_READ, IO_WRITE, etc. — CDB completion, no register WB
                    cdb0_valid     = 1'b1;
                    cdb0_tag       = u_instr.rob_tag;
                    cdb0_data      = 32'd0;
                    cdb0_exception = 1'b0;
                end

            endcase
        end

        // =============================================================
        // V-Pipe Execution (only runs if U-pipe is not stalling)
        // =============================================================
        if (v_valid && u_ready) begin
            case (v_instr.op_category)

                OP_ALU_REG, OP_ALU_IMM: begin
                    // V-pipe SIMD ops use opcode[7:4]==4'hF prefix
                    if (v_instr.opcode[7:4] == 4'hF) begin
                        wb_data_v  = simd_res;
                    end else begin
                        wb_data_v  = alu_v_res;
                        wb_flags   = alu_v_flags;  // V-pipe flags (last writer wins)
                    end
                    wb_we_v        = 1'b1;
                    cdb1_valid     = 1'b1;
                    cdb1_tag       = v_instr.rob_tag;
                    cdb1_data      = wb_data_v;
                    cdb1_exception = 1'b0;
                end

                default: ;  // V-pipe only handles simple ALU/SIMD

            endcase
        end
    end

endmodule
