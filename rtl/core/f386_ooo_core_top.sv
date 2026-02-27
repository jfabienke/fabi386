/*
 * fabi386: Out-of-Order Core Top-Level (v18.0)
 * ---------------------------------------------
 * Integrates the full superscalar OoO pipeline:
 *
 *   Fetch → Decode → Rename → Dispatch/IQ → Execute → ROB → Retire
 *                                                  ↑       |
 *                                                  +--CDB---+
 *
 * Submodules wired:
 *   f386_branch_predict_hybrid  — Gshare + RAS branch predictor
 *   f386_decode                 — Dual-issue superscalar decoder
 *   f386_register_rename        — 8→32 physical register mapping
 *   f386_issue_queue            — 8-entry reservation station
 *   f386_rob                    — 16-entry reorder buffer
 *   f386_execute_stage          — Dual ALU + FPU + SIMD + branch resolution
 *
 * External interfaces:
 *   Memory bus (fetch block + data load/store)
 *   Telemetry (retired instruction trace)
 */

import f386_pkg::*;

module f386_ooo_core_top (
    input  logic         clk,
    input  logic         rst_n,

    // --- Fetch Memory Interface ---
    output logic [31:0]  fetch_addr,
    input  logic [127:0] fetch_data,      // 16-byte fetch block from I-cache/bus
    input  logic         fetch_data_valid,
    output logic         fetch_req,

    // --- Data Memory Interface (to BIU / L1D) ---
    output logic [31:0]  mem_addr,
    output logic [31:0]  mem_wdata,
    input  logic [31:0]  mem_rdata,
    output logic         mem_req,
    output logic         mem_wr,
    input  logic         mem_ack,

    // --- CPU Mode (from Control Registers) ---
    input  logic         pe_mode,         // CR0.PE — Protected Mode
    input  logic         v86_mode,        // EFLAGS.VM — Virtual 8086
    input  logic         default_32,      // CS.D — Default operand/address size

    // --- Telemetry Port (HARE Suite) ---
    output telemetry_pkt_t trace_out,
    output logic           trace_valid,

    // --- External Interrupts ---
    input  logic         irq,
    input  logic [7:0]   irq_vector
);

    // =================================================================
    // Internal Wiring
    // =================================================================

    // --- Fetch / PC ---
    logic [31:0] pc_current;
    logic [31:0] pc_next;
    logic        fetch_ack;

    // --- Branch Predictor ---
    logic [31:0] bp_next_pc;
    logic        bp_predict_taken;
    logic        bp_is_ret;

    // --- Decode → Rename/ROB ---
    ooo_instr_t  dec_instr_u, dec_instr_v;
    logic        dec_instr_u_valid, dec_instr_v_valid;
    logic        dec_branch_target_u_valid, dec_branch_target_v_valid;
    logic [31:0] dec_branch_target_u, dec_branch_target_v;
    logic        dec_branch_indirect_u, dec_branch_indirect_v;
    logic        dec_u_reads_flags, dec_u_writes_flags;
    logic        dec_v_reads_flags, dec_v_writes_flags;
    logic [2:0]  dec_u_addr_base, dec_u_addr_index;
    logic        dec_u_addr_base_valid, dec_u_addr_index_valid;
    logic [1:0]  dec_u_addr_scale;
    logic [2:0]  dec_v_addr_base, dec_v_addr_index;
    logic        dec_v_addr_base_valid, dec_v_addr_index_valid;
    logic [1:0]  dec_v_addr_scale;

    // --- Rename ---
    logic        rename_ready;
    phys_reg_t   rename_phys_u;

    // --- Issue Queue ---
    ooo_instr_t  iq_issue_instr;
    logic        iq_issue_valid;

    // --- ROB ---
    rob_id_t     rob_tag_u, rob_tag_v;
    logic        rob_full;
    rob_entry_t  rob_retire_u, rob_retire_v;
    logic        rob_retire_u_valid, rob_retire_v_valid;

    // --- Execute Stage → CDB ---
    logic        cdb0_valid, cdb1_valid;
    rob_id_t     cdb0_tag, cdb1_tag;
    logic [31:0] cdb0_data, cdb1_data;
    logic        cdb0_exception, cdb1_exception;

    // --- Execute Stage → Writeback ---
    logic [31:0] wb_data_u, wb_data_v;
    logic [5:0]  wb_flags;
    logic [3:0]  wb_fpu_status;
    logic        wb_fpu_status_we;
    logic        wb_we_u, wb_we_v;
    logic        exec_u_ready, exec_v_ready;

    // --- Execute Stage → Branch Resolution ---
    logic        branch_resolved;
    logic        branch_taken;
    logic [31:0] branch_target;
    logic        branch_mispredict;
    rob_id_t     branch_rob_tag;

    // --- Execute Stage → Microcode ---
    logic        microcode_req;
    logic [7:0]  microcode_opcode;

    // --- Flush Signal ---
    // Triggered by branch misprediction — squashes all in-flight work
    logic        flush;
    assign flush = branch_mispredict;

    // =================================================================
    // 1. Program Counter
    // =================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc_current <= 32'h0000_FFF0;  // x86 reset vector (high)
        else if (flush)
            pc_current <= branch_target;   // Redirect on mispredict
        else if (fetch_ack)
            pc_current <= pc_next;
    end

    // Next PC: predicted (from BP) or sequential (PC + fetch block consumed)
    assign pc_next   = bp_predict_taken ? bp_next_pc : (pc_current + 32'd16);
    assign fetch_addr = pc_current;
    assign fetch_req  = !flush;  // Always fetching unless flushing

    // =================================================================
    // 2. Branch Predictor
    // =================================================================
    f386_branch_predict_hybrid bp_inst (
        .clk           (clk),
        .reset_n       (rst_n),

        // Fetch stage
        .fetch_pc      (pc_current),
        .is_ret_op     (bp_is_ret),
        .next_pc_pred  (bp_next_pc),
        .predict_taken (bp_predict_taken),

        // Feedback from decode (call/ret detection)
        .dec_is_call   (dec_instr_u_valid && dec_instr_u.op_cat == OP_BRANCH &&
                        dec_instr_u.opcode[7:4] == 4'hE),  // CALL-like
        .dec_ret_addr  (dec_instr_u.pc + {24'd0, dec_instr_u.raw_instr[7:0]}),
        .dec_is_ret    (bp_is_ret),

        // Feedback from execute (branch resolution)
        .res_valid          (branch_resolved),
        .res_pc             (dec_instr_u.pc),
        .res_actually_taken (branch_taken),
        .res_is_mispredict  (branch_mispredict)
    );

    // Simple RET detection from decode output
    assign bp_is_ret = dec_instr_u_valid &&
                       dec_instr_u.op_cat == OP_BRANCH &&
                       dec_instr_u.opcode == 8'hC3;

    // =================================================================
    // 3. Decoder
    // =================================================================
    f386_decode decoder (
        .clk               (clk),
        .rst_n             (rst_n),

        .fetch_block       (fetch_data),
        .fetch_valid       (fetch_data_valid),
        .current_pc        (pc_current),
        .fetch_ack         (fetch_ack),

        .instr_u           (dec_instr_u),
        .instr_u_valid     (dec_instr_u_valid),
        .instr_v           (dec_instr_v),
        .instr_v_valid     (dec_instr_v_valid),
        .rename_ready      (rename_ready && !rob_full),

        .branch_target_u       (dec_branch_target_u),
        .branch_target_u_valid (dec_branch_target_u_valid),
        .branch_indirect_u     (dec_branch_indirect_u),
        .branch_target_v       (dec_branch_target_v),
        .branch_target_v_valid (dec_branch_target_v_valid),
        .branch_indirect_v     (dec_branch_indirect_v),

        .u_reads_flags     (dec_u_reads_flags),
        .u_writes_flags    (dec_u_writes_flags),
        .v_reads_flags     (dec_v_reads_flags),
        .v_writes_flags    (dec_v_writes_flags),

        .u_addr_base       (dec_u_addr_base),
        .u_addr_base_valid (dec_u_addr_base_valid),
        .u_addr_index      (dec_u_addr_index),
        .u_addr_index_valid(dec_u_addr_index_valid),
        .u_addr_scale      (dec_u_addr_scale),
        .v_addr_base       (dec_v_addr_base),
        .v_addr_base_valid (dec_v_addr_base_valid),
        .v_addr_index      (dec_v_addr_index),
        .v_addr_index_valid(dec_v_addr_index_valid),
        .v_addr_scale      (dec_v_addr_scale),

        .pe_mode           (pe_mode),
        .v86_mode          (v86_mode),
        .default_32        (default_32)
    );

    // =================================================================
    // 4. Register Rename
    // =================================================================
    f386_register_rename renamer (
        .clk           (clk),
        .reset_n       (rst_n),

        .arch_dest_u   (dec_instr_u.p_dest[2:0]),
        .phys_dest_u   (rename_phys_u),
        .can_rename    (rename_ready),

        .retire_valid  (rob_retire_u_valid),
        .retire_phys   (rob_retire_u.instr.p_dest)
    );

    // =================================================================
    // 5. Issue Queue (Reservation Station)
    // =================================================================
    f386_issue_queue iq (
        .clk             (clk),
        .reset_n         (rst_n),

        .dispatch_instr  (dec_instr_u),
        .dispatch_valid  (dec_instr_u_valid && rename_ready && !rob_full),

        .issue_instr     (iq_issue_instr),
        .issue_valid     (iq_issue_valid),
        .exec_ready      (exec_u_ready)
    );

    // =================================================================
    // 6. Reorder Buffer
    // =================================================================
    f386_rob rob (
        .clk               (clk),
        .rst_n             (rst_n),

        // Dispatch
        .dispatch_u        (dec_instr_u),
        .dispatch_u_valid  (dec_instr_u_valid && rename_ready && !rob_full),
        .dispatch_v        (dec_instr_v),
        .dispatch_v_valid  (dec_instr_v_valid && rename_ready && !rob_full),
        .rob_tag_u         (rob_tag_u),
        .rob_tag_v         (rob_tag_v),
        .full              (rob_full),

        // CDB writeback from execute
        .cdb0_valid        (cdb0_valid),
        .cdb0_tag          (cdb0_tag),
        .cdb0_data         (cdb0_data),
        .cdb0_exception    (cdb0_exception),
        .cdb1_valid        (cdb1_valid),
        .cdb1_tag          (cdb1_tag),
        .cdb1_data         (cdb1_data),
        .cdb1_exception    (cdb1_exception),

        // Retirement
        .retire_u          (rob_retire_u),
        .retire_u_valid    (rob_retire_u_valid),
        .retire_v          (rob_retire_v),
        .retire_v_valid    (rob_retire_v_valid),

        // Flush
        .flush             (flush)
    );

    // =================================================================
    // 7. Execute Stage
    // =================================================================
    // Build instr_info_t from the IQ-issued ooo_instr_t for U-pipe,
    // and from decoded V-pipe instruction directly.

    instr_info_t exec_u_instr, exec_v_instr;

    // U-pipe: issued from IQ (out-of-order)
    always_comb begin
        exec_u_instr.is_valid    = iq_issue_valid;
        exec_u_instr.pc          = iq_issue_instr.pc;
        exec_u_instr.opcode      = iq_issue_instr.opcode;
        exec_u_instr.op_category = iq_issue_instr.op_cat;
        exec_u_instr.reg_dest    = iq_issue_instr.p_dest[2:0];
        exec_u_instr.reg_src_a   = iq_issue_instr.p_src_a[2:0];
        exec_u_instr.reg_src_b   = iq_issue_instr.p_src_b[2:0];
        exec_u_instr.rob_tag     = iq_issue_instr.rob_tag;
        exec_u_instr.imm_value   = iq_issue_instr.imm_value;
        exec_u_instr.flags_in    = 6'd0;  // TODO: forward from EFLAGS register
        exec_u_instr.pred_taken  = bp_predict_taken;
        exec_u_instr.pred_target = bp_next_pc;
    end

    // V-pipe: simple ops bypass IQ (in-order, paired with U)
    always_comb begin
        exec_v_instr.is_valid    = dec_instr_v_valid && rename_ready && !rob_full;
        exec_v_instr.pc          = dec_instr_v.pc;
        exec_v_instr.opcode      = dec_instr_v.opcode;
        exec_v_instr.op_category = dec_instr_v.op_cat;
        exec_v_instr.reg_dest    = dec_instr_v.p_dest[2:0];
        exec_v_instr.reg_src_a   = dec_instr_v.p_src_a[2:0];
        exec_v_instr.reg_src_b   = dec_instr_v.p_src_b[2:0];
        exec_v_instr.rob_tag     = rob_tag_v;
        exec_v_instr.imm_value   = dec_instr_v.imm_value;
        exec_v_instr.flags_in    = 6'd0;  // TODO: forward from EFLAGS register
        exec_v_instr.pred_taken  = 1'b0;
        exec_v_instr.pred_target = 32'd0;
    end

    f386_execute_stage exec_stage (
        .clk             (clk),
        .reset_n         (rst_n),

        // U-pipe
        .u_instr         (exec_u_instr),
        .u_op_a          (iq_issue_instr.val_a),
        .u_op_b          (iq_issue_instr.val_b),
        .u_valid         (iq_issue_valid),
        .u_ready         (exec_u_ready),

        // V-pipe
        .v_instr         (exec_v_instr),
        .v_op_a          (dec_instr_v.val_a),
        .v_op_b          (dec_instr_v.val_b),
        .v_valid         (exec_v_instr.is_valid),
        .v_ready         (exec_v_ready),

        // CDB
        .cdb0_valid      (cdb0_valid),
        .cdb0_tag        (cdb0_tag),
        .cdb0_data       (cdb0_data),
        .cdb0_exception  (cdb0_exception),
        .cdb1_valid      (cdb1_valid),
        .cdb1_tag        (cdb1_tag),
        .cdb1_data       (cdb1_data),
        .cdb1_exception  (cdb1_exception),

        // Writeback
        .wb_data_u       (wb_data_u),
        .wb_data_v       (wb_data_v),
        .wb_flags        (wb_flags),
        .wb_fpu_status   (wb_fpu_status),
        .wb_fpu_status_we(wb_fpu_status_we),
        .wb_we_u         (wb_we_u),
        .wb_we_v         (wb_we_v),

        // Branch resolution
        .branch_resolved (branch_resolved),
        .branch_taken    (branch_taken),
        .branch_target   (branch_target),
        .branch_mispredict(branch_mispredict),
        .branch_rob_tag  (branch_rob_tag),

        // Microcode
        .microcode_req   (microcode_req),
        .microcode_opcode(microcode_opcode)
    );

    // =================================================================
    // 8. Telemetry (Retired Instruction Trace)
    // =================================================================
    // Generate trace packets from retired instructions for the HARE
    // instrumentation suite (guard unit, PASC, snoop engine, etc.)

    always_comb begin
        trace_valid = rob_retire_u_valid;
        trace_out   = '0;

        if (rob_retire_u_valid) begin
            trace_out.is_data     = 1'b0;
            trace_out.instr       = rob_retire_u.instr;
            trace_out.data.addr   = rob_retire_u.data;
            trace_out.data.value  = rob_retire_u.data;
            trace_out.data.m_class = CLASS_INTERNAL;
            trace_out.data.taint  = 1'b0;
            trace_out.stack_fault = 1'b0;
        end
    end

    // =================================================================
    // 9. Data Memory Interface (Stub — LSU to be added)
    // =================================================================
    // Simple pass-through for load/store addresses from execute stage.
    // A full Load/Store Unit with store buffer will replace this.
    assign mem_addr  = wb_data_u;
    assign mem_wdata = 32'd0;     // Store data path TBD
    assign mem_req   = 1'b0;      // LSU will drive this
    assign mem_wr    = 1'b0;

endmodule
