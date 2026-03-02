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
    output logic [5:0]   cdb0_flags,       // ALU flags result {OF,SF,ZF,AF,PF,CF}
    output logic [5:0]   cdb0_flags_mask,  // Which flags this instruction writes
    output logic         cdb0_exception,

    output phys_reg_t    cdb0_phys_dest,   // Physical dest for PRF writeback

    output logic         cdb1_valid,
    output rob_id_t      cdb1_tag,
    output logic [31:0]  cdb1_data,
    output logic [5:0]   cdb1_flags,
    output logic [5:0]   cdb1_flags_mask,
    output logic         cdb1_exception,
    output phys_reg_t    cdb1_phys_dest,   // Physical dest for PRF writeback

    // --- Writeback to Architectural State ---
    output logic [31:0]  wb_data_u,
    output logic [31:0]  wb_data_v,
    output logic [5:0]   wb_flags,       // EFLAGS update {OF,SF,ZF,AF,PF,CF}
    output logic [3:0]   wb_fpu_status,  // x87 condition codes {C3,C2,C1,C0}
    output logic         wb_fpu_status_we, // FPU status valid
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

    // --- Bit-Count Unit (U-Pipe, combinational, Nehalem extensions) ---
    logic [31:0] bitcount_res;
    logic [5:0]  bitcount_flags;
    generate
        if (CONF_ENABLE_NEHALEM_EXT) begin : gen_bitcount
            f386_alu_bitcount bitcount_inst (
                .op_a       (u_op_a),
                .bitcount_op(u_instr.opcode[1:0]),
                .opsz       (u_instr.opcode[3:2]),  // Operand size from decoder
                .result     (bitcount_res),
                .flags_out  (bitcount_flags)
            );
        end else begin : gen_no_bitcount
            assign bitcount_res   = 32'd0;
            assign bitcount_flags = 6'd0;
        end
    endgenerate

    // --- CMOVcc Condition Evaluator (reuses branch condition logic) ---
    logic cmov_condition_met;
    always_comb begin
        cmov_condition_met = 1'b0;
        if (CONF_ENABLE_PENTIUM_EXT) begin
            case (u_instr.opcode[3:0])
                4'h0: cmov_condition_met =  u_instr.flags_in[5];           // CMOVO  (OF=1)
                4'h1: cmov_condition_met = !u_instr.flags_in[5];           // CMOVNO (OF=0)
                4'h2: cmov_condition_met =  u_instr.flags_in[0];           // CMOVB  (CF=1)
                4'h3: cmov_condition_met = !u_instr.flags_in[0];           // CMOVNB (CF=0)
                4'h4: cmov_condition_met =  u_instr.flags_in[3];           // CMOVE  (ZF=1)
                4'h5: cmov_condition_met = !u_instr.flags_in[3];           // CMOVNE (ZF=0)
                4'h6: cmov_condition_met =  u_instr.flags_in[0] | u_instr.flags_in[3]; // CMOVBE
                4'h7: cmov_condition_met = !u_instr.flags_in[0] & !u_instr.flags_in[3]; // CMOVA
                4'h8: cmov_condition_met =  u_instr.flags_in[4];           // CMOVS  (SF=1)
                4'h9: cmov_condition_met = !u_instr.flags_in[4];           // CMOVNS (SF=0)
                4'hA: cmov_condition_met =  u_instr.flags_in[1];           // CMOVP  (PF=1)
                4'hB: cmov_condition_met = !u_instr.flags_in[1];           // CMOVNP (PF=0)
                4'hC: cmov_condition_met =  u_instr.flags_in[4] != u_instr.flags_in[5]; // CMOVL
                4'hD: cmov_condition_met =  u_instr.flags_in[4] == u_instr.flags_in[5]; // CMOVGE
                4'hE: cmov_condition_met =  u_instr.flags_in[3] |
                                           (u_instr.flags_in[4] != u_instr.flags_in[5]); // CMOVLE
                4'hF: cmov_condition_met = !u_instr.flags_in[3] &
                                           (u_instr.flags_in[4] == u_instr.flags_in[5]); // CMOVG
            endcase
        end
    end

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

    // --- Divider (U-Pipe, multi-cycle, non-restoring) ---
    logic [31:0] div_quotient;
    logic [31:0] div_remainder;
    logic        div_busy;
    logic        div_done;
    logic        div_error;
    wire         div_is_signed = u_instr.opcode[0];    // opcode[0] = signed flag
    wire  [1:0]  div_op_size   = u_instr.opcode[2:1];  // opcode[2:1] = size
    wire         div_start     = u_valid && u_instr.op_category == OP_MUL_DIV &&
                                 u_instr.opcode[3] && !div_busy;  // opcode[3] = DIV vs MUL

    f386_divider divider_inst (
        .clk          (clk),
        .rst_n        (reset_n),
        .start        (div_start),
        .op_size      (div_op_size),
        .is_signed    (div_is_signed),
        .dividend     ({u_op_a, u_op_b}),   // {high, low}
        .divisor      (u_op_b),
        .quotient     (div_quotient),
        .remainder    (div_remainder),
        .busy         (div_busy),
        .done         (div_done),
        .divide_error (div_error)
    );

    // --- Multiplier (U-Pipe, 2-cycle DSP pipeline) ---
    logic [63:0] mul_result;
    logic        mul_done;
    logic        mul_overflow;
    wire         mul_is_signed = u_instr.opcode[0];
    wire  [1:0]  mul_op_size   = u_instr.opcode[2:1];
    wire         mul_start     = u_valid && u_instr.op_category == OP_MUL_DIV &&
                                 !u_instr.opcode[3] && !div_busy;  // opcode[3]=0 → MUL

    f386_multiplier mul_inst (
        .clk           (clk),
        .rst_n         (reset_n),
        .start         (mul_start),
        .op_size       (mul_op_size),
        .is_signed     (mul_is_signed),
        .op_a          (u_op_a),
        .op_b          (u_op_b),
        .result        (mul_result),
        .done          (mul_done),
        .overflow_flag (mul_overflow)
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
            4'h0: br_actual_taken =  u_instr.flags_in[5];           // JO  (OF=1)
            4'h1: br_actual_taken = !u_instr.flags_in[5];           // JNO (OF=0)
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
        wb_fpu_status   = 4'd0;
        wb_fpu_status_we = 1'b0;

        cdb0_valid      = 1'b0;
        cdb0_tag        = 4'd0;
        cdb0_data       = 32'd0;
        cdb0_flags      = 6'd0;
        cdb0_flags_mask = 6'd0;
        cdb0_exception  = 1'b0;
        cdb0_phys_dest  = u_instr.phys_dest;

        cdb1_valid      = 1'b0;
        cdb1_tag        = 4'd0;
        cdb1_data       = 32'd0;
        cdb1_flags      = 6'd0;
        cdb1_flags_mask = 6'd0;
        cdb1_exception  = 1'b0;
        cdb1_phys_dest  = v_instr.phys_dest;

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
                    wb_data_u       = alu_u_res;
                    wb_flags        = alu_u_flags;
                    wb_we_u         = 1'b1;
                    // CDB writeback to ROB (flags travel with data)
                    cdb0_valid      = 1'b1;
                    cdb0_tag        = u_instr.rob_tag;
                    cdb0_data       = alu_u_res;
                    cdb0_flags      = alu_u_flags;
                    cdb0_flags_mask = u_instr.flags_mask;
                    cdb0_exception  = 1'b0;
                end

                OP_FLOAT: begin
                    if (fpu_busy || !fpu_done) begin
                        u_ready = 1'b0;  // Stall U-pipe only
                    end else begin
                        wb_data_u        = fpu_res;
                        wb_we_u          = 1'b1;
                        wb_fpu_status    = fpu_status;
                        wb_fpu_status_we = 1'b1;
                        cdb0_valid       = 1'b1;
                        cdb0_tag         = u_instr.rob_tag;
                        cdb0_data        = fpu_res;
                        // Exception: NaN or Inf result indicates FPU fault
                        cdb0_exception   = (fpu_res[30:23] == 8'hFF);
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

                OP_MUL_DIV: begin
                    if (u_instr.opcode[3]) begin
                        // DIV/IDIV — multi-cycle
                        if (div_busy || !div_done) begin
                            u_ready = 1'b0;  // Stall U-pipe
                        end else begin
                            wb_data_u       = div_quotient;
                            wb_we_u         = 1'b1;
                            cdb0_valid      = 1'b1;
                            cdb0_tag        = u_instr.rob_tag;
                            cdb0_data       = div_quotient;
                            cdb0_exception  = div_error;  // #DE
                        end
                    end else begin
                        // MUL/IMUL — 2-cycle pipeline
                        if (!mul_done) begin
                            u_ready = 1'b0;
                        end else begin
                            wb_data_u       = mul_result[31:0];
                            wb_we_u         = 1'b1;
                            // CF=OF set if upper half significant
                            cdb0_flags      = {mul_overflow, 4'b0000, mul_overflow};
                            cdb0_flags_mask = 6'b100001;  // OF, CF only
                            cdb0_valid      = 1'b1;
                            cdb0_tag        = u_instr.rob_tag;
                            cdb0_data       = mul_result[31:0];
                            cdb0_exception  = 1'b0;
                        end
                    end
                end

                OP_LOAD, OP_STORE: begin
                    // Load/Store handled by BIU/LSU — signal ROB completion
                    // with address as data (LSU will update with real data)
                    cdb0_valid     = 1'b1;
                    cdb0_tag       = u_instr.rob_tag;
                    cdb0_data      = alu_u_res;  // Effective address
                    cdb0_exception = 1'b0;
                end

                OP_CMOV: begin
                    // CMOVcc: if condition met, write source; else keep dest unchanged
                    wb_data_u       = cmov_condition_met ? u_op_b : u_op_a;
                    wb_we_u         = 1'b1;
                    cdb0_valid      = 1'b1;
                    cdb0_tag        = u_instr.rob_tag;
                    cdb0_data       = cmov_condition_met ? u_op_b : u_op_a;
                    cdb0_flags      = 6'd0;
                    cdb0_flags_mask = 6'b000000;  // CMOVcc modifies no flags
                    cdb0_exception  = 1'b0;
                end

                OP_BITCOUNT: begin
                    // POPCNT / LZCNT / TZCNT
                    wb_data_u       = bitcount_res;
                    wb_flags        = bitcount_flags;
                    wb_we_u         = 1'b1;
                    cdb0_valid      = 1'b1;
                    cdb0_tag        = u_instr.rob_tag;
                    cdb0_data       = bitcount_res;
                    cdb0_flags      = bitcount_flags;
                    cdb0_flags_mask = 6'b001001;  // ZF, CF only
                    cdb0_exception  = 1'b0;
                end

                OP_FENCE: begin
                    // MFENCE/LFENCE/SFENCE — NOP completion (LSQ hook point)
                    cdb0_valid      = 1'b1;
                    cdb0_tag        = u_instr.rob_tag;
                    cdb0_data       = 32'd0;
                    cdb0_exception  = 1'b0;
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
                        // SIMD ops don't produce ALU flags
                    end else begin
                        wb_data_v       = alu_v_res;
                        wb_flags        = alu_v_flags;
                        cdb1_flags      = alu_v_flags;
                        cdb1_flags_mask = v_instr.flags_mask;
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
