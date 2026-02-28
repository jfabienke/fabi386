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
    logic [5:0]  rob_retire_u_flags, rob_retire_u_flags_mask;
    logic [5:0]  rob_retire_v_flags, rob_retire_v_flags_mask;

    // --- Execute Stage → CDB ---
    logic        cdb0_valid, cdb1_valid;
    rob_id_t     cdb0_tag, cdb1_tag;
    logic [31:0] cdb0_data, cdb1_data;
    logic [5:0]  cdb0_flags, cdb1_flags;
    logic [5:0]  cdb0_flags_mask, cdb1_flags_mask;
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

    // --- SpecBits (Phase P1) ---
    br_tag_t     specbits_alloc_tag;
    logic        specbits_alloc_valid;
    specbits_t   specbits_cur;
    specbits_t   specbits_squash_mask;
    logic        specbits_tags_available;

    // --- FTQ (Phase P1) ---
    ftq_idx_t    ftq_enq_idx;
    logic        ftq_enq_ready;
    logic        ftq_deq_valid;
    logic [31:0] ftq_deq_pc;
    logic        ftq_deq_pred_taken;
    logic [31:0] ftq_deq_pred_target;
    br_tag_t     ftq_deq_br_tag;
    logic        ftq_deq_has_branch;
    ftq_idx_t    ftq_deq_idx;
    logic [31:0] ftq_redirect_repair_pc;
    logic [CONF_GHR_WIDTH-1:0] ftq_redirect_repair_ghr;

    // --- CPU Mode (driven by sys_regs) ---
    logic        pe_mode;
    logic        v86_mode;
    logic        default_32;

    // --- System Register File Outputs ---
    logic [31:0] sys_cr0, sys_cr2, sys_cr3, sys_cr4;
    logic [31:0] sys_eflags;
    logic [31:0] sys_gdtr_base, sys_idtr_base;
    logic [15:0] sys_gdtr_limit, sys_idtr_limit;
    logic [15:0] sys_ldtr_sel, sys_tr_sel;
    logic [63:0] sys_ldtr_cache, sys_tr_cache;
    logic [1:0]  sys_cpl;
    logic [1:0]  sys_iopl;
    logic        sys_iopl_allow;
    logic        sys_pg_mode, sys_vme_enabled, sys_pse_enabled, sys_wp_enabled;
    logic        cr0_write_flush, cr3_write_flush, cr4_write_flush;

    // --- Segment Cache Outputs ---
    logic [15:0] seg_cs_sel;
    logic        seg_cs_db;

    // --- ALU Flags Gather (EFLAGS → packed 6-bit for execute stage) ---
    wire [5:0] alu_flags_current = {
        sys_eflags[EFLAGS_OF],   // [5] OF
        sys_eflags[EFLAGS_SF],   // [4] SF
        sys_eflags[EFLAGS_ZF],   // [3] ZF
        sys_eflags[EFLAGS_AF],   // [2] AF
        sys_eflags[EFLAGS_PF],   // [1] PF
        sys_eflags[EFLAGS_CF]    // [0] CF
    };

    // --- Flush Signal ---
    // Triggered by branch misprediction or system register changes
    logic        flush;
    assign flush = branch_mispredict || cr0_write_flush || cr3_write_flush || cr4_write_flush;

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

        .arch_dest_v   (dec_instr_v.p_dest[2:0]),
        .phys_dest_v   (),
        .rename_v_valid(dec_instr_v_valid && rename_ready && !rob_full),

        .src_arch_a    (dec_instr_u.p_src_a[2:0]),
        .src_arch_b    (dec_instr_u.p_src_b[2:0]),
        .src_phys_a    (),
        .src_phys_b    (),
        .src_busy_a    (),
        .src_busy_b    (),

        .retire_valid  (rob_retire_u_valid),
        .retire_phys   (rob_retire_u.instr.p_dest),
        .retire_arch   (rob_retire_u.instr.p_dest[2:0]),
        .retire_old_phys('0),  // TODO: carry old_phys through ROB

        .retire_v_valid  (rob_retire_v_valid),
        .retire_v_arch   (rob_retire_v.instr.p_dest[2:0]),
        .retire_v_phys   (rob_retire_v.instr.p_dest),
        .retire_v_old_phys('0),

        .branch_dispatch (dec_instr_u_valid && dec_instr_u.op_cat == OP_BRANCH &&
                           rename_ready && !rob_full),
        .branch_id       (specbits_alloc_tag),
        .branch_mispredict(branch_mispredict),
        .branch_restore_id(specbits_alloc_tag),

        .cdb0_valid    (cdb0_valid),
        .cdb0_dest     (cdb0_phys_dest),
        .cdb1_valid    (cdb1_valid),
        .cdb1_dest     (cdb1_phys_dest),

        .flush         (flush),

        // Context pre-warm (unused until scheduler integration)
        .pre_warm_valid   (1'b0),
        .pre_warm_arch_reg(3'b000),
        .pre_warm_value   (32'd0),
        .pre_warm_ready   ()
    );

    // =================================================================
    // 5. Issue Queue (Reservation Station)
    // =================================================================
    // CDB physical register destinations (for IQ operand capture)
    phys_reg_t cdb0_phys_dest, cdb1_phys_dest;
    assign cdb0_phys_dest = phys_reg_t'(cdb0_tag);  // TODO: carry phys_dest through execute
    assign cdb1_phys_dest = phys_reg_t'(cdb1_tag);

    f386_issue_queue iq (
        .clk             (clk),
        .reset_n         (rst_n),

        .dispatch_instr  (dec_instr_u),
        .dispatch_valid  (dec_instr_u_valid && rename_ready && !rob_full),

        .issue_instr     (iq_issue_instr),
        .issue_valid     (iq_issue_valid),
        .exec_ready      (exec_u_ready),

        // CDB (for wakeup and operand capture)
        .cdb0_valid      (cdb0_valid),
        .cdb0_tag        (cdb0_tag),
        .cdb0_data       (cdb0_data),
        .cdb0_dest       (cdb0_phys_dest),
        .cdb1_valid      (cdb1_valid),
        .cdb1_tag        (cdb1_tag),
        .cdb1_data       (cdb1_data),
        .cdb1_dest       (cdb1_phys_dest),

        // Flush
        .flush           (flush)
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

        // CDB writeback from execute (flags travel with data — BOOM/RSD pattern)
        .cdb0_valid        (cdb0_valid),
        .cdb0_tag          (cdb0_tag),
        .cdb0_data         (cdb0_data),
        .cdb0_flags        (cdb0_flags),
        .cdb0_flags_mask   (cdb0_flags_mask),
        .cdb0_exception    (cdb0_exception),
        .cdb1_valid        (cdb1_valid),
        .cdb1_tag          (cdb1_tag),
        .cdb1_data         (cdb1_data),
        .cdb1_flags        (cdb1_flags),
        .cdb1_flags_mask   (cdb1_flags_mask),
        .cdb1_exception    (cdb1_exception),

        // Retirement (flags forwarded to sys_regs for architectural commit)
        .retire_u          (rob_retire_u),
        .retire_u_valid    (rob_retire_u_valid),
        .retire_u_flags    (rob_retire_u_flags),
        .retire_u_flags_mask(rob_retire_u_flags_mask),
        .retire_v          (rob_retire_v),
        .retire_v_valid    (rob_retire_v_valid),
        .retire_v_flags    (rob_retire_v_flags),
        .retire_v_flags_mask(rob_retire_v_flags_mask),

        // LSQ index pairing (stubs until LSU integration)
        .dispatch_u_lq_idx ('0),
        .dispatch_u_sq_idx ('0),
        .dispatch_v_lq_idx ('0),
        .dispatch_v_sq_idx ('0),
        .retire_u_sq_idx   (),
        .retire_u_is_store (),
        .retire_v_sq_idx   (),
        .retire_v_is_store (),

        // SpecBits (Phase P1)
        .dispatch_u_specbits     (specbits_cur),
        .dispatch_v_specbits     (specbits_cur),
        .dispatch_u_ftq_idx      (ftq_deq_idx),
        .dispatch_v_ftq_idx      (ftq_deq_idx),
        .specbits_resolve_valid  (branch_resolved && !branch_mispredict),
        .specbits_resolve_tag    (specbits_alloc_tag),
        .specbits_squash_valid   (branch_mispredict),
        .specbits_squash_mask    (specbits_squash_mask),

        // Flush
        .flush             (flush)
    );

    // =================================================================
    // 6b. SpecBits Manager (Phase P1)
    // =================================================================
    f386_specbits specbits_mgr (
        .clk              (clk),
        .rst_n            (rst_n),
        .flush            (flush),

        // Allocation (at branch dispatch)
        .alloc_req        (dec_instr_u_valid && dec_instr_u.op_cat == OP_BRANCH &&
                           rename_ready && !rob_full),
        .alloc_tag        (specbits_alloc_tag),
        .alloc_valid      (specbits_alloc_valid),

        // Current mask (carried by all dispatched instructions)
        .cur_specbits     (specbits_cur),

        // Resolution (correct prediction → clear bit)
        .resolve_valid    (branch_resolved && !branch_mispredict),
        .resolve_tag      (specbits_alloc_tag),  // TODO: carry br_tag through execute

        // Squash (misprediction → kill tagged instructions)
        .squash_valid     (branch_mispredict),
        .squash_tag       (specbits_alloc_tag),  // TODO: carry br_tag through execute
        .squash_mask      (specbits_squash_mask),

        .tags_available   (specbits_tags_available)
    );

    // =================================================================
    // 6c. Fetch Target Queue (Phase P1)
    // =================================================================
    f386_ftq ftq (
        .clk              (clk),
        .rst_n            (rst_n),
        .flush            (flush),

        // Enqueue (from fetch stage)
        .enq_valid        (fetch_data_valid && !flush),
        .enq_fetch_pc     (pc_current),
        .enq_pred_taken   (bp_predict_taken),
        .enq_pred_target  (bp_next_pc),
        .enq_br_tag       (specbits_alloc_tag),
        .enq_has_branch   (1'b0),  // TODO: populated by pre-decode scan
        .enq_ghr          ('0),    // TODO: GHR snapshot from branch predictor
        .enq_ready        (ftq_enq_ready),
        .enq_ftq_idx      (ftq_enq_idx),

        // Dequeue (to decode/dispatch)
        .deq_valid        (ftq_deq_valid),
        .deq_fetch_pc     (ftq_deq_pc),
        .deq_pred_taken   (ftq_deq_pred_taken),
        .deq_pred_target  (ftq_deq_pred_target),
        .deq_br_tag       (ftq_deq_br_tag),
        .deq_has_branch   (ftq_deq_has_branch),
        .deq_ftq_idx      (ftq_deq_idx),
        .deq_ready        (dec_instr_u_valid),  // Decode consumed the block

        // Redirect (mispredict)
        .redirect_valid   (branch_mispredict),
        .redirect_ftq_idx (ftq_deq_idx),  // TODO: carry ftq_idx through execute
        .redirect_repair_pc (ftq_redirect_repair_pc),
        .redirect_repair_ghr(ftq_redirect_repair_ghr),

        // ROB PC lookup
        .lookup_idx       ('0),    // Driven by retirement when needed
        .lookup_pc        ()       // Available for exception PC reporting
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
        exec_u_instr.flags_in    = alu_flags_current;
        exec_u_instr.flags_mask  = (iq_issue_instr.op_cat == OP_ALU_REG ||
                                    iq_issue_instr.op_cat == OP_ALU_IMM) ? 6'b111111 : 6'b000000;
        exec_u_instr.pred_taken  = bp_predict_taken;
        exec_u_instr.pred_target = bp_next_pc;
        exec_u_instr.sem_tag     = SEM_NONE;  // Populated by decoder in future
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
        exec_v_instr.flags_in    = alu_flags_current;
        exec_v_instr.flags_mask  = (dec_instr_v.op_cat == OP_ALU_REG ||
                                    dec_instr_v.op_cat == OP_ALU_IMM) ? 6'b111111 : 6'b000000;
        exec_v_instr.pred_taken  = 1'b0;
        exec_v_instr.pred_target = 32'd0;
        exec_v_instr.sem_tag     = SEM_NONE;
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

        // CDB (flags travel alongside data through ROB)
        .cdb0_valid      (cdb0_valid),
        .cdb0_tag        (cdb0_tag),
        .cdb0_data       (cdb0_data),
        .cdb0_flags      (cdb0_flags),
        .cdb0_flags_mask (cdb0_flags_mask),
        .cdb0_exception  (cdb0_exception),
        .cdb1_valid      (cdb1_valid),
        .cdb1_tag        (cdb1_tag),
        .cdb1_data       (cdb1_data),
        .cdb1_flags      (cdb1_flags),
        .cdb1_flags_mask (cdb1_flags_mask),
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
    // 8. System Register File
    // =================================================================
    // ALU flags write: only at retirement, never speculatively.
    // The mask from ROB tells sys_regs exactly which flags to commit.
    // If both U and V retire with flags, merge: V is younger (program order),
    // so V's flags take priority on overlapping bits; U's unique bits also apply.
    logic        retire_u_writes_flags, retire_v_writes_flags;
    logic [5:0]  merged_retire_flags, merged_retire_flags_mask;

    assign retire_u_writes_flags = rob_retire_u_valid && (rob_retire_u_flags_mask != 6'd0);
    assign retire_v_writes_flags = rob_retire_v_valid && (rob_retire_v_flags_mask != 6'd0);

    // Merge: for each bit, V wins if V writes it, else U's value
    always_comb begin
        if (retire_v_writes_flags && retire_u_writes_flags) begin
            // Both retire with flags: merge masks, V takes priority per-bit
            merged_retire_flags_mask = rob_retire_u_flags_mask | rob_retire_v_flags_mask;
            for (int i = 0; i < 6; i++) begin
                merged_retire_flags[i] = rob_retire_v_flags_mask[i] ?
                    rob_retire_v_flags[i] : rob_retire_u_flags[i];
            end
        end else if (retire_v_writes_flags) begin
            merged_retire_flags      = rob_retire_v_flags;
            merged_retire_flags_mask = rob_retire_v_flags_mask;
        end else begin
            merged_retire_flags      = rob_retire_u_flags;
            merged_retire_flags_mask = rob_retire_u_flags_mask;
        end
    end

    f386_sys_regs sys_regs (
        .clk             (clk),
        .rst_n           (rst_n),

        // CR write port (undriven until microcode sequencer)
        .cr_idx          (CR_0),
        .cr_din          (32'h0),
        .cr_we           (1'b0),

        // Page fault CR2 (undriven until MMU)
        .pf_cr2_din      (32'h0),
        .pf_cr2_we       (1'b0),

        // EFLAGS write port (undriven until microcode sequencer)
        .eflags_din      (32'h0),
        .eflags_mask     (32'h0),
        .eflags_we       (1'b0),

        // ALU flags from ROB retirement (BOOM/RSD pattern: flags travel through ROB)
        .alu_flags_in    (merged_retire_flags),
        .alu_flags_mask  (merged_retire_flags_mask),
        .alu_flags_we    (retire_u_writes_flags || retire_v_writes_flags),

        // DTR write port (undriven until microcode sequencer)
        .dtr_idx         (DTR_GDTR),
        .dtr_base_din    (32'h0),
        .dtr_limit_din   (16'h0),
        .dtr_sel_din     (16'h0),
        .dtr_cache_din   (64'h0),
        .dtr_we          (1'b0),

        // CS selector input (for CPL = CS.RPL derivation)
        .cs_sel_in       (seg_cs_sel),

        // Segment cache D/B input
        .cs_cache_db     (seg_cs_db),

        // CR read ports
        .cr0             (sys_cr0),
        .cr2             (sys_cr2),
        .cr3             (sys_cr3),
        .cr4             (sys_cr4),

        // EFLAGS
        .eflags          (sys_eflags),

        // DTR read ports
        .gdtr_base       (sys_gdtr_base),
        .gdtr_limit      (sys_gdtr_limit),
        .idtr_base       (sys_idtr_base),
        .idtr_limit      (sys_idtr_limit),
        .ldtr_sel        (sys_ldtr_sel),
        .ldtr_cache      (sys_ldtr_cache),
        .tr_sel          (sys_tr_sel),
        .tr_cache        (sys_tr_cache),

        // CPL
        .cpl             (sys_cpl),

        // Derived outputs
        .pe_mode         (pe_mode),
        .pg_mode         (sys_pg_mode),
        .v86_mode        (v86_mode),
        .iopl            (sys_iopl),
        .iopl_allow      (sys_iopl_allow),
        .vme_enabled     (sys_vme_enabled),
        .pse_enabled     (sys_pse_enabled),
        .wp_enabled      (sys_wp_enabled),
        .default_32      (default_32),

        // Flush pulses
        .cr0_write_flush (cr0_write_flush),
        .cr3_write_flush (cr3_write_flush),
        .cr4_write_flush (cr4_write_flush)
    );

    // =================================================================
    // 9. Segment Shadow Register File
    // =================================================================
    f386_seg_cache seg_cache (
        .clk             (clk),
        .rst_n           (rst_n),

        // Write port (undriven until segment load microcode)
        .seg_idx             (SEG_ES),
        .seg_sel_din         (16'h0),
        .seg_cache_din       (64'h0),
        .seg_cache_valid_din (1'b1),
        .seg_we              (1'b0),

        // Selector read ports
        .es_sel          (),
        .cs_sel          (seg_cs_sel),
        .ss_sel          (),
        .ds_sel          (),
        .fs_sel          (),
        .gs_sel          (),

        // Cache read ports
        .es_cache        (),
        .cs_cache        (),
        .ss_cache        (),
        .ds_cache        (),
        .fs_cache        (),
        .gs_cache        (),

        // Extracted bases (active but unused until AGU integration)
        .es_base         (),
        .cs_base         (),
        .ss_base         (),
        .ds_base         (),
        .fs_base         (),
        .gs_base         (),

        // Extracted limits (active but unused until segment validation)
        .es_limit        (),
        .cs_limit        (),
        .ss_limit        (),
        .ds_limit        (),
        .fs_limit        (),
        .gs_limit        (),

        // Cache validity (active but unused until segment validation)
        .es_cache_valid  (),
        .cs_cache_valid  (),
        .ss_cache_valid  (),
        .ds_cache_valid  (),
        .fs_cache_valid  (),
        .gs_cache_valid  (),

        // CS D/B → sys_regs for default_32
        .cs_db           (seg_cs_db)
    );

    // =================================================================
    // 10. Telemetry (Retired Instruction Trace)
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
    // 11. V86 Safe-Trap Table (Neo-386 Pro)
    // =================================================================
    logic        v86_io_safe, v86_int_safe;
    logic [7:0]  v86_fast_ucode_base;

    f386_v86_safe_trap safe_trap (
        .clk              (clk),
        .rst_n            (rst_n),

        .v86_mode         (v86_mode),

        // Query (from decoder — uses first decoded instruction's info)
        .query_io_valid   (dec_instr_u_valid &&
                           (dec_instr_u.op_cat == OP_IO_READ || dec_instr_u.op_cat == OP_IO_WRITE)),
        .query_io_port    (dec_instr_u.imm_value[15:0]),
        .query_io_is_write(dec_instr_u.op_cat == OP_IO_WRITE),
        .query_int_valid  (dec_instr_u_valid && dec_instr_u.op_cat == OP_MICROCODE &&
                           dec_instr_u.opcode == 8'hCD),  // INT n
        .query_int_vector (dec_instr_u.imm_value[7:0]),

        .io_is_safe       (v86_io_safe),
        .int_is_safe      (v86_int_safe),
        .fast_ucode_base  (v86_fast_ucode_base),

        // Configuration (undriven until supervisor integration)
        .cfg_we           (1'b0),
        .cfg_is_int       (1'b0),
        .cfg_slot         (4'd0),
        .cfg_port         (16'd0),
        .cfg_port_allow_wr(1'b0),
        .cfg_int_vector   (8'd0),
        .cfg_enable       (1'b0)
    );

    // =================================================================
    // 12. Shadow Stack (Neo-386 Pro)
    // =================================================================
    logic        shadow_ret_mismatch;
    logic [31:0] shadow_expected_addr;
    logic [7:0]  shadow_mismatch_count;
    logic        shadow_overflow, shadow_underflow;

    f386_shadow_stack shadow_stack (
        .clk              (clk),
        .rst_n            (rst_n),
        .flush            (flush),

        .v86_mode         (v86_mode),

        // Push on CALL dispatch (opcode E8 = near CALL)
        .push_valid       (dec_instr_u_valid && rename_ready && !rob_full &&
                           dec_instr_u.op_cat == OP_BRANCH &&
                           dec_instr_u.opcode == 8'hE8),
        .push_ret_addr    (dec_instr_u.pc + {24'd0, dec_instr_u.raw_instr[7:0]} + 32'd1),

        // Pop on RET dispatch (opcode C3 = near RET)
        .pop_valid        (dec_instr_u_valid && rename_ready && !rob_full &&
                           dec_instr_u.op_cat == OP_BRANCH &&
                           dec_instr_u.opcode == 8'hC3),

        // Retirement validation
        .retire_ret_valid (rob_retire_u_valid &&
                           rob_retire_u.instr.opcode == 8'hC3),
        .retire_ret_target(rob_retire_u.data),

        .ret_mismatch     (shadow_ret_mismatch),
        .shadow_expected_addr(shadow_expected_addr),

        // Squash recovery (stub — needs depth tracking)
        .squash_valid     (branch_mispredict),
        .squash_depth     (5'd0),  // TODO: track speculative depth per branch

        .mismatch_count   (shadow_mismatch_count),
        .stack_overflow   (shadow_overflow),
        .stack_underflow  (shadow_underflow)
    );

    // =================================================================
    // 13. Semantic Transition Logger (Neo-386 Pro)
    // =================================================================
    logic        sem_log_valid;
    logic [127:0] sem_log_entry;
    logic [3:0]  sem_log_count;

    f386_semantic_logger sem_logger (
        .clk              (clk),
        .rst_n            (rst_n),
        .flush            (flush),

        .pe_mode          (pe_mode),
        .v86_mode         (v86_mode),
        .cpl              (sys_cpl),
        .eflags           (sys_eflags),
        .cr0              (sys_cr0),
        .cs_sel           (seg_cs_sel),

        .retire_valid     (rob_retire_u_valid),
        .retire_pc        (rob_retire_u.instr.pc),
        .retire_is_iret   (rob_retire_u_valid &&
                           rob_retire_u.instr.opcode == 8'hCF),
        .retire_is_int    (rob_retire_u_valid &&
                           (rob_retire_u.instr.opcode == 8'hCD ||
                            rob_retire_u.instr.opcode == 8'hCC)),

        // Exception events (stub until exception unit wired)
        .exc_delivered    (1'b0),
        .exc_vector       (8'd0),

        .shadow_mismatch  (shadow_ret_mismatch),

        .log_valid        (sem_log_valid),
        .log_entry        (sem_log_entry),
        .log_ready        (1'b0),  // TODO: wire to HARE DMA engine
        .log_count        (sem_log_count)
    );

    // =================================================================
    // 14. Data Memory Interface (Stub — LSU to be added)
    // =================================================================
    // Simple pass-through for load/store addresses from execute stage.
    // A full Load/Store Unit with store buffer will replace this.
    assign mem_addr  = wb_data_u;
    assign mem_wdata = 32'd0;     // Store data path TBD
    assign mem_req   = 1'b0;      // LSU will drive this
    assign mem_wr    = 1'b0;

endmodule
