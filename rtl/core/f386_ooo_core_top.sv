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

    // --- Data Memory Interface (legacy, to BIU / L1D — widened to 64-bit for P2) ---
    output logic [31:0]  mem_addr,
    output logic [63:0]  mem_wdata,
    input  logic [63:0]  mem_rdata,
    output logic         mem_req,
    output logic         mem_wr,
    output logic [7:0]   mem_byte_en,
    output logic         mem_cacheable,
    output logic         mem_strong_order,
    input  logic         mem_ack,
    input  logic         mem_gnt,

    // --- Split-Phase Data Port (active when CONF_ENABLE_MEM_FABRIC=1) ---
    output logic         sp_data_req_valid,
    input  logic         sp_data_req_ready,
    output mem_req_t     sp_data_req,
    input  logic         sp_data_rsp_valid,
    output logic         sp_data_rsp_ready,
    input  mem_rsp_t     sp_data_rsp,

    // --- A20 Gate (for AGU) ---
    input  logic         a20_gate,

    // --- Page Walker Memory Port (always present, tied off when TLB gate OFF) ---
    output logic [31:0]  pt_addr,
    output logic [31:0]  pt_wdata,
    input  logic [31:0]  pt_rdata,
    output logic         pt_req,
    output logic         pt_wr,
    input  logic         pt_ack,

    // --- Telemetry Port (HARE Suite) ---
    output telemetry_pkt_t trace_out,
    output logic           trace_valid,

    // --- External Interrupts ---
    input  logic         irq,
    input  logic [7:0]   irq_vector
`ifdef VERILATOR
    ,input logic         test_force_flush
`endif
);

    `include "f386_microcode_defs.svh"

    // =================================================================
    // Feature Gate Overrides (Verilator test harnesses)
    // =================================================================
`ifdef VERILATOR_ENABLE_LSQ_MEMIF
    localparam bit LOCAL_ENABLE_LSQ_MEMIF = 1'b1;
`else
    localparam bit LOCAL_ENABLE_LSQ_MEMIF = CONF_ENABLE_LSQ_MEMIF;
`endif

`ifdef VERILATOR_ENABLE_TLB
    localparam bit LOCAL_ENABLE_TLB = 1'b1;
`else
    localparam bit LOCAL_ENABLE_TLB = CONF_ENABLE_TLB;
`endif

    // Static assertion: TLB requires LSQ memory interface
`ifndef SYNTHESIS
    initial if (LOCAL_ENABLE_TLB && !LOCAL_ENABLE_LSQ_MEMIF)
        $fatal(1, "CONF_ENABLE_TLB requires CONF_ENABLE_LSQ_MEMIF");
`endif

    // Page walker tie-offs when TLB gate OFF (unconditional — generate blocks override when ON)
    generate if (!LOCAL_ENABLE_TLB) begin : gen_no_tlb_tieoff
        assign pt_addr  = 32'd0;
        assign pt_wdata = 32'd0;
        assign pt_req   = 1'b0;
        assign pt_wr    = 1'b0;
    end endgenerate

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
    logic [CONF_GHR_WIDTH-1:0] bp_ghr_snapshot;

    // --- Decode raw outputs (directly from decoder) ---
    ooo_instr_t  raw_dec_instr_u, raw_dec_instr_v;
    logic        raw_dec_instr_u_valid, raw_dec_instr_v_valid;
    logic        raw_dec_branch_target_u_valid, raw_dec_branch_target_v_valid;
    logic [31:0] raw_dec_branch_target_u, raw_dec_branch_target_v;
    logic        raw_dec_branch_indirect_u, raw_dec_branch_indirect_v;
    logic        raw_dec_u_reads_flags, raw_dec_u_writes_flags;
    logic        raw_dec_v_reads_flags, raw_dec_v_writes_flags;
    logic [2:0]  raw_dec_u_addr_base, raw_dec_u_addr_index;
    logic        raw_dec_u_addr_base_valid, raw_dec_u_addr_index_valid;
    logic [1:0]  raw_dec_u_addr_scale;
    logic [2:0]  raw_dec_v_addr_base, raw_dec_v_addr_index;
    logic        raw_dec_v_addr_base_valid, raw_dec_v_addr_index_valid;
    logic [1:0]  raw_dec_v_addr_scale;
    logic [1:0]  raw_dec_u_mem_size, raw_dec_v_mem_size;
    logic [15:0] raw_dec_far_selector_u;

    // --- Decode muxed outputs (cache hit or raw, driven by generate block) ---
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
    logic [1:0]  dec_u_mem_size, dec_v_mem_size;

    // --- Rename ---
    logic        rename_ready;
    logic        rename_v_alloc_valid;
    phys_reg_t   rename_phys_u, rename_phys_v;
    phys_reg_t   src_phys_a, src_phys_b, src_phys_c, src_phys_d;
    logic        src_busy_a, src_busy_b, src_busy_c, src_busy_d;
    phys_reg_t   rename_old_phys_u, rename_old_phys_v;
    phys_reg_t   rename_com_map [CONF_ARCH_REG_NUM];

    // --- ROB head pointer (for microcode drain) ---
    rob_id_t     rob_head_ptr;

    // --- PRF read data ---
    logic [31:0] prf_data_a, prf_data_b, prf_data_c, prf_data_d;

    // --- ROB old_phys retirement ---
    phys_reg_t   rob_retire_u_old_phys, rob_retire_v_old_phys;

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

    // --- Execute Stage → CDB (raw from exec, muxed in gen_lsq_memif) ---
    logic        raw_cdb0_valid, raw_cdb1_valid;
    rob_id_t     raw_cdb0_tag, raw_cdb1_tag;
    logic [31:0] raw_cdb0_data, raw_cdb1_data;
    logic [5:0]  raw_cdb0_flags, raw_cdb1_flags;
    logic [5:0]  raw_cdb0_flags_mask, raw_cdb1_flags_mask;
    logic        raw_cdb0_exception, raw_cdb1_exception;
    phys_reg_t   raw_cdb0_phys_dest, raw_cdb1_phys_dest;
    logic        raw_cdb0_dest_valid, raw_cdb1_dest_valid;

    // --- CDB (muxed: generate block selects raw or LSQ) ---
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
    br_tag_t     branch_br_tag;

    // --- Execute Stage → Microcode ---
    logic        microcode_req;
    logic [7:0]  microcode_opcode;

    // --- P3: Microcode muxed signals (driven by gen_microcode or passthrough) ---
    logic        eff_iq_exec_ready;       // IQ exec_ready (gated during UC_ACTIVE)
    logic        eff_exec_u_valid;        // Execute u_valid (sequencer or IQ)
    instr_info_t eff_exec_u_instr;        // Execute u_instr (sequencer or IQ)
    logic [31:0] eff_u_op_a, eff_u_op_b;  // Execute operands
    phys_reg_t   eff_prf_rd_addr_a;       // PRF read port A
    phys_reg_t   eff_prf_rd_addr_b;       // PRF read port B
    logic        eff_rob_cdb0_valid;      // ROB CDB0 valid (suppress intermediate micro-ops)
    rob_id_t     eff_rob_cdb0_tag;        // ROB CDB0 tag (macro_rob_tag for synthetic)
    logic        ucode_block_interrupt;   // Block interrupts during atomic sequences

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
    logic [CONF_GHR_WIDTH-1:0] ftq_lookup_ghr;
    ftq_idx_t    branch_ftq_idx;

    // Side-table: ROB tag -> FTQ index for prediction repair/training
    ftq_idx_t    rob_ftq_idx_tbl [0:CONF_ROB_ENTRIES-1];

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
`ifdef VERILATOR
    assign flush = branch_mispredict || ucode_redirect_valid || cr0_write_flush || cr3_write_flush || cr4_write_flush || test_force_flush;
`else
    assign flush = branch_mispredict || ucode_redirect_valid || cr0_write_flush || cr3_write_flush || cr4_write_flush;
`endif

    // Mode-only flush for decode cache (excludes branch_mispredict)
    wire mode_flush = cr0_write_flush || cr3_write_flush || cr4_write_flush || ucode_redirect_valid;

    // --- LSQ Dispatch Backpressure (driven by gen_lsq_memif, 0 when gate OFF) ---
    logic lsq_dispatch_blocked;

    // --- LSQ CDB1 active (gates V-pipe dispatch to prevent CDB1 collision) ---
    logic lsq_cdb1_active;

    // --- LSQ load issue stall (gates IQ exec_ready to prevent load dequeue when LD_WAIT busy) ---
    logic lsq_load_issue_stall;

    // --- DTLB fault signals (driven by gen_dtlb or gen_no_dtlb, read by sys_regs CR2) ---
    logic        dtlb_fault;
    logic [31:0] dtlb_fault_addr;

    // --- LSQ ↔ ROB wiring (driven by gen_lsq_memif, stubbed when gate OFF) ---
    lq_idx_t  rob_dispatch_u_lq_idx;
    sq_idx_t  rob_dispatch_u_sq_idx;
    sq_idx_t  rob_retire_u_sq_idx_w;
    logic     rob_retire_u_is_store_w;

    // --- P3: Microcode active (driven by gen_microcode, 0 when gate OFF) ---
    logic ucode_active;

    // --- P3.1b: Microcode memory engine bridge (gen_microcode ↔ gen_lsq_memif) ---
    // From gen_microcode → gen_lsq_memif
    logic        uc_mem_ld_fire;           // Load AGU fire
    logic        uc_mem_st_fire;           // Store AGU fire
    logic [31:0] uc_mem_addr;             // Memory address
    lq_idx_t     uc_mem_lq_idx;           // Load queue index
    sq_idx_t     uc_mem_sq_idx;           // Store queue index
    logic [31:0] uc_mem_st_data;          // Store data
    logic [1:0]  uc_mem_size;             // Memory size (2=dword)
    logic [3:0]  uc_mem_byte_en;          // Byte enables
    logic        uc_mem_ld_dispatch;       // LQ sideband dispatch
    logic        uc_mem_st_dispatch;       // SQ sideband dispatch
    rob_id_t     uc_mem_dispatch_rob_tag;  // Dispatch ROB tag
    logic        uc_mem_retire_st;         // SQ sideband commitment
    sq_idx_t     uc_mem_retire_sq_idx;     // SQ commitment index
    logic        uc_mem_load_waiting;      // In UM_LOAD_WAIT (for CDB1 override)
    phys_reg_t   uc_mem_cdb1_phys_dest;    // CDB1 dest for microcode loads
    logic        uc_mem_esp_cdb0_fire;     // ESP update CDB0
    logic [31:0] uc_mem_esp_cdb0_data;     // ESP new value
    phys_reg_t   uc_mem_esp_phys_dest;     // ESP physical register
    // Microcode register-only CDB0 synthesis (LOAD_CR / STORE_CR)
    logic        uc_regonly_cdb0_fire;
    logic [31:0] uc_regonly_cdb0_data;
    phys_reg_t   uc_regonly_phys_dest;
    logic        uc_regonly_dest_valid;
    // Microcode special command bridge (gen_microcode → gen_lsq_memif)
    logic [7:0]  uc_mem_special_cmd;         // Current UM FSM special command
    // Microcode CR write port
    cr_idx_t     ucode_cr_idx;
    logic [31:0] ucode_cr_din;
    logic        ucode_cr_we;
    // Microcode DTR write port (LGDT/LIDT)
    logic        ucode_dtr_we;
    dtr_idx_t    ucode_dtr_idx;
    logic [31:0] ucode_dtr_base_din;
    logic [15:0] ucode_dtr_limit_din;
    // Macro EA bridge: AGU EA from gen_lsq_memif → gen_microcode
    logic [31:0] uc_macro_ea;
    // Segment cache write port (driven by gen_microcode, used by seg_cache)
    logic        ucode_seg_we;
    seg_idx_t    ucode_seg_idx;
    logic [15:0] ucode_seg_sel;
    logic [63:0] ucode_seg_cache;
    // PC redirect from microcode (far JMP)
    logic        ucode_redirect_valid;
    logic [31:0] ucode_redirect_pc;
    // CR write flush redirect: next fetch block after microcode instruction
    logic [31:0] ucode_cr_flush_next_pc;
    // From gen_lsq_memif → gen_microcode
    lq_idx_t     uc_lsq_ld_alloc_idx;     // Allocated LQ index
    sq_idx_t     uc_lsq_st_alloc_idx;     // Allocated SQ index
    logic        uc_lsq_lq_full;          // LQ full
    logic        uc_lsq_sq_full;          // SQ full

    // --- Dispatch Valid (derived signals used across sections) ---
    // V-pipe suppressed when U-pipe is OP_MICROCODE or OP_SYS_CALL:
    // execute stage gates V-pipe on u_ready, which is 0 for these ops,
    // so the V-pipe instruction would dispatch but never get CDB writeback.
    logic dispatch_u_valid, dispatch_v_valid;
    wire u_stalls_vpipe = dec_instr_u_valid &&
                          (dec_instr_u.op_cat == OP_MICROCODE ||
                           dec_instr_u.op_cat == OP_SYS_CALL);
    assign dispatch_u_valid = dec_instr_u_valid && rename_ready && !rob_full && !lsq_dispatch_blocked
                              && !ucode_active;
    assign dispatch_v_valid = dec_instr_v_valid && rename_ready && !rob_full && rename_v_alloc_valid
                              && !lsq_cdb1_active && !ucode_active && !u_stalls_vpipe;

    // Track FTQ index alongside each dispatched ROB entry so branch resolution
    // can recover prediction-time metadata (e.g. GHR snapshot).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < CONF_ROB_ENTRIES; i++)
                rob_ftq_idx_tbl[i] <= '0;
        end else if (flush) begin
            for (int i = 0; i < CONF_ROB_ENTRIES; i++)
                rob_ftq_idx_tbl[i] <= '0;
        end else begin
            if (dispatch_u_valid) rob_ftq_idx_tbl[rob_tag_u] <= ftq_deq_idx;
            if (dispatch_v_valid) rob_ftq_idx_tbl[rob_tag_v] <= ftq_deq_idx;
        end
    end

    always_comb begin
        branch_ftq_idx = '0;
        if (branch_resolved) branch_ftq_idx = rob_ftq_idx_tbl[branch_rob_tag];
    end

    // =================================================================
    // 1. Program Counter
    // =================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc_current <= 32'h0000_FFF0;  // x86 reset vector (high)
        else if (flush)
            pc_current <= ucode_redirect_valid ? ucode_redirect_pc :
                         (cr0_write_flush || cr3_write_flush || cr4_write_flush) ? ucode_cr_flush_next_pc :
                         branch_target;
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
        .res_pc             (iq_issue_instr.pc),
        .res_actually_taken (branch_taken),
        .res_is_mispredict  (branch_mispredict),
        .res_ghr_snap       (ftq_lookup_ghr),
        .ghr_snapshot       (bp_ghr_snapshot)
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

        .instr_u           (raw_dec_instr_u),
        .instr_u_valid     (raw_dec_instr_u_valid),
        .instr_v           (raw_dec_instr_v),
        .instr_v_valid     (raw_dec_instr_v_valid),
        .rename_ready      (rename_ready && !rob_full && !ucode_active),

        .branch_target_u       (raw_dec_branch_target_u),
        .branch_target_u_valid (raw_dec_branch_target_u_valid),
        .branch_indirect_u     (raw_dec_branch_indirect_u),
        .branch_target_v       (raw_dec_branch_target_v),
        .branch_target_v_valid (raw_dec_branch_target_v_valid),
        .branch_indirect_v     (raw_dec_branch_indirect_v),

        .u_reads_flags     (raw_dec_u_reads_flags),
        .u_writes_flags    (raw_dec_u_writes_flags),
        .v_reads_flags     (raw_dec_v_reads_flags),
        .v_writes_flags    (raw_dec_v_writes_flags),

        .u_addr_base       (raw_dec_u_addr_base),
        .u_addr_base_valid (raw_dec_u_addr_base_valid),
        .u_addr_index      (raw_dec_u_addr_index),
        .u_addr_index_valid(raw_dec_u_addr_index_valid),
        .u_addr_scale      (raw_dec_u_addr_scale),
        .v_addr_base       (raw_dec_v_addr_base),
        .v_addr_base_valid (raw_dec_v_addr_base_valid),
        .v_addr_index      (raw_dec_v_addr_index),
        .v_addr_index_valid(raw_dec_v_addr_index_valid),
        .v_addr_scale      (raw_dec_v_addr_scale),

        .u_mem_size        (raw_dec_u_mem_size),
        .v_mem_size        (raw_dec_v_mem_size),

        .u_far_selector    (raw_dec_far_selector_u),

        .pe_mode           (pe_mode),
        .v86_mode          (v86_mode),
        .default_32        (default_32)
    );

    // =================================================================
    // 3b. Decode Cache (Phase 1)
    // =================================================================
    // When enabled, stores decoded U+V pipe pairs in M10K BRAM indexed by
    // PC + CPU mode. Lookup runs in parallel with decode (same latency).
    // On hit, mux selects cached data; on miss, fills from decoder output.

    // Decode output accepted — decoder asserts valid only when s1_valid && rename_ready
    wire decode_accepted = raw_dec_instr_u_valid && !flush;

    generate if (CONF_ENABLE_DECODE_CACHE) begin : gen_dec_cache

        // Pack decode outputs into dc_pipe_entry_t for fill
        dc_pipe_entry_t dc_fill_u, dc_fill_v;
        always_comb begin
            dc_fill_u = '{
                valid:              raw_dec_instr_u.valid,
                pc:                 raw_dec_instr_u.pc,
                raw_instr:          raw_dec_instr_u.raw_instr,
                opcode:             raw_dec_instr_u.opcode,
                op_cat:             raw_dec_instr_u.op_cat,
                arch_dest:          raw_dec_instr_u.p_dest[2:0],
                dest_valid:         raw_dec_instr_u.dest_valid,
                arch_src_a:         raw_dec_instr_u.p_src_a[2:0],
                arch_src_b:         raw_dec_instr_u.p_src_b[2:0],
                src_a_not_needed:   raw_dec_instr_u.src_a_ready,
                src_b_not_needed:   raw_dec_instr_u.src_b_ready,
                imm_value:          raw_dec_instr_u.imm_value,
                branch_target:      raw_dec_branch_target_u,
                branch_target_valid:raw_dec_branch_target_u_valid,
                branch_indirect:    raw_dec_branch_indirect_u,
                reads_flags:        raw_dec_u_reads_flags,
                writes_flags:       raw_dec_u_writes_flags,
                addr_base:          raw_dec_u_addr_base,
                addr_base_valid:    raw_dec_u_addr_base_valid,
                addr_index:         raw_dec_u_addr_index,
                addr_index_valid:   raw_dec_u_addr_index_valid,
                addr_scale:         raw_dec_u_addr_scale
            };
            dc_fill_v = '{
                valid:              raw_dec_instr_v.valid,
                pc:                 raw_dec_instr_v.pc,
                raw_instr:          raw_dec_instr_v.raw_instr,
                opcode:             raw_dec_instr_v.opcode,
                op_cat:             raw_dec_instr_v.op_cat,
                arch_dest:          raw_dec_instr_v.p_dest[2:0],
                dest_valid:         raw_dec_instr_v.dest_valid,
                arch_src_a:         raw_dec_instr_v.p_src_a[2:0],
                arch_src_b:         raw_dec_instr_v.p_src_b[2:0],
                src_a_not_needed:   raw_dec_instr_v.src_a_ready,
                src_b_not_needed:   raw_dec_instr_v.src_b_ready,
                imm_value:          raw_dec_instr_v.imm_value,
                branch_target:      raw_dec_branch_target_v,
                branch_target_valid:raw_dec_branch_target_v_valid,
                branch_indirect:    raw_dec_branch_indirect_v,
                reads_flags:        raw_dec_v_reads_flags,
                writes_flags:       raw_dec_v_writes_flags,
                addr_base:          raw_dec_v_addr_base,
                addr_base_valid:    raw_dec_v_addr_base_valid,
                addr_index:         raw_dec_v_addr_index,
                addr_index_valid:   raw_dec_v_addr_index_valid,
                addr_scale:         raw_dec_v_addr_scale
            };
        end

        // Cache instance
        logic dc_hit;
        dc_pipe_entry_t dc_u_out, dc_v_out;

        f386_decode_cache u_dec_cache (
            .clk        (clk),
            .rst_n      (rst_n),
            .lookup_pc  (pc_current),
            .lookup_valid(fetch_ack),
            .pe_mode    (pe_mode),
            .v86_mode   (v86_mode),
            .default_32 (default_32),
            .hit        (dc_hit),
            .hit_u      (dc_u_out),
            .hit_v      (dc_v_out),
            .fill_valid (decode_accepted && !dc_hit),
            .fill_pc    (raw_dec_instr_u.pc),
            .fill_mode  ({pe_mode, v86_mode, default_32}),
            .fill_u     (dc_fill_u),
            .fill_v     (dc_fill_v),
            .inv_all    (mode_flush),
            .perf_hits  (),
            .perf_misses()
        );

        // Rebuild full ooo_instr_t from cache entry (zero-fill dispatch fields)
        function automatic ooo_instr_t rebuild(dc_pipe_entry_t e);
            rebuild.valid       = e.valid;
            rebuild.pc          = e.pc;
            rebuild.raw_instr   = e.raw_instr;
            rebuild.opcode      = e.opcode;
            rebuild.op_cat      = e.op_cat;
            rebuild.p_dest      = {2'b0, e.arch_dest};
            rebuild.dest_valid  = e.dest_valid;
            rebuild.p_src_a     = {2'b0, e.arch_src_a};
            rebuild.p_src_b     = {2'b0, e.arch_src_b};
            rebuild.src_a_ready = e.src_a_not_needed;
            rebuild.src_b_ready = e.src_b_not_needed;
            rebuild.val_a       = 32'h0;
            rebuild.val_b       = 32'h0;
            rebuild.rob_tag     = '0;
            rebuild.br_tag      = '0;
            rebuild.imm_value   = e.imm_value;
            rebuild.lq_idx      = '0;
            rebuild.sq_idx      = '0;
            rebuild.addr_base_valid  = e.addr_base_valid;
            rebuild.addr_index_valid = e.addr_index_valid;
            rebuild.addr_scale  = e.addr_scale;
            rebuild.mem_size    = 2'd2; // Default dword; re-derived from decode on miss
            // P3: microcode fields (not cached — OP_MICROCODE never hits decode cache)
            rebuild.is_0f       = 1'b0;
            rebuild.modrm_reg   = 3'd0;
            rebuild.is_rep      = 1'b0;
            rebuild.is_repne    = 1'b0;
            rebuild.is_32bit    = 1'b0;
        endfunction

        // Output mux: cache hit overrides decode
        wire use_cache = dc_hit && decode_accepted;

        assign dec_instr_u       = use_cache ? rebuild(dc_u_out) : raw_dec_instr_u;
        assign dec_instr_u_valid = use_cache ? dc_u_out.valid    : raw_dec_instr_u_valid;
        assign dec_instr_v       = use_cache ? rebuild(dc_v_out) : raw_dec_instr_v;
        assign dec_instr_v_valid = use_cache ? dc_v_out.valid    : raw_dec_instr_v_valid;

        assign dec_branch_target_u       = use_cache ? dc_u_out.branch_target       : raw_dec_branch_target_u;
        assign dec_branch_target_u_valid = use_cache ? dc_u_out.branch_target_valid : raw_dec_branch_target_u_valid;
        assign dec_branch_indirect_u     = use_cache ? dc_u_out.branch_indirect     : raw_dec_branch_indirect_u;
        assign dec_branch_target_v       = use_cache ? dc_v_out.branch_target       : raw_dec_branch_target_v;
        assign dec_branch_target_v_valid = use_cache ? dc_v_out.branch_target_valid : raw_dec_branch_target_v_valid;
        assign dec_branch_indirect_v     = use_cache ? dc_v_out.branch_indirect     : raw_dec_branch_indirect_v;

        assign dec_u_reads_flags      = use_cache ? dc_u_out.reads_flags      : raw_dec_u_reads_flags;
        assign dec_u_writes_flags     = use_cache ? dc_u_out.writes_flags     : raw_dec_u_writes_flags;
        assign dec_v_reads_flags      = use_cache ? dc_v_out.reads_flags      : raw_dec_v_reads_flags;
        assign dec_v_writes_flags     = use_cache ? dc_v_out.writes_flags     : raw_dec_v_writes_flags;

        assign dec_u_addr_base        = use_cache ? dc_u_out.addr_base        : raw_dec_u_addr_base;
        assign dec_u_addr_base_valid  = use_cache ? dc_u_out.addr_base_valid  : raw_dec_u_addr_base_valid;
        assign dec_u_addr_index       = use_cache ? dc_u_out.addr_index       : raw_dec_u_addr_index;
        assign dec_u_addr_index_valid = use_cache ? dc_u_out.addr_index_valid : raw_dec_u_addr_index_valid;
        assign dec_u_addr_scale       = use_cache ? dc_u_out.addr_scale       : raw_dec_u_addr_scale;
        assign dec_v_addr_base        = use_cache ? dc_v_out.addr_base        : raw_dec_v_addr_base;
        assign dec_v_addr_base_valid  = use_cache ? dc_v_out.addr_base_valid  : raw_dec_v_addr_base_valid;
        assign dec_v_addr_index       = use_cache ? dc_v_out.addr_index       : raw_dec_v_addr_index;
        assign dec_v_addr_index_valid = use_cache ? dc_v_out.addr_index_valid : raw_dec_v_addr_index_valid;
        assign dec_v_addr_scale       = use_cache ? dc_v_out.addr_scale       : raw_dec_v_addr_scale;

        // mem_size: not cached (derived from opcode+prefix each time)
        assign dec_u_mem_size         = raw_dec_u_mem_size;
        assign dec_v_mem_size         = raw_dec_v_mem_size;

    end else begin : gen_no_dec_cache

        // Passthrough when cache disabled
        assign dec_instr_u           = raw_dec_instr_u;
        assign dec_instr_u_valid     = raw_dec_instr_u_valid;
        assign dec_instr_v           = raw_dec_instr_v;
        assign dec_instr_v_valid     = raw_dec_instr_v_valid;

        assign dec_branch_target_u       = raw_dec_branch_target_u;
        assign dec_branch_target_u_valid = raw_dec_branch_target_u_valid;
        assign dec_branch_indirect_u     = raw_dec_branch_indirect_u;
        assign dec_branch_target_v       = raw_dec_branch_target_v;
        assign dec_branch_target_v_valid = raw_dec_branch_target_v_valid;
        assign dec_branch_indirect_v     = raw_dec_branch_indirect_v;

        assign dec_u_reads_flags     = raw_dec_u_reads_flags;
        assign dec_u_writes_flags    = raw_dec_u_writes_flags;
        assign dec_v_reads_flags     = raw_dec_v_reads_flags;
        assign dec_v_writes_flags    = raw_dec_v_writes_flags;

        assign dec_u_addr_base       = raw_dec_u_addr_base;
        assign dec_u_addr_base_valid = raw_dec_u_addr_base_valid;
        assign dec_u_addr_index      = raw_dec_u_addr_index;
        assign dec_u_addr_index_valid= raw_dec_u_addr_index_valid;
        assign dec_u_addr_scale      = raw_dec_u_addr_scale;
        assign dec_v_addr_base       = raw_dec_v_addr_base;
        assign dec_v_addr_base_valid = raw_dec_v_addr_base_valid;
        assign dec_v_addr_index      = raw_dec_v_addr_index;
        assign dec_v_addr_index_valid= raw_dec_v_addr_index_valid;
        assign dec_v_addr_scale      = raw_dec_v_addr_scale;

        assign dec_u_mem_size        = raw_dec_u_mem_size;
        assign dec_v_mem_size        = raw_dec_v_mem_size;

    end endgenerate

    // =================================================================
    // 4. Register Rename
    // =================================================================
    f386_register_rename renamer (
        .clk           (clk),
        .reset_n       (rst_n),

        .arch_dest_u   (dec_instr_u.p_dest[2:0]),
        .phys_dest_u   (rename_phys_u),
        .can_rename    (rename_ready),

        .dest_valid_u  (dec_instr_u.dest_valid && !ucode_dest_suppress),
        .dest_valid_v  (dec_instr_v.dest_valid),

        .arch_dest_v   (dec_instr_v.p_dest[2:0]),
        .phys_dest_v   (rename_phys_v),
        .v_alloc_valid (rename_v_alloc_valid),
        .rename_v_valid(dec_instr_v_valid && rename_ready && !rob_full),

        // U-pipe source lookup
        .src_arch_a    (dec_instr_u.p_src_a[2:0]),
        .src_arch_b    (dec_instr_u.p_src_b[2:0]),
        .src_phys_a    (src_phys_a),
        .src_phys_b    (src_phys_b),
        .src_busy_a    (src_busy_a),
        .src_busy_b    (src_busy_b),

        // V-pipe source lookup
        .src_arch_c    (dec_instr_v.p_src_a[2:0]),
        .src_arch_d    (dec_instr_v.p_src_b[2:0]),
        .src_phys_c    (src_phys_c),
        .src_phys_d    (src_phys_d),
        .src_busy_c    (src_busy_c),
        .src_busy_d    (src_busy_d),

        // Old physical mapping (for freelist reclaim)
        .old_phys_u    (rename_old_phys_u),
        .old_phys_v    (rename_old_phys_v),

        .retire_valid  (rob_retire_u_valid && rob_retire_u.instr.dest_valid),
        .retire_phys   (rob_retire_u.instr.p_dest),
        .retire_arch   (rob_retire_u.instr.p_dest[2:0]),
        .retire_old_phys(rob_retire_u_old_phys),

        .retire_v_valid  (rob_retire_v_valid && rob_retire_v.instr.dest_valid),
        .retire_v_arch   (rob_retire_v.instr.p_dest[2:0]),
        .retire_v_phys   (rob_retire_v.instr.p_dest),
        .retire_v_old_phys(rob_retire_v_old_phys),

        .branch_dispatch (dec_instr_u_valid && dec_instr_u.op_cat == OP_BRANCH &&
                           rename_ready && !rob_full),
        .branch_id       (specbits_alloc_tag),
        .branch_mispredict(branch_mispredict),
        .branch_restore_id(branch_br_tag),

        .cdb0_valid    (cdb0_wr_valid),    // Gate busy clear by dest_valid
        .cdb0_dest     (cdb0_phys_dest),
        .cdb1_valid    (cdb1_wr_valid),    // Gate busy clear by dest_valid
        .cdb1_dest     (cdb1_phys_dest),

        .flush         (flush),

        // Context pre-warm (unused until scheduler integration)
        .pre_warm_valid   (1'b0),
        .pre_warm_arch_reg(3'b000),
        .pre_warm_value   (32'd0),
        .pre_warm_ready   (),

        // P3: Committed map export (for microcode sequencer)
        .com_map_out      (rename_com_map)
    );

    // =================================================================
    // 4b. Patched Dispatch Instructions
    // =================================================================
    // Build fully-patched ooo_instr_t with rob_tag, physical regs,
    // source readiness, and PRF values before sending to IQ/ROB.
    ooo_instr_t patched_u, patched_v;

    // P3: Force dest_valid=0 for OP_MICROCODE — no rename allocation
    // Micro-ops write committed physical registers directly via CDB→PRF
    wire ucode_dest_suppress = (dec_instr_u.op_cat == OP_MICROCODE);

    always_comb begin
        patched_u             = dec_instr_u;
        patched_u.rob_tag     = rob_tag_u;
        patched_u.p_dest      = (dec_instr_u.dest_valid && !ucode_dest_suppress) ? rename_phys_u : '0;
        patched_u.dest_valid  = dec_instr_u.dest_valid && !ucode_dest_suppress;
        patched_u.br_tag      = (dec_instr_u.op_cat == OP_BRANCH) ? specbits_alloc_tag : '0;
        patched_u.p_src_a     = src_phys_a;
        patched_u.p_src_b     = src_phys_b;
        patched_u.src_a_ready = !src_busy_a;
        patched_u.src_b_ready = !src_busy_b;
        patched_u.val_a       = prf_data_a;
        patched_u.val_b       = prf_data_b;
        patched_u.addr_base_valid  = dec_u_addr_base_valid;
        patched_u.addr_index_valid = dec_u_addr_index_valid;
        patched_u.addr_scale  = dec_u_addr_scale;
        patched_u.mem_size    = dec_u_mem_size;
        patched_u.lq_idx      = rob_dispatch_u_lq_idx;
        patched_u.sq_idx      = rob_dispatch_u_sq_idx;

        patched_v             = dec_instr_v;
        patched_v.rob_tag     = rob_tag_v;
        patched_v.p_dest      = dec_instr_v.dest_valid ? rename_phys_v : '0;
        patched_v.dest_valid  = dec_instr_v.dest_valid;
        patched_v.br_tag      = '0;  // V-pipe does not dispatch branches
        patched_v.p_src_a     = src_phys_c;
        patched_v.p_src_b     = src_phys_d;
        patched_v.src_a_ready = !src_busy_c;
        patched_v.src_b_ready = !src_busy_d;
        patched_v.val_a       = prf_data_c;
        patched_v.val_b       = prf_data_d;
        patched_v.addr_base_valid  = dec_v_addr_base_valid;
        patched_v.addr_index_valid = dec_v_addr_index_valid;
        patched_v.addr_scale  = dec_v_addr_scale;
        patched_v.mem_size    = dec_v_mem_size;
    end

    // =================================================================
    // 4c. Physical Register File
    // =================================================================
    // CDB phys_dest/dest_valid assigned by gen_lsq_memif (muxed) or gen_no_lsq_memif (passthrough)
    phys_reg_t cdb0_phys_dest, cdb1_phys_dest;
    logic      cdb0_dest_valid, cdb1_dest_valid;

    // Gated CDB valid: suppress all destination side effects for no-dest ops.
    // ROB keeps raw cdb_valid (CMP/TEST/branches still need ROB completion).
    logic      cdb0_wr_valid, cdb1_wr_valid;
    assign cdb0_wr_valid = cdb0_valid && cdb0_dest_valid;
    assign cdb1_wr_valid = cdb1_valid && cdb1_dest_valid;

    f386_phys_regfile prf (
        .clk       (clk),
        .rst_n     (rst_n),
        .rd_addr_a (eff_prf_rd_addr_a),
        .rd_addr_b (eff_prf_rd_addr_b),
        .rd_addr_c (src_phys_c),
        .rd_addr_d (src_phys_d),
        .rd_data_a (prf_data_a),
        .rd_data_b (prf_data_b),
        .rd_data_c (prf_data_c),
        .rd_data_d (prf_data_d),
        .wr_en_0   (cdb0_wr_valid),
        .wr_addr_0 (cdb0_phys_dest),
        .wr_data_0 (cdb0_data),
        .wr_en_1   (cdb1_wr_valid),
        .wr_addr_1 (cdb1_phys_dest),
        .wr_data_1 (cdb1_data)
    );

    // =================================================================
    // 5. Issue Queue (Reservation Station)
    // =================================================================
    f386_issue_queue iq (
        .clk             (clk),
        .reset_n         (rst_n),

        .dispatch_instr  (patched_u),
        .dispatch_valid  (dispatch_u_valid),

        .issue_instr     (iq_issue_instr),
        .issue_valid     (iq_issue_valid),
        .exec_ready      (eff_iq_exec_ready),

        // CDB (for wakeup and operand capture)
        .cdb0_valid      (cdb0_wr_valid),    // Gate wakeup by dest_valid
        .cdb0_tag        (cdb0_tag),
        .cdb0_data       (cdb0_data),
        .cdb0_dest       (cdb0_phys_dest),
        .cdb1_valid      (cdb1_wr_valid),    // Gate wakeup by dest_valid
        .cdb1_tag        (cdb1_tag),
        .cdb1_data       (cdb1_data),
        .cdb1_dest       (cdb1_phys_dest),

        // Flush
        .flush           (flush),

        // Microcode: skip OP_MICROCODE unless at ROB head and sequencer idle
        .ucode_active    (ucode_active),
        .rob_head        (rob_head_ptr)
    );

    // =================================================================
    // 6. Reorder Buffer
    // =================================================================
    f386_rob rob (
        .clk               (clk),
        .rst_n             (rst_n),

        // Dispatch (patched instructions with physical reg mappings)
        .dispatch_u        (patched_u),
        .dispatch_u_valid  (dispatch_u_valid),
        .dispatch_v        (patched_v),
        .dispatch_v_valid  (dispatch_v_valid),
        .rob_tag_u         (rob_tag_u),
        .rob_tag_v         (rob_tag_v),
        .full              (rob_full),

        // CDB writeback from execute (ROB CDB0 gated for microcode intermediate ops)
        .cdb0_valid        (eff_rob_cdb0_valid),
        .cdb0_tag          (eff_rob_cdb0_tag),
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

        // Old physical register (for freelist reclaim at retirement)
        .dispatch_u_old_phys (rename_old_phys_u),
        .dispatch_v_old_phys (rename_old_phys_v),
        .retire_u_old_phys   (rob_retire_u_old_phys),
        .retire_v_old_phys   (rob_retire_v_old_phys),

        // LSQ index pairing (driven by gen_lsq_memif, stubbed to '0 when gate OFF)
        .dispatch_u_lq_idx (rob_dispatch_u_lq_idx),
        .dispatch_u_sq_idx (rob_dispatch_u_sq_idx),
        .dispatch_v_lq_idx ('0),
        .dispatch_v_sq_idx ('0),
        .retire_u_sq_idx   (rob_retire_u_sq_idx_w),
        .retire_u_is_store (rob_retire_u_is_store_w),
        .retire_v_sq_idx   (),
        .retire_v_is_store (),

        // SpecBits (Phase P1)
        .dispatch_u_specbits     (specbits_cur),
        .dispatch_v_specbits     (specbits_cur),
        .dispatch_u_ftq_idx      (ftq_deq_idx),
        .dispatch_v_ftq_idx      (ftq_deq_idx),
        .specbits_resolve_valid  (branch_resolved && !branch_mispredict),
        .specbits_resolve_tag    (branch_br_tag),
        .specbits_squash_valid   (branch_mispredict),
        .specbits_squash_mask    (specbits_squash_mask),

        // Flush
        .flush             (flush),

        // P3: Head pointer export (for microcode drain)
        .rob_head_out      (rob_head_ptr)
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
        .resolve_tag      (branch_br_tag),

        // Squash (misprediction → kill tagged instructions)
        .squash_valid     (branch_mispredict),
        .squash_tag       (branch_br_tag),
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
        .enq_ghr          (bp_ghr_snapshot),
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
        .redirect_ftq_idx (branch_ftq_idx),
        .redirect_repair_pc (ftq_redirect_repair_pc),
        .redirect_repair_ghr(ftq_redirect_repair_ghr),

        // ROB PC lookup
        .lookup_idx       (branch_ftq_idx),
        .lookup_pc        (),      // Available for exception PC reporting
        .lookup_ghr       (ftq_lookup_ghr)
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
        exec_u_instr.br_tag      = iq_issue_instr.br_tag;
        exec_u_instr.dest_valid  = iq_issue_instr.dest_valid;
        exec_u_instr.phys_dest   = iq_issue_instr.p_dest;
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
        exec_v_instr.is_valid    = dispatch_v_valid;
        exec_v_instr.pc          = patched_v.pc;
        exec_v_instr.opcode      = patched_v.opcode;
        exec_v_instr.op_category = patched_v.op_cat;
        exec_v_instr.reg_dest    = patched_v.p_dest[2:0];
        exec_v_instr.reg_src_a   = patched_v.p_src_a[2:0];
        exec_v_instr.reg_src_b   = patched_v.p_src_b[2:0];
        exec_v_instr.rob_tag     = rob_tag_v;
        exec_v_instr.br_tag      = '0;
        exec_v_instr.dest_valid  = patched_v.dest_valid;
        exec_v_instr.phys_dest   = patched_v.p_dest;
        exec_v_instr.imm_value   = patched_v.imm_value;
        exec_v_instr.flags_in    = alu_flags_current;
        exec_v_instr.flags_mask  = (patched_v.op_cat == OP_ALU_REG ||
                                    patched_v.op_cat == OP_ALU_IMM) ? 6'b111111 : 6'b000000;
        exec_v_instr.pred_taken  = 1'b0;
        exec_v_instr.pred_target = 32'd0;
        exec_v_instr.sem_tag     = SEM_NONE;
    end

    f386_execute_stage exec_stage (
        .clk             (clk),
        .reset_n         (rst_n),

        // U-pipe (muxed for microcode: eff_* signals from gen_microcode)
        .u_instr         (eff_exec_u_instr),
        .u_op_a          (eff_u_op_a),
        .u_op_b          (eff_u_op_b),
        .u_valid         (eff_exec_u_valid),
        .u_ready         (exec_u_ready),

        // V-pipe (operands from PRF via patched instruction)
        .v_instr         (exec_v_instr),
        .v_op_a          (patched_v.val_a),
        .v_op_b          (patched_v.val_b),
        .v_valid         (exec_v_instr.is_valid),
        .v_ready         (exec_v_ready),

        // CDB (raw outputs — muxed with LSQ CDB in gen_lsq_memif)
        .cdb0_valid      (raw_cdb0_valid),
        .cdb0_tag        (raw_cdb0_tag),
        .cdb0_data       (raw_cdb0_data),
        .cdb0_flags      (raw_cdb0_flags),
        .cdb0_flags_mask (raw_cdb0_flags_mask),
        .cdb0_exception  (raw_cdb0_exception),
        .cdb0_phys_dest  (raw_cdb0_phys_dest),
        .cdb0_dest_valid (raw_cdb0_dest_valid),
        .cdb1_valid      (raw_cdb1_valid),
        .cdb1_tag        (raw_cdb1_tag),
        .cdb1_data       (raw_cdb1_data),
        .cdb1_flags      (raw_cdb1_flags),
        .cdb1_flags_mask (raw_cdb1_flags_mask),
        .cdb1_exception  (raw_cdb1_exception),
        .cdb1_phys_dest  (raw_cdb1_phys_dest),
        .cdb1_dest_valid (raw_cdb1_dest_valid),

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
        .branch_br_tag   (branch_br_tag),

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

    // --- Microcode EFLAGS write port (driven by gen_microcode / gen_no_microcode) ---
    logic [31:0] ucode_eflags_din;
    logic [31:0] ucode_eflags_mask;
    logic        ucode_eflags_we;

    f386_sys_regs sys_regs (
        .clk             (clk),
        .rst_n           (rst_n),

        // CR write port (driven by microcode STORE_CR)
        .cr_idx          (ucode_cr_idx),
        .cr_din          (ucode_cr_din),
        .cr_we           (ucode_cr_we),

        // Page fault CR2 (undriven until MMU)
        .pf_cr2_din      (dtlb_fault_addr),
        .pf_cr2_we       (dtlb_fault),

        // EFLAGS write port (microcode special commands)
        .eflags_din      (ucode_eflags_din),
        .eflags_mask     (ucode_eflags_mask),
        .eflags_we       (ucode_eflags_we),

        // ALU flags from ROB retirement (BOOM/RSD pattern: flags travel through ROB)
        .alu_flags_in    (merged_retire_flags),
        .alu_flags_mask  (merged_retire_flags_mask),
        .alu_flags_we    (retire_u_writes_flags || retire_v_writes_flags),

        // DTR write port (driven by microcode LGDT/LIDT)
        .dtr_idx         (ucode_dtr_idx),
        .dtr_base_din    (ucode_dtr_base_din),
        .dtr_limit_din   (ucode_dtr_limit_din),
        .dtr_sel_din     (16'h0),            // Future (LLDT/LTR)
        .dtr_cache_din   (64'h0),            // Future (LLDT/LTR)
        .dtr_we          (ucode_dtr_we),

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

        // Write port (driven by microcode far JMP / segment load)
        .seg_idx             (ucode_seg_idx),
        .seg_sel_din         (ucode_seg_sel),
        .seg_cache_din       (ucode_seg_cache),
        .seg_cache_valid_din (1'b1),
        .seg_we              (ucode_seg_we),

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
        .push_valid       (dispatch_u_valid &&
                           dec_instr_u.op_cat == OP_BRANCH &&
                           dec_instr_u.opcode == 8'hE8),
        .push_ret_addr    (dec_instr_u.pc + {24'd0, dec_instr_u.raw_instr[7:0]} + 32'd1),

        // Pop on RET dispatch (opcode C3 = near RET)
        .pop_valid        (dispatch_u_valid &&
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
    // 14. Data Memory Interface — LSQ Integration (P2 Step 2a)
    // =================================================================
    // When LOCAL_ENABLE_LSQ_MEMIF is ON: full LSQ pipeline with AGU,
    // shim, CDB mux, dispatch backpressure, and retirement wiring.
    // When OFF: legacy stub (no behavioral change).

    generate if (LOCAL_ENABLE_LSQ_MEMIF) begin : gen_lsq_memif

        // ---------------------------------------------------------
        // Dispatch wiring: detect memory ops
        // ---------------------------------------------------------
        wire lsq_ld_dispatch_valid = dispatch_u_valid && (dec_instr_u.op_cat == OP_LOAD);
        wire lsq_st_dispatch_valid = dispatch_u_valid && (dec_instr_u.op_cat == OP_STORE);

        // LSQ capacity signals
        logic lsq_lq_full, lsq_sq_full;
        lq_idx_t lsq_ld_dispatch_idx;
        sq_idx_t lsq_st_dispatch_idx;

        // Export to module scope for microcode memory engine
        assign uc_lsq_lq_full = lsq_lq_full;
        assign uc_lsq_sq_full = lsq_sq_full;

        // ---------------------------------------------------------
        // Dispatch backpressure (Finding #7)
        // ---------------------------------------------------------
        wire mem_dispatch_blocked = (dec_instr_u.op_cat == OP_LOAD  && lsq_lq_full) ||
                                    (dec_instr_u.op_cat == OP_STORE && lsq_sq_full);
        assign lsq_dispatch_blocked  = mem_dispatch_blocked;
        // lsq_cdb1_active assigned below after IO path CDB signals are declared

        // Wire LSQ indices to ROB
        assign rob_dispatch_u_lq_idx = lsq_ld_dispatch_idx;
        assign rob_dispatch_u_sq_idx = lsq_st_dispatch_idx;

        // ---------------------------------------------------------
        // CDB suppression: OP_LOAD must not broadcast from exec cdb0
        // (LSQ handles load completion via cdb1)
        // ---------------------------------------------------------
        wire cdb0_suppress_load = (iq_issue_instr.op_cat == OP_LOAD);

        // cdb0: suppress OP_LOAD broadcast (LSQ delivers load data on cdb1)
        // OR in microcode CDB0 synthesis (ESP / regonly, mutually exclusive with exec CDB0)
        wire uc_synth_cdb0 = uc_mem_esp_cdb0_fire || uc_regonly_cdb0_fire;
        assign cdb0_valid      = (raw_cdb0_valid && !cdb0_suppress_load) || uc_synth_cdb0;
        assign cdb0_tag        = uc_synth_cdb0         ? uc_mem_dispatch_rob_tag : raw_cdb0_tag;
        assign cdb0_data       = uc_regonly_cdb0_fire  ? uc_regonly_cdb0_data    :
                                 uc_mem_esp_cdb0_fire   ? uc_mem_esp_cdb0_data    : raw_cdb0_data;
        assign cdb0_flags      = uc_synth_cdb0         ? 6'd0                    : raw_cdb0_flags;
        assign cdb0_flags_mask = uc_synth_cdb0         ? 6'd0                    : raw_cdb0_flags_mask;
        assign cdb0_exception  = uc_synth_cdb0         ? 1'b0                    : raw_cdb0_exception;
        assign cdb0_phys_dest  = uc_regonly_cdb0_fire  ? uc_regonly_phys_dest    :
                                 uc_mem_esp_cdb0_fire   ? uc_mem_esp_phys_dest    : raw_cdb0_phys_dest;
        assign cdb0_dest_valid = uc_regonly_cdb0_fire  ? uc_regonly_dest_valid   :
                                 uc_mem_esp_cdb0_fire   ? 1'b1                    : raw_cdb0_dest_valid;

        // ---------------------------------------------------------
        // LSQ CDB load result
        // ---------------------------------------------------------
        logic        lsq_ld_cdb_valid;
        rob_id_t     lsq_ld_cdb_tag;
        logic [31:0] lsq_ld_cdb_data;
        logic        lsq_ld_cdb_fault;

        // ---------------------------------------------------------
        // IO path CDB load result (MMIO loads)
        // ---------------------------------------------------------
        logic        io_ld_cdb_valid;
        rob_id_t     io_ld_cdb_tag;
        logic [31:0] io_ld_cdb_data;
        lq_idx_t     io_ld_cdb_lq_idx;
        logic        io_ld_cdb_fault;

        // Combined CDB1 active flag (gates V-pipe exec CDB)
        assign lsq_cdb1_active = lsq_ld_cdb_valid || io_ld_cdb_valid;

        // ---------------------------------------------------------
        // phys_dest side table (Finding #2)
        // Maps ROB tag → phys_dest for LSQ CDB writeback to PRF
        // ---------------------------------------------------------
        phys_reg_t rob_phys_dest_tbl  [0:CONF_ROB_ENTRIES-1];
        logic      rob_dest_valid_tbl [0:CONF_ROB_ENTRIES-1];

        always_ff @(posedge clk) begin
            if (dispatch_u_valid && !mem_dispatch_blocked) begin
                rob_phys_dest_tbl [rob_tag_u] <= patched_u.p_dest;
                rob_dest_valid_tbl[rob_tag_u] <= patched_u.dest_valid;
            end
            if (dispatch_v_valid) begin
                rob_phys_dest_tbl [rob_tag_v] <= patched_v.p_dest;
                rob_dest_valid_tbl[rob_tag_v] <= patched_v.dest_valid;
            end
            // Microcode load dispatch: override phys_dest for CDB1 writeback
            // POP_FLAGS: suppress PRF write (loaded value goes to EFLAGS, not GPR)
            if (uc_mem_ld_dispatch) begin
                rob_phys_dest_tbl [uc_mem_dispatch_rob_tag] <= uc_mem_cdb1_phys_dest;
                rob_dest_valid_tbl[uc_mem_dispatch_rob_tag] <=
                    (uc_mem_special_cmd != UCMD_POP_FLAGS) &&
                    (uc_mem_special_cmd != UCMD_LOAD_DTR) &&
                    (uc_mem_special_cmd != UCMD_FAR_CALL) &&
                    (uc_mem_special_cmd != UCMD_LOAD_SEG);
            end
        end

        // Microcode regonly CDB0 phys_dest (needs rob_phys_dest_tbl from this generate block)
        assign uc_regonly_phys_dest = rob_phys_dest_tbl[uc_mem_dispatch_rob_tag];

        // cdb1: IO path > LSQ > V-pipe execute priority
        wire any_ld_cdb = io_ld_cdb_valid || lsq_ld_cdb_valid;
        wire [3:0] ld_cdb_rob_tag = io_ld_cdb_valid ? io_ld_cdb_tag : lsq_ld_cdb_tag;
        wire [31:0] ld_cdb_result = io_ld_cdb_valid ? io_ld_cdb_data : lsq_ld_cdb_data;

        assign cdb1_valid      = any_ld_cdb        ? 1'b1                             : raw_cdb1_valid;
        assign cdb1_tag        = any_ld_cdb        ? ld_cdb_rob_tag                   : raw_cdb1_tag;
        assign cdb1_data       = any_ld_cdb        ? ld_cdb_result                    : raw_cdb1_data;
        assign cdb1_phys_dest  = any_ld_cdb        ? rob_phys_dest_tbl[ld_cdb_rob_tag]
                                                   : raw_cdb1_phys_dest;
        assign cdb1_dest_valid = any_ld_cdb        ? rob_dest_valid_tbl[ld_cdb_rob_tag]
                                                   : raw_cdb1_dest_valid;
        assign cdb1_flags      = any_ld_cdb        ? 6'd0                             : raw_cdb1_flags;
        assign cdb1_flags_mask = any_ld_cdb        ? 6'd0                             : raw_cdb1_flags_mask;
        assign cdb1_exception  = io_ld_cdb_valid   ? io_ld_cdb_fault                  :
                                 lsq_ld_cdb_valid  ? lsq_ld_cdb_fault                :
                                                     raw_cdb1_exception;

        // ---------------------------------------------------------
        // AGU (Finding #1): combinational effective address
        // ---------------------------------------------------------
        logic [31:0] computed_ea;

        // AGU index_valid: enabled for loads (val_b = index value).
        // Disabled for stores (val_b = store DATA, not index) — indexed
        // stores require 3 operands and must be decomposed by microcode.
        wire agu_index_en = iq_issue_instr.addr_index_valid &&
                            (iq_issue_instr.op_cat == OP_LOAD);

        // Indexed store guard: block agu_st_fire when addr_index_valid.
        // EA would be wrong (missing index*scale) since val_b carries
        // store data, not index. These instructions must go through
        // microcode decomposition. Stalling in the IQ is safe — they'll
        // block until microcode is wired (P3). Writing a wrong address
        // is not safe.
        wire indexed_store_block = iq_issue_instr.addr_index_valid &&
                                   (iq_issue_instr.op_cat == OP_STORE);

        // Misaligned cross-dword store guard: block agu_st_fire when
        // the store would cross a 32-bit dword boundary. Without
        // split-store support, these produce truncated byte_en masks
        // and silently partial-write. Stall in IQ until split-store
        // handling exists.
        // Cross-dword: word at ea[1:0]==3, dword at ea[1:0]!=0.
        // Uses computed_ea which is valid combinationally from AGU.

        f386_agu u_agu (
            .seg_base     (32'd0),            // Flat model (P2 simplification)
            .base_val     (iq_issue_instr.val_a),
            .base_valid   (iq_issue_instr.addr_base_valid),
            .index_val    (iq_issue_instr.val_b),
            .index_valid  (agu_index_en),
            .scale        (iq_issue_instr.addr_scale),
            .displacement (iq_issue_instr.imm_value),
            .linear_addr  (computed_ea),
            .a20_gate     (a20_gate)
        );

        // Bridge computed_ea to gen_microcode for macro EA latch
        assign uc_macro_ea = computed_ea;

        // Misaligned cross-dword store detection (uses computed_ea from AGU)
        wire misaligned_store_block = (iq_issue_instr.op_cat == OP_STORE) && (
            (iq_issue_instr.mem_size == 2'd1 && computed_ea[1:0] == 2'd3) ||  // word at offset 3
            (iq_issue_instr.mem_size == 2'd2 && computed_ea[1:0] != 2'd0)     // dword misaligned
        );

        // ---------------------------------------------------------
        // Byte-enable derivation from size + address alignment
        // ---------------------------------------------------------
        // ---------------------------------------------------------
        // Byte-enable for LOADS (LSQ CAM forwarding)
        // Cross-dword accesses get byte_en=0 to disable forwarding —
        // the 64-bit beat memory path handles them correctly, but the
        // 32-bit forwarding CAM cannot.
        // ---------------------------------------------------------
        function automatic logic [3:0] ld_byte_en(
            input logic [1:0] size, input logic [1:0] addr_lo
        );
            case ({size, addr_lo})
                4'b00_00: ld_byte_en = 4'b0001;
                4'b00_01: ld_byte_en = 4'b0010;
                4'b00_10: ld_byte_en = 4'b0100;
                4'b00_11: ld_byte_en = 4'b1000;
                4'b01_00: ld_byte_en = 4'b0011;
                4'b01_01: ld_byte_en = 4'b0110;
                4'b01_10: ld_byte_en = 4'b1100;
                4'b01_11: ld_byte_en = 4'b0000; // Cross-dword: disable forwarding
                4'b10_00: ld_byte_en = 4'b1111;
                4'b10_01: ld_byte_en = 4'b0000; // Misaligned dword: disable forwarding
                4'b10_10: ld_byte_en = 4'b0000;
                4'b10_11: ld_byte_en = 4'b0000;
                default:  ld_byte_en = 4'b0000;
            endcase
        endfunction

        // ---------------------------------------------------------
        // Byte-enable for STORES (actual lane mask for memory write)
        // Must never be zero — LSQ store_drain_checks assert this.
        // Cross-dword stores produce truncated masks here; the
        // store_drain_checks assertion catches them as errors.
        // ---------------------------------------------------------
        function automatic logic [3:0] st_byte_en(
            input logic [1:0] size, input logic [1:0] addr_lo
        );
            case ({size, addr_lo})
                4'b00_00: st_byte_en = 4'b0001;
                4'b00_01: st_byte_en = 4'b0010;
                4'b00_10: st_byte_en = 4'b0100;
                4'b00_11: st_byte_en = 4'b1000;
                4'b01_00: st_byte_en = 4'b0011;
                4'b01_01: st_byte_en = 4'b0110;
                4'b01_10: st_byte_en = 4'b1100;
                4'b01_11: st_byte_en = 4'b1000; // Cross-dword word: low byte in this dword (truncated)
                4'b10_00: st_byte_en = 4'b1111;
                4'b10_01: st_byte_en = 4'b1110; // Misaligned dword (truncated to this dword)
                4'b10_10: st_byte_en = 4'b1100;
                4'b10_11: st_byte_en = 4'b1000;
                default:  st_byte_en = 4'b1111;
            endcase
        endfunction

        // ---------------------------------------------------------
        // MMIO classification (after AGU)
        // ---------------------------------------------------------
        wire ea_is_mmio = is_mmio_addr(computed_ea);

        // IO path ready signal (forward-declared, driven by IO path instance)
        logic io_path_ld_ready;

        // LSQ store queue empty (for IO path TSO serialization)
        logic lsq_sq_empty;

        // ---------------------------------------------------------
        // Load in-flight tracker (Finding #4)
        // Prevents AGU from issuing a new load while LD_WAIT is busy.
        // Set on AGU load fire, cleared on LSQ or IO CDB completion.
        // ---------------------------------------------------------
        logic ld_in_flight;

        // ---------------------------------------------------------
        // Muxed fire/address/data signals (driven by gen_dtlb or gen_no_dtlb)
        // ---------------------------------------------------------
        logic        eff_ld_fire;       // Cacheable load fire
        logic        eff_ld_mmio_fire;  // MMIO load fire
        logic        eff_st_fire;       // Store fire
        logic [31:0] eff_ld_addr;       // Physical address for loads
        lq_idx_t     eff_ld_idx;
        logic [1:0]  eff_ld_size;
        logic [3:0]  eff_ld_byte_en;
        logic [31:0] eff_st_addr;       // Physical address for stores
        sq_idx_t     eff_st_idx;
        logic [31:0] eff_st_data;
        logic [1:0]  eff_st_size;
        logic [3:0]  eff_st_byte_en;
        logic [31:0] eff_io_addr;       // MMIO load address
        logic [1:0]  eff_io_size;
        rob_id_t     eff_io_rob_tag;
        lq_idx_t     eff_io_lq_idx;
        logic        eff_is_mmio;       // MMIO classification for routing

        // DTLB signals (driven by gen_dtlb, tied off by gen_no_dtlb)
        // dtlb_fault and dtlb_fault_addr are at module scope (for CR2 wiring)
        logic        dtlb_busy;
        logic        dtlb_resp_valid;
        logic [31:0] dtlb_paddr;
        logic [3:0]  dtlb_fault_code;

        // ---------------------------------------------------------
        // DTLB Integration (P3.TLB.a)
        // ---------------------------------------------------------
        if (LOCAL_ENABLE_TLB) begin : gen_dtlb

            // Translation context latch — captured on DTLB request acceptance,
            // consumed on resp_valid. Only one outstanding translation (IQ stalled).
            typedef struct packed {
                logic                         is_load;
                logic                         is_store;
                rob_id_t                      rob_tag;
                lq_idx_t                      lq_idx;
                sq_idx_t                      sq_idx;
                logic [1:0]                   mem_size;
                logic [31:0]                  store_data;
                logic [31:0]                  linear_addr;
                logic                         addr_index_valid;
            } xlat_ctx_t;

            xlat_ctx_t xlat_ctx;

            // DTLB request fires when IQ issues a memory op and DTLB is ready
            wire xlat_req_fire = iq_issue_valid && !dtlb_busy
                                 && (iq_issue_instr.op_cat inside {OP_LOAD, OP_STORE})
                                 && !indexed_store_block && !misaligned_store_block;

            // Hold DTLB response when MMIO load can't fire (IO path not ready)
            wire dtlb_resp_hold = dtlb_resp_valid && !dtlb_fault
                                  && xlat_ctx.is_load && xlat_is_mmio && !io_path_ld_ready;

            f386_dtlb_frontend u_dtlb (
                .clk              (clk),
                .rst_n            (rst_n),
                .flush            (flush),
                .req_valid        (xlat_req_fire),
                .req_addr_linear  (computed_ea),
                .req_write        (iq_issue_instr.op_cat == OP_STORE),
                .req_user         (sys_cpl == 2'b11 || v86_mode),
                .resp_valid       (dtlb_resp_valid),
                .resp_paddr       (dtlb_paddr),
                .resp_fault       (dtlb_fault),
                .resp_fault_addr  (dtlb_fault_addr),
                .resp_fault_code  (dtlb_fault_code),
                .busy             (dtlb_busy),
                .resp_hold        (dtlb_resp_hold),
                .paging_enabled   (sys_pg_mode),
                .flush_all        (cr3_write_flush),
                .invlpg_valid     (1'b0),               // deferred
                .invlpg_vaddr     (32'd0),
                .cr3              (sys_cr3),
                .pt_addr          (pt_addr),
                .pt_wdata         (pt_wdata),
                .pt_rdata         (pt_rdata),
                .pt_req           (pt_req),
                .pt_wr            (pt_wr),
                .pt_ack           (pt_ack)
            );

            // Latch context on DTLB request acceptance
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    xlat_ctx <= '0;
                else if (flush)
                    xlat_ctx <= '0;
                else if (xlat_req_fire) begin
                    xlat_ctx.is_load          <= (iq_issue_instr.op_cat == OP_LOAD);
                    xlat_ctx.is_store         <= (iq_issue_instr.op_cat == OP_STORE);
                    xlat_ctx.rob_tag          <= iq_issue_instr.rob_tag;
                    xlat_ctx.lq_idx           <= iq_issue_instr.lq_idx;
                    xlat_ctx.sq_idx           <= iq_issue_instr.sq_idx;
                    xlat_ctx.mem_size         <= iq_issue_instr.mem_size;
                    xlat_ctx.store_data       <= iq_issue_instr.val_b;
                    xlat_ctx.linear_addr      <= computed_ea;
                    xlat_ctx.addr_index_valid <= iq_issue_instr.addr_index_valid;
                end
            end

            // MMIO classification: route on linear address for first pass
            wire xlat_is_mmio = is_mmio_addr(xlat_ctx.linear_addr);

            // MMIO hazard assertions (sim-only)
            `ifndef SYNTHESIS
            always @(posedge clk) begin
                if (dtlb_resp_valid && sys_pg_mode) begin
                    if (is_mmio_addr(xlat_ctx.linear_addr) && dtlb_paddr != xlat_ctx.linear_addr)
                        $warning("MMIO linear address remapped by paging");
                    if (!is_mmio_addr(xlat_ctx.linear_addr) && is_mmio_addr(dtlb_paddr))
                        $warning("Non-MMIO linear address maps to physical MMIO range");
                end
            end
            `endif

            // Store fault policy: provisional
            `ifndef SYNTHESIS
            always @(posedge clk) begin
                if (dtlb_resp_valid && dtlb_fault && xlat_ctx.is_store)
                    $fatal(1, "Store page fault (provisional — not yet handled)");
            end
            `endif

            // Drive muxed fire signals from latched context + translation response
            assign eff_ld_fire      = dtlb_resp_valid && !dtlb_fault
                                      && xlat_ctx.is_load && !xlat_is_mmio;
            assign eff_ld_mmio_fire = dtlb_resp_valid && !dtlb_fault
                                      && xlat_ctx.is_load && xlat_is_mmio && io_path_ld_ready;
            assign eff_st_fire      = dtlb_resp_valid && !dtlb_fault
                                      && xlat_ctx.is_store;

            assign eff_ld_addr    = dtlb_paddr;
            assign eff_ld_idx     = xlat_ctx.lq_idx;
            assign eff_ld_size    = xlat_ctx.mem_size;
            assign eff_ld_byte_en = ld_byte_en(xlat_ctx.mem_size, dtlb_paddr[1:0]);
            assign eff_st_addr    = dtlb_paddr;
            assign eff_st_idx     = xlat_ctx.sq_idx;
            assign eff_st_data    = xlat_ctx.store_data;
            assign eff_st_size    = xlat_ctx.mem_size;
            assign eff_st_byte_en = st_byte_en(xlat_ctx.mem_size, dtlb_paddr[1:0]);
            assign eff_io_addr    = dtlb_paddr;
            assign eff_io_size    = xlat_ctx.mem_size;
            assign eff_io_rob_tag = xlat_ctx.rob_tag;
            assign eff_io_lq_idx  = xlat_ctx.lq_idx;
            assign eff_is_mmio    = xlat_is_mmio;

            // Load in-flight: set on DTLB request acceptance for loads
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    ld_in_flight <= 1'b0;
                else if (flush)
                    ld_in_flight <= 1'b0;
                else if (lsq_ld_cdb_valid || io_ld_cdb_valid)
                    ld_in_flight <= 1'b0;
                else if (xlat_req_fire && (iq_issue_instr.op_cat == OP_LOAD))
                    ld_in_flight <= 1'b1;
            end

            // IQ stall: translation busy, or load in-flight, or existing guards
            assign lsq_load_issue_stall =
                dtlb_busy ||
                ((iq_issue_instr.op_cat == OP_LOAD) && ld_in_flight) ||
                indexed_store_block || misaligned_store_block;

        end else begin : gen_no_dtlb

            // Passthrough: physical = linear, no latch needed
            assign dtlb_paddr      = computed_ea;
            assign dtlb_resp_valid = iq_issue_valid
                                     && (iq_issue_instr.op_cat inside {OP_LOAD, OP_STORE});
            assign dtlb_fault      = 1'b0;
            assign dtlb_fault_addr = 32'd0;
            assign dtlb_fault_code = 4'd0;
            assign dtlb_busy       = 1'b0;

            // Direct fire signals (existing behavior)
            assign eff_ld_fire      = iq_issue_valid && (iq_issue_instr.op_cat == OP_LOAD)
                                      && !ld_in_flight && !ea_is_mmio;
            assign eff_ld_mmio_fire = iq_issue_valid && (iq_issue_instr.op_cat == OP_LOAD)
                                      && !ld_in_flight && ea_is_mmio && io_path_ld_ready;
            assign eff_st_fire      = iq_issue_valid && (iq_issue_instr.op_cat == OP_STORE)
                                      && !indexed_store_block && !misaligned_store_block;

            assign eff_ld_addr    = computed_ea;
            assign eff_ld_idx     = iq_issue_instr.lq_idx;
            assign eff_ld_size    = iq_issue_instr.mem_size;
            assign eff_ld_byte_en = ld_byte_en(iq_issue_instr.mem_size, computed_ea[1:0]);
            assign eff_st_addr    = computed_ea;
            assign eff_st_idx     = iq_issue_instr.sq_idx;
            assign eff_st_data    = iq_issue_instr.val_b;
            assign eff_st_size    = iq_issue_instr.mem_size;
            assign eff_st_byte_en = st_byte_en(iq_issue_instr.mem_size, computed_ea[1:0]);
            assign eff_io_addr    = computed_ea;
            assign eff_io_size    = iq_issue_instr.mem_size;
            assign eff_io_rob_tag = iq_issue_instr.rob_tag;
            assign eff_io_lq_idx  = iq_issue_instr.lq_idx;
            assign eff_is_mmio    = ea_is_mmio;

            // Load in-flight (original logic)
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    ld_in_flight <= 1'b0;
                else if (flush)
                    ld_in_flight <= 1'b0;
                else if (lsq_ld_cdb_valid || io_ld_cdb_valid)
                    ld_in_flight <= 1'b0;
                else if (iq_issue_valid && (iq_issue_instr.op_cat == OP_LOAD) && !ld_in_flight
                         && (!ea_is_mmio || io_path_ld_ready))
                    ld_in_flight <= 1'b1;
            end

            // IQ stall (original logic)
            assign lsq_load_issue_stall =
                ((iq_issue_instr.op_cat == OP_LOAD) &&
                 (ld_in_flight || (ea_is_mmio && !io_path_ld_ready))) ||
                indexed_store_block || misaligned_store_block;

        end

        // ROB retirement signals come from top-level wires
        // (rob_retire_u_sq_idx_w, rob_retire_u_is_store_w)

        // ---------------------------------------------------------
        // Split-phase memory interface (LSQ ↔ arbiter client 0)
        // ---------------------------------------------------------
        logic       lsq_mem_req_valid, lsq_mem_req_ready;
        mem_req_t   lsq_mem_req_out;
        logic       lsq_mem_rsp_valid, lsq_mem_rsp_ready;
        mem_rsp_t   lsq_mem_rsp_in;

        // ---------------------------------------------------------
        // Split-phase memory interface (IO path ↔ arbiter client 1)
        // ---------------------------------------------------------
        logic       io_mem_req_valid, io_mem_req_ready;
        mem_req_t   io_mem_req_out;
        logic       io_mem_rsp_valid, io_mem_rsp_ready;
        mem_rsp_t   io_mem_rsp_in;

        // ---------------------------------------------------------
        // Split-phase memory interface (arbiter ↔ shim)
        // ---------------------------------------------------------
        logic       arb_mem_req_valid, arb_mem_req_ready;
        mem_req_t   arb_mem_req_out;
        logic       arb_mem_rsp_valid, arb_mem_rsp_ready;
        mem_rsp_t   arb_mem_rsp_in;

        // ---------------------------------------------------------
        // MDP signals (unused in P2a)
        // ---------------------------------------------------------
        logic        lsq_mdp_violation;
        logic [31:0] lsq_mdp_violation_pc;

        // ---------------------------------------------------------
        // LSQ Instantiation
        // ---------------------------------------------------------
        f386_lsq u_lsq (
            .clk              (clk),
            .rst_n            (rst_n),
            .flush            (flush),

            // Dispatch
            .ld_dispatch_valid (lsq_ld_dispatch_valid && !mem_dispatch_blocked),
            .ld_dispatch_rob_tag(rob_tag_u),
            .st_dispatch_valid (lsq_st_dispatch_valid && !mem_dispatch_blocked),
            .st_dispatch_rob_tag(rob_tag_u),
            .ld_dispatch_idx  (lsq_ld_dispatch_idx),
            .st_dispatch_idx  (lsq_st_dispatch_idx),
            .lq_full          (lsq_lq_full),
            .sq_full          (lsq_sq_full),

            // Microcode sideband dispatch/retirement
            .uc_ld_dispatch_valid (uc_mem_ld_dispatch),
            .uc_st_dispatch_valid (uc_mem_st_dispatch),
            .uc_dispatch_rob_tag  (uc_mem_dispatch_rob_tag),
            .uc_ld_dispatch_idx   (uc_lsq_ld_alloc_idx),
            .uc_st_dispatch_idx   (uc_lsq_st_alloc_idx),
            .uc_retire_st_valid   (uc_mem_retire_st),
            .uc_retire_st_idx     (uc_mem_retire_sq_idx),
            .uc_store_drain_done  (),

            // AGU load (normal | microcode — MMIO goes to IO path)
            .agu_ld_valid     (eff_ld_fire | uc_mem_ld_fire),
            .agu_ld_idx       (uc_mem_ld_fire ? uc_mem_lq_idx  : eff_ld_idx),
            .agu_ld_addr      (uc_mem_ld_fire ? uc_mem_addr    : eff_ld_addr),
            .agu_ld_size      (uc_mem_ld_fire ? uc_mem_size    : eff_ld_size),
            .agu_ld_byte_en   (uc_mem_ld_fire ? uc_mem_byte_en : eff_ld_byte_en),
            .agu_ld_signed    (1'b0),   // TODO: carry sign info from decode

            // AGU store (normal | microcode — MMIO classification on drain)
            .agu_st_valid     (eff_st_fire | uc_mem_st_fire),
            .agu_st_idx       (uc_mem_st_fire ? uc_mem_sq_idx   : eff_st_idx),
            .agu_st_addr      (uc_mem_st_fire ? uc_mem_addr     : eff_st_addr),
            .agu_st_data      (uc_mem_st_fire ? uc_mem_st_data  : eff_st_data),
            .agu_st_size      (uc_mem_st_fire ? uc_mem_size     : eff_st_size),
            .agu_st_byte_en   (uc_mem_st_fire ? uc_mem_byte_en  : eff_st_byte_en),

            // CDB load result
            .ld_cdb_valid     (lsq_ld_cdb_valid),
            .ld_cdb_tag       (lsq_ld_cdb_tag),
            .ld_cdb_data      (lsq_ld_cdb_data),
            .ld_cdb_fault     (lsq_ld_cdb_fault),

            // Retirement
            .retire_st_valid  (rob_retire_u_valid && rob_retire_u_is_store_w),
            .retire_st_idx    (rob_retire_u_sq_idx_w),

            // IO path load completion (MMIO load bypassed LSQ data path)
            .io_ld_complete_valid (io_ld_cdb_valid),
            .io_ld_complete_idx   (io_ld_cdb_lq_idx),
            .io_ld_complete_data  (io_ld_cdb_data),

            // Store queue empty (for IO path TSO serialization)
            .sq_empty         (lsq_sq_empty),

            // D-Cache (unused in P2 — stubs)
            .dcache_req_valid (),
            .dcache_req_addr  (),
            .dcache_req_wdata (),
            .dcache_req_byte_en(),
            .dcache_req_wr    (),
            .dcache_req_ready (1'b0),
            .dcache_resp_valid(1'b0),
            .dcache_resp_data (32'd0),

            // Split-phase memory (to arbiter client 0)
            .mem_req_valid    (lsq_mem_req_valid),
            .mem_req_ready    (lsq_mem_req_ready),
            .mem_req_out      (lsq_mem_req_out),
            .mem_rsp_valid    (lsq_mem_rsp_valid),
            .mem_rsp_ready    (lsq_mem_rsp_ready),
            .mem_rsp_in       (lsq_mem_rsp_in),

            // MDP
            .mdp_violation    (lsq_mdp_violation),
            .mdp_violation_pc (lsq_mdp_violation_pc)
        );

        // ---------------------------------------------------------
        // MMIO IO Path (MMIO loads — strongly ordered, in-order)
        // ---------------------------------------------------------
        f386_mmio_io_path u_io_path (
            .clk              (clk),
            .rst_n            (rst_n),
            .flush            (flush),

            // Upstream: MMIO load request
            .ld_req_valid     (eff_ld_mmio_fire),
            .ld_req_ready     (io_path_ld_ready),
            .ld_req_addr      (eff_io_addr),
            .ld_req_size      (eff_io_size),
            .ld_req_signed    (1'b0),   // TODO: carry sign info from decode
            .ld_req_rob_tag   (eff_io_rob_tag),
            .ld_req_lq_idx    (eff_io_lq_idx),

            // TSO ordering
            .sq_empty         (lsq_sq_empty),

            // CDB output
            .ld_cdb_valid     (io_ld_cdb_valid),
            .ld_cdb_tag       (io_ld_cdb_tag),
            .ld_cdb_data      (io_ld_cdb_data),
            .ld_cdb_lq_idx    (io_ld_cdb_lq_idx),
            .ld_cdb_fault     (io_ld_cdb_fault),

            // Downstream: split-phase memory (to arbiter client 1)
            .mem_req_valid    (io_mem_req_valid),
            .mem_req_ready    (io_mem_req_ready),
            .mem_req_out      (io_mem_req_out),
            .mem_rsp_valid    (io_mem_rsp_valid),
            .mem_rsp_ready    (io_mem_rsp_ready),
            .mem_rsp_in       (io_mem_rsp_in)
        );

        // ---------------------------------------------------------
        // 2-Client Arbiter: LSQ (c0) + IO path (c1) → shim
        // ---------------------------------------------------------
        f386_mem_req_arbiter u_arbiter (
            .clk              (clk),
            .rst_n            (rst_n),
            .flush            (flush),

            // Client 0 (LSQ)
            .c0_req_valid     (lsq_mem_req_valid),
            .c0_req_ready     (lsq_mem_req_ready),
            .c0_req           (lsq_mem_req_out),
            .c0_rsp_valid     (lsq_mem_rsp_valid),
            .c0_rsp_ready     (lsq_mem_rsp_ready),
            .c0_rsp           (lsq_mem_rsp_in),

            // Client 1 (IO path)
            .c1_req_valid     (io_mem_req_valid),
            .c1_req_ready     (io_mem_req_ready),
            .c1_req           (io_mem_req_out),
            .c1_rsp_valid     (io_mem_rsp_valid),
            .c1_rsp_ready     (io_mem_rsp_ready),
            .c1_rsp           (io_mem_rsp_in),

            // Downstream (to shim)
            .dn_req_valid     (arb_mem_req_valid),
            .dn_req_ready     (arb_mem_req_ready),
            .dn_req           (arb_mem_req_out),
            .dn_rsp_valid     (arb_mem_rsp_valid),
            .dn_rsp_ready     (arb_mem_rsp_ready),
            .dn_rsp           (arb_mem_rsp_in)
        );

        // ---------------------------------------------------------
        // Data port routing: MEM_FABRIC → split-phase, else → shim
        // ---------------------------------------------------------
        if (CONF_ENABLE_MEM_FABRIC) begin : gen_mem_fabric
            // Arbiter downstream → split-phase ports (no shim)
            assign sp_data_req_valid = arb_mem_req_valid;
            assign arb_mem_req_ready = sp_data_req_ready;
            assign sp_data_req       = arb_mem_req_out;
            assign arb_mem_rsp_valid = sp_data_rsp_valid;
            assign sp_data_rsp_ready = arb_mem_rsp_ready;
            assign arb_mem_rsp_in    = sp_data_rsp;

            // Stub legacy ports
            assign mem_addr         = 32'd0;
            assign mem_wdata        = 64'd0;
            assign mem_byte_en      = 8'd0;
            assign mem_req          = 1'b0;
            assign mem_wr           = 1'b0;
            assign mem_cacheable    = 1'b0;
            assign mem_strong_order = 1'b0;
        end else begin : gen_legacy_shim
            // Stub split-phase ports
            assign sp_data_req_valid = 1'b0;
            assign sp_data_req       = '0;
            assign sp_data_rsp_ready = 1'b0;

            // Perf counter wires (readable via simulation waveforms)
            logic [31:0] shim_ctr_req_total;
            logic [31:0] shim_ctr_rsp_total;
            logic [31:0] shim_ctr_stall_cycles;
            logic [31:0] shim_ctr_drain_events;
            logic [31:0] shim_ctr_fifo_full_cyc;

            f386_lsq_to_memctrl_shim u_shim (
                .clk          (clk),
                .rst_n        (rst_n),
                .flush        (flush),

                .req_valid    (arb_mem_req_valid),
                .req_ready    (arb_mem_req_ready),
                .req          (arb_mem_req_out),

                .rsp_valid    (arb_mem_rsp_valid),
                .rsp_ready    (arb_mem_rsp_ready),
                .rsp          (arb_mem_rsp_in),

                .data_addr         (mem_addr),
                .data_wdata        (mem_wdata),
                .data_byte_en      (mem_byte_en),
                .data_req          (mem_req),
                .data_wr           (mem_wr),
                .data_cacheable    (mem_cacheable),
                .data_strong_order (mem_strong_order),
                .data_rdata        (mem_rdata),
                .data_ack          (mem_ack),
                .data_gnt          (mem_gnt),

                .ctr_req_total    (shim_ctr_req_total),
                .ctr_rsp_total    (shim_ctr_rsp_total),
                .ctr_stall_cycles (shim_ctr_stall_cycles),
                .ctr_drain_events (shim_ctr_drain_events),
                .ctr_fifo_full_cyc(shim_ctr_fifo_full_cyc)
            );
        end

        // ---------------------------------------------------------
        // MMIO range coverage assertions (sim-only)
        // ---------------------------------------------------------
        `ifndef SYNTHESIS
        always @(posedge clk) begin
            if (mem_req && !mem_wr) begin
                if (mem_addr >= 32'hFEE0_0000 && mem_addr <= 32'hFEE0_0FFF)
                    $warning("APIC access at %08h -- not classified as MMIO", mem_addr);
                if (mem_addr >= 32'h0000_0CF8 && mem_addr <= 32'h0000_0CFF)
                    $warning("PCI config access at %08h -- not classified as MMIO", mem_addr);
                if (mem_addr >= 32'hFEC0_0000 && mem_addr <= 32'hFEC0_003F)
                    $warning("IOAPIC access at %08h -- not classified as MMIO", mem_addr);
            end
        end

        // IO path and LSQ CDB must never fire simultaneously
        always @(posedge clk) begin
            if (rst_n)
                assert (!(io_ld_cdb_valid && lsq_ld_cdb_valid))
                    else $error("CDB1: IO path and LSQ load CDB fired simultaneously");
        end
        `endif

    end else begin : gen_no_lsq_memif

        // ---------------------------------------------------------
        // Legacy stubs (gate OFF — no behavioral change)
        // ---------------------------------------------------------
        assign lsq_dispatch_blocked   = 1'b0;
        assign lsq_cdb1_active        = 1'b0;
        assign lsq_load_issue_stall   = 1'b0;
        assign uc_lsq_lq_full         = 1'b1;   // Always full (no LSQ)
        assign uc_lsq_sq_full         = 1'b1;
        assign uc_lsq_ld_alloc_idx    = '0;
        assign uc_lsq_st_alloc_idx    = '0;
        assign rob_dispatch_u_lq_idx  = '0;
        assign rob_dispatch_u_sq_idx  = '0;
        assign dtlb_fault             = 1'b0;
        assign dtlb_fault_addr        = 32'd0;

        assign mem_addr         = 32'd0;
        assign mem_wdata        = 64'd0;
        assign mem_byte_en      = 8'd0;
        assign mem_req          = 1'b0;
        assign mem_wr           = 1'b0;
        assign mem_cacheable    = 1'b0;
        assign mem_strong_order = 1'b0;

        // Stub split-phase ports
        assign sp_data_req_valid = 1'b0;
        assign sp_data_req       = '0;
        assign sp_data_rsp_ready = 1'b0;

        // Microcode regonly CDB0 phys_dest stub
        assign uc_regonly_phys_dest = '0;

        // Macro EA bridge stub (no AGU when LSQ disabled)
        assign uc_macro_ea = 32'd0;

        // CDB passthrough (no muxing)
        assign cdb0_valid      = raw_cdb0_valid;
        assign cdb0_tag        = raw_cdb0_tag;
        assign cdb0_data       = raw_cdb0_data;
        assign cdb0_flags      = raw_cdb0_flags;
        assign cdb0_flags_mask = raw_cdb0_flags_mask;
        assign cdb0_exception  = raw_cdb0_exception;
        assign cdb0_phys_dest  = raw_cdb0_phys_dest;
        assign cdb0_dest_valid = raw_cdb0_dest_valid;

        assign cdb1_valid      = raw_cdb1_valid;
        assign cdb1_tag        = raw_cdb1_tag;
        assign cdb1_data       = raw_cdb1_data;
        assign cdb1_flags      = raw_cdb1_flags;
        assign cdb1_flags_mask = raw_cdb1_flags_mask;
        assign cdb1_exception  = raw_cdb1_exception;
        assign cdb1_phys_dest  = raw_cdb1_phys_dest;
        assign cdb1_dest_valid = raw_cdb1_dest_valid;

    end endgenerate

    // Debug probe: microcode FSM state (for Verilator tests)
    logic [1:0] dbg_ucode_state;

    // =================================================================
    // 15. Microcode Sequencer Integration (P3.1a)
    // =================================================================
    // When CONF_ENABLE_MICROCODE is ON: instantiates sequencer, drain FSM,
    // muxes IQ/exec/CDB/PRF signals for micro-op execution.
    // When OFF: all eff_* signals are passthrough (zero behavior change).

    generate if (CONF_ENABLE_MICROCODE) begin : gen_microcode

        // ---------------------------------------------------------
        // Drain FSM States
        // ---------------------------------------------------------
        typedef enum logic [1:0] {
            UC_IDLE     = 2'd0,
            UC_DRAINING = 2'd1,   // Waiting for ROB head to reach macro-op
            UC_ACTIVE   = 2'd2    // Sequencer running micro-ops
        } ucode_state_t;

        ucode_state_t ucode_state;

        // Latched macro-op info
        rob_id_t  macro_rob_tag;
        logic [7:0]  macro_opcode;
        logic        macro_is_0f;
        logic [2:0]  macro_modrm_reg;
        logic        macro_is_32bit;
        logic        macro_is_rep;
        logic        macro_is_repne;
        logic [31:0] macro_pc;

        // Force dequeue: combinational — fires same cycle as OP_MICROCODE IQ issue
        // so the IQ clears the correct entry (not a later-issuing instruction)
        wire iq_force_dequeue = (ucode_state == UC_IDLE)
                             && iq_issue_valid
                             && (iq_issue_instr.op_cat == OP_MICROCODE);

        // Sequencer signals
        logic        seq_uop_valid;
        logic [47:0] seq_uop_data;
        op_type_t    seq_uop_op_type;
        logic [3:0]  seq_uop_alu_op;
        logic [2:0]  seq_uop_dest_reg;
        logic [2:0]  seq_uop_src_a_reg;
        logic [2:0]  seq_uop_src_b_reg;
        logic [2:0]  seq_uop_seg_reg;
        logic [7:0]  seq_uop_special_cmd;
        logic [15:0] seq_uop_immediate;
        logic        seq_uop_is_last;
        logic        seq_uop_is_atomic;
        logic        seq_busy;
        logic        seq_block_interrupt;

        // ---------------------------------------------------------
        // Sequencer Instantiation
        // ---------------------------------------------------------
        f386_microcode_sequencer u_ucode_seq (
            .clk            (clk),
            .rst_n          (rst_n),
            .flush          (flush),
            .start          (ucode_state == UC_DRAINING && rob_head_ptr == macro_rob_tag),
            .opcode         (macro_is_0f ? 8'h0F : macro_opcode),
            .opcode_ext     (macro_opcode),
            .is_0f_prefix   (macro_is_0f),
            .is_rep_prefix  (macro_is_rep),
            .is_repne       (macro_is_repne),
            .is_32bit       (macro_is_32bit),
            .modrm_reg      (macro_modrm_reg),
            .instr_pc       (macro_pc),
            .uop_valid      (seq_uop_valid),
            .uop_data       (seq_uop_data),
            .uop_op_type    (seq_uop_op_type),
            .uop_alu_op     (seq_uop_alu_op),
            .uop_dest_reg   (seq_uop_dest_reg),
            .uop_src_a_reg  (seq_uop_src_a_reg),
            .uop_src_b_reg  (seq_uop_src_b_reg),
            .uop_seg_reg    (seq_uop_seg_reg),
            .uop_special_cmd(seq_uop_special_cmd),
            .uop_immediate  (seq_uop_immediate),
            .uop_is_last    (seq_uop_is_last),
            .uop_is_atomic  (seq_uop_is_atomic),
            .exec_ack       (ucode_exec_ack),
            .busy           (seq_busy),
            .block_interrupt(seq_block_interrupt),
            .rep_ecx_zero   (1'b1),    // P3.1a stub: REP terminates immediately
            .rep_zf_value   (1'b0)     // P3.1c: real feedback
        );

        // ---------------------------------------------------------
        // Microcode Memory Engine (P3.1b)
        // ---------------------------------------------------------
        // Replaces synthetic memory stub with real AGU→LSQ path.
        // Stack-form micro-ops only (UCMD_PUSH_PRE, UCMD_POP_POST).

        // Detect memory micro-op from sequencer
        // PUSH_FLAGS/POP_FLAGS are OP_SYS_CALL in ROM but need the memory path
        // LOAD_DTR is OP_SYS_CALL in ROM but issues a second dword load
        wire uop_is_far_call = (seq_uop_special_cmd == UCMD_FAR_CALL);
        wire uop_is_far_call_mem = uop_is_far_call && pe_mode;  // PE: GDT reads

        wire uop_is_load_seg = (seq_uop_special_cmd == UCMD_LOAD_SEG);
        wire uop_is_load_seg_mem = uop_is_load_seg && pe_mode;  // PE: GDT reads

        // MOV Sreg step 0 (LOAD with UCMD_NOP): regonly for register form
        // The selector is already in macro_val_a from GPR source read at dispatch
        wire uop_is_mov_sreg_step0 = (ucode_state == UC_ACTIVE) && seq_uop_valid &&
            (macro_opcode == 8'h8E) && (seq_uop_op_type == OP_LOAD) &&
            (seq_uop_special_cmd == UCMD_NOP);

        wire uop_is_mem = (ucode_state == UC_ACTIVE) && seq_uop_valid &&
                          ((seq_uop_op_type == OP_LOAD || seq_uop_op_type == OP_STORE) &&
                           !uop_is_mov_sreg_step0 ||  // step 0 of reg-form MOV sreg is regonly
                           seq_uop_special_cmd == UCMD_PUSH_FLAGS ||
                           seq_uop_special_cmd == UCMD_POP_FLAGS ||
                           seq_uop_special_cmd == UCMD_LOAD_DTR ||
                           uop_is_far_call_mem ||
                           uop_is_load_seg_mem);

        // Detect PUSH variants (needs ESP on PRF port B)
        wire uop_is_push = uop_is_mem && (seq_uop_special_cmd == UCMD_PUSH_PRE ||
                                           seq_uop_special_cmd == UCMD_PUSH_FLAGS);

        // Detect register-only special commands (bypass execute, self-completing)
        wire uop_is_regonly_cmd = (ucode_state == UC_ACTIVE) && seq_uop_valid &&
            (seq_uop_special_cmd == UCMD_STORE_CR || seq_uop_special_cmd == UCMD_LOAD_CR ||
             (uop_is_far_call && !pe_mode) ||
             (uop_is_load_seg && !pe_mode) ||      // Real-mode MOV Sreg: no GDT reads
             uop_is_mov_sreg_step0);               // MOV Sreg step 0 reg form: self-complete

        // PRF port B needs ESP for PUSH variants and POP_FLAGS
        wire uop_needs_esp_b = uop_is_push ||
                               (uop_is_mem && seq_uop_special_cmd == UCMD_POP_FLAGS);

        typedef enum logic [1:0] {
            UM_IDLE      = 2'd0,
            UM_ALLOC     = 2'd1,
            UM_ISSUE     = 2'd2,
            UM_LOAD_WAIT = 2'd3
        } uc_mem_state_t;

        uc_mem_state_t uc_mem_state;

        // Latched context
        logic        uc_mem_is_load_r;
        logic [31:0] uc_mem_addr_r;
        logic [31:0] uc_mem_data_r;
        lq_idx_t     uc_mem_lq_idx_r;
        sq_idx_t     uc_mem_sq_idx_r;
        logic [7:0]  uc_mem_special_r;
        phys_reg_t   uc_mem_phys_dest_r;
        logic [31:0] uc_mem_esp_new_r;

        // PUSHA original ESP latch: x86 PUSHA pushes the ESP value
        // from *before* the instruction began (not the decremented value).
        logic [31:0] uc_orig_esp_r;
        logic        uc_orig_esp_latched;

        // Macro EA: AGU effective address latched at drain time (for generic LOAD/STORE)
        logic [31:0] macro_ea;

        // LOAD_DTR: temp register for step 0's dword (limit + base[15:0])
        logic [31:0] uc_dtr_low_r;

        // FAR_CALL: dispatch-time far selector latch
        logic [15:0] uc_far_sel_latch;

        // FAR_CALL: drain-time latches
        logic [15:0] macro_far_sel;    // New CS selector
        logic [31:0] macro_imm;        // New EIP (absolute offset from far ptr)

        // FAR_CALL: GDT read phase tracking
        logic        uc_far_phase;     // 0=first GDT dword, 1=second
        logic [31:0] uc_far_desc_lo;   // Latched first GDT dword

        // Size constant: dword for 32-bit stack ops
        localparam logic [1:0] UC_MEM_SIZE = 2'd2;
        localparam logic [3:0] UC_MEM_BYTE_EN = 4'b1111;
        localparam logic [31:0] ESP_DELTA = 32'd4;

        // Memory engine done pulse (for exec_ack)
        // Suppress for intermediate GDT load (phase 0 → need second read)
        wire uc_gdt_phase0 = (uc_mem_special_r == UCMD_FAR_CALL ||
                              uc_mem_special_r == UCMD_LOAD_SEG) && !uc_far_phase;
        wire uc_mem_done = (uc_mem_state == UM_ISSUE && !uc_mem_is_load_r) ||
                           (uc_mem_state == UM_LOAD_WAIT && lsq_cdb1_active &&
                            !uc_gdt_phase0);

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                uc_mem_state      <= UM_IDLE;
                uc_mem_is_load_r  <= 1'b0;
                uc_mem_addr_r     <= 32'd0;
                uc_mem_data_r     <= 32'd0;
                uc_mem_lq_idx_r   <= '0;
                uc_mem_sq_idx_r   <= '0;
                uc_mem_special_r  <= 8'd0;
                uc_mem_phys_dest_r<= '0;
                uc_mem_esp_new_r  <= 32'd0;
                uc_orig_esp_r     <= 32'd0;
                uc_orig_esp_latched <= 1'b0;
                macro_ea          <= 32'd0;
                uc_dtr_low_r      <= 32'd0;
                uc_far_sel_latch  <= 16'd0;
                macro_far_sel     <= 16'd0;
                macro_imm         <= 32'd0;
                uc_far_phase      <= 1'b0;
                uc_far_desc_lo    <= 32'd0;
            end else if (flush) begin
                uc_mem_state      <= UM_IDLE;
                uc_orig_esp_latched <= 1'b0;
                uc_far_phase      <= 1'b0;
            end else begin
                case (uc_mem_state)
                    UM_IDLE: begin
                        // Clear PUSHA ESP latch when microcode sequence ends
                        if (ucode_state == UC_IDLE)
                            uc_orig_esp_latched <= 1'b0;
                        if (uop_is_mem) begin
                            uc_mem_state     <= UM_ALLOC;
                            uc_mem_is_load_r <= (seq_uop_op_type == OP_LOAD) ||
                                               (seq_uop_special_cmd == UCMD_POP_FLAGS) ||
                                               (seq_uop_special_cmd == UCMD_LOAD_DTR) ||
                                               uop_is_far_call_mem ||
                                               uop_is_load_seg_mem;
                            uc_mem_special_r <= seq_uop_special_cmd;
                            uc_mem_phys_dest_r <= rename_com_map[seq_uop_dest_reg];

                            case (seq_uop_special_cmd)
                                UCMD_PUSH_PRE: begin
                                    // prf_data_b = ESP (via PRF override below)
                                    uc_mem_addr_r    <= prf_data_b - ESP_DELTA;
                                    uc_mem_esp_new_r <= prf_data_b - ESP_DELTA;
                                    // PUSHA: latch original ESP on first PUSH of sequence
                                    if (!uc_orig_esp_latched) begin
                                        uc_orig_esp_r       <= prf_data_b;
                                        uc_orig_esp_latched <= 1'b1;
                                    end
                                    // PUSHA step 4: push original ESP, not decremented value
                                    uc_mem_data_r <= (seq_uop_src_a_reg == 3'd4) ?
                                                      uc_orig_esp_r : prf_data_a;
                                end
                                UCMD_PUSH_FLAGS: begin
                                    // PUSHF: push EFLAGS to stack (ESP-4)
                                    uc_mem_addr_r    <= prf_data_b - ESP_DELTA;
                                    uc_mem_esp_new_r <= prf_data_b - ESP_DELTA;
                                    uc_mem_data_r    <= sys_eflags;
                                end
                                UCMD_POP_POST: begin
                                    // prf_data_a = ESP (src_a_reg = ESP in microcode)
                                    uc_mem_addr_r    <= prf_data_a;
                                    uc_mem_data_r    <= 32'd0;
                                    uc_mem_esp_new_r <= prf_data_a + ESP_DELTA;
                                end
                                UCMD_POP_FLAGS: begin
                                    // POPF: load from stack to EFLAGS (ESP via port B)
                                    uc_mem_addr_r    <= prf_data_b;
                                    uc_mem_data_r    <= 32'd0;
                                    uc_mem_esp_new_r <= prf_data_b + ESP_DELTA;
                                end
                                UCMD_LOAD_DTR: begin
                                    // LGDT/LIDT step 1: capture step 0 result,
                                    // issue second dword load at EA+4
                                    uc_dtr_low_r     <= prf_data_a;       // {base[15:0], limit[15:0]}
                                    uc_mem_addr_r    <= macro_ea + 32'd4; // base[31:16] at offset 4
                                    uc_mem_data_r    <= 32'd0;
                                    uc_mem_esp_new_r <= 32'd0;
                                end
                                UCMD_FAR_CALL: begin
                                    // Protected-mode far JMP: first GDT dword load
                                    // GDT addr = GDTR.base + (selector & 0xFFF8)
                                    uc_mem_addr_r    <= sys_gdtr_base + {16'd0, macro_far_sel[15:3], 3'd0};
                                    uc_mem_data_r    <= 32'd0;
                                    uc_mem_esp_new_r <= 32'd0;
                                    uc_far_phase     <= 1'b0;
                                end
                                UCMD_LOAD_SEG: begin
                                    // Protected-mode MOV Sreg: first GDT dword load
                                    // Selector from macro_val_a (GPR source, register form)
                                    uc_mem_addr_r    <= sys_gdtr_base + {16'd0, macro_val_a[15:3], 3'd0};
                                    uc_mem_data_r    <= 32'd0;
                                    uc_mem_esp_new_r <= 32'd0;
                                    uc_far_phase     <= 1'b0;
                                end
                                default: begin
                                    // Generic LOAD/STORE: address from macro EA
                                    uc_mem_addr_r    <= macro_ea;
                                    uc_mem_data_r    <= prf_data_a;  // Store data (if store)
                                    uc_mem_esp_new_r <= 32'd0;
                                end
                            endcase
                        end
                    end

                    UM_ALLOC: begin
                        if (uc_mem_is_load_r && !uc_lsq_lq_full) begin
                            uc_mem_lq_idx_r <= uc_lsq_ld_alloc_idx;
                            uc_mem_state    <= UM_ISSUE;
                        end else if (!uc_mem_is_load_r && !uc_lsq_sq_full) begin
                            uc_mem_sq_idx_r <= uc_lsq_st_alloc_idx;
                            uc_mem_state    <= UM_ISSUE;
                        end
                    end

                    UM_ISSUE: begin
                        if (uc_mem_is_load_r)
                            uc_mem_state <= UM_LOAD_WAIT;
                        else
                            uc_mem_state <= UM_IDLE;  // Store: done at issue
                    end

                    UM_LOAD_WAIT: begin
                        if (lsq_cdb1_active) begin
                            if ((uc_mem_special_r == UCMD_FAR_CALL ||
                                 uc_mem_special_r == UCMD_LOAD_SEG) && !uc_far_phase) begin
                                // Phase 0 complete: latch low dword, issue second read
                                uc_far_desc_lo   <= cdb1_data[31:0];
                                uc_mem_addr_r    <= uc_mem_addr_r + 32'd4;
                                uc_far_phase     <= 1'b1;
                                uc_mem_state     <= UM_ALLOC;  // Re-enter for second load
                            end else begin
                                uc_mem_state     <= UM_IDLE;   // Normal completion
                            end
                        end
                    end

                    default: uc_mem_state <= UM_IDLE;
                endcase
            end
        end

        // Drive bridge signals
        assign uc_mem_ld_dispatch      = (uc_mem_state == UM_ALLOC) && uc_mem_is_load_r && !uc_lsq_lq_full;
        assign uc_mem_st_dispatch      = (uc_mem_state == UM_ALLOC) && !uc_mem_is_load_r && !uc_lsq_sq_full;
        assign uc_mem_dispatch_rob_tag = macro_rob_tag;
        assign uc_mem_ld_fire          = (uc_mem_state == UM_ISSUE) && uc_mem_is_load_r;
        assign uc_mem_st_fire          = (uc_mem_state == UM_ISSUE) && !uc_mem_is_load_r;
        assign uc_mem_addr             = uc_mem_addr_r;
        assign uc_mem_lq_idx           = uc_mem_lq_idx_r;
        assign uc_mem_sq_idx           = uc_mem_sq_idx_r;
        assign uc_mem_st_data          = uc_mem_data_r;
        assign uc_mem_size             = UC_MEM_SIZE;
        assign uc_mem_byte_en          = UC_MEM_BYTE_EN;
        assign uc_mem_retire_st        = (uc_mem_state == UM_ISSUE) && !uc_mem_is_load_r;
        assign uc_mem_retire_sq_idx    = uc_mem_sq_idx_r;
        assign uc_mem_load_waiting     = (uc_mem_state == UM_LOAD_WAIT);
        assign uc_mem_cdb1_phys_dest   = uc_mem_phys_dest_r;

        // ESP CDB0 synthesis
        wire esp_is_push = (uc_mem_special_r == UCMD_PUSH_PRE) ||
                           (uc_mem_special_r == UCMD_PUSH_FLAGS);
        wire esp_is_pop  = (uc_mem_special_r == UCMD_POP_POST) ||
                           (uc_mem_special_r == UCMD_POP_FLAGS);
        assign uc_mem_esp_cdb0_fire = (uc_mem_state == UM_ISSUE && !uc_mem_is_load_r && esp_is_push) ||
                                       (uc_mem_state == UM_LOAD_WAIT && lsq_cdb1_active && esp_is_pop);
        assign uc_mem_esp_cdb0_data = uc_mem_esp_new_r;
        assign uc_mem_esp_phys_dest = rename_com_map[3'd4];  // ESP = arch reg 4

        // Bridge uc_mem_special_r to module level for gen_lsq_memif
        assign uc_mem_special_cmd = uc_mem_special_r;

        // ---------------------------------------------------------
        // Drain FSM
        // ---------------------------------------------------------
        // Register-only special command self-completing path (1-cycle delay)
        logic uc_regonly_pending_r;
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n)      uc_regonly_pending_r <= 1'b0;
            else if (flush)  uc_regonly_pending_r <= 1'b0;
            else             uc_regonly_pending_r <= uop_is_regonly_cmd && !uc_regonly_pending_r;
        end
        wire uc_regonly_done = uc_regonly_pending_r;

        // Microcode exec_ack: CDB0 for ALU ops, UM done for memory ops,
        // regonly done for register-only special commands
        wire ucode_exec_ack = (ucode_state == UC_ACTIVE) &&
                              (raw_cdb0_valid || uc_mem_done || uc_regonly_done);

        // Latched operand value for STORE_CR (source GPR value from IQ issue)
        logic [31:0] macro_val_a;

        // Dispatch-time far_selector capture: only one OP_MICROCODE in-flight
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n)
                uc_far_sel_latch <= 16'd0;
            else if (dispatch_u_valid && dec_instr_u.op_cat == OP_MICROCODE)
                uc_far_sel_latch <= raw_dec_far_selector_u;
        end

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                ucode_state     <= UC_IDLE;
                macro_rob_tag   <= '0;
                macro_opcode    <= 8'h0;
                macro_is_0f     <= 1'b0;
                macro_modrm_reg <= 3'd0;
                macro_is_32bit  <= 1'b0;
                macro_is_rep    <= 1'b0;
                macro_is_repne  <= 1'b0;
                macro_pc        <= 32'h0;
                macro_val_a     <= 32'h0;
            end else if (flush) begin
                ucode_state     <= UC_IDLE;
            end else begin
                case (ucode_state)
                    UC_IDLE: begin
                        // Detect OP_MICROCODE issued from IQ
                        if (iq_issue_valid && iq_issue_instr.op_cat == OP_MICROCODE) begin
                            ucode_state      <= UC_DRAINING;
                            // Latch macro-op info from IQ issue
                            macro_rob_tag    <= iq_issue_instr.rob_tag;
                            macro_opcode     <= iq_issue_instr.opcode;
                            macro_is_0f      <= iq_issue_instr.is_0f;
                            macro_modrm_reg  <= iq_issue_instr.modrm_reg;
                            macro_is_32bit   <= iq_issue_instr.is_32bit;
                            macro_is_rep     <= iq_issue_instr.is_rep;
                            macro_is_repne   <= iq_issue_instr.is_repne;
                            macro_pc         <= iq_issue_instr.pc;
                            macro_val_a      <= iq_issue_instr.val_a;
                            macro_ea         <= uc_macro_ea;
                            macro_far_sel    <= uc_far_sel_latch;
                            macro_imm        <= iq_issue_instr.imm_value;
                        end
                    end

                    UC_DRAINING: begin
                        // Wait for ROB head to reach macro-op (all prior retired)
                        if (rob_head_ptr == macro_rob_tag) begin
                            ucode_state <= UC_ACTIVE;
                        end
                    end

                    UC_ACTIVE: begin
                        // Sequencer done: return to idle
                        if (!seq_busy) begin
                            ucode_state <= UC_IDLE;
                        end
                    end

                    default: ucode_state <= UC_IDLE;
                endcase
            end
        end

        assign ucode_active = (ucode_state != UC_IDLE);
        assign dbg_ucode_state = ucode_state;

        // ---------------------------------------------------------
        // IQ exec_ready mux (section d)
        // ---------------------------------------------------------
        assign eff_iq_exec_ready =
            iq_force_dequeue                        ? 1'b1 :  // Force dequeue macro-op
            (ucode_state == UC_ACTIVE)              ? 1'b0 :  // Suppress IQ during sequencer
            (exec_u_ready && !lsq_load_issue_stall);          // Normal

        // ---------------------------------------------------------
        // Execute u_valid mux (section f)
        // ---------------------------------------------------------
        // During UC_ACTIVE: sequencer drives valid (skipping memory + regonly ops)
        // On dequeue cycle: suppress (macro-op consumed, not executed)
        assign eff_exec_u_valid =
            (ucode_state == UC_ACTIVE) ? (seq_uop_valid && !uop_is_mem && !uop_is_regonly_cmd) :
            iq_force_dequeue           ? 1'b0 :
            iq_issue_valid;

        // ---------------------------------------------------------
        // PRF read address mux (section g)
        // ---------------------------------------------------------
        // During UC_ACTIVE: read from committed physical registers
        // ESP override: port B reads ESP for PUSH/PUSH_FLAGS/POP_FLAGS
        assign eff_prf_rd_addr_a = (ucode_state == UC_ACTIVE) ?
            rename_com_map[seq_uop_src_a_reg] : src_phys_a;
        assign eff_prf_rd_addr_b = (ucode_state == UC_ACTIVE) ?
            (uop_needs_esp_b ? rename_com_map[3'd4] :  // ESP = arch reg 4
             rename_com_map[seq_uop_src_b_reg]) : src_phys_b;

        // ---------------------------------------------------------
        // Execute u_instr override (section h)
        // ---------------------------------------------------------
        always_comb begin
            if (ucode_state == UC_ACTIVE && seq_uop_valid) begin
                eff_exec_u_instr.is_valid    = 1'b1;
                eff_exec_u_instr.pc          = macro_pc;
                eff_exec_u_instr.opcode      = {4'b0, seq_uop_alu_op};
                eff_exec_u_instr.op_category = seq_uop_op_type;
                eff_exec_u_instr.reg_dest    = seq_uop_dest_reg;
                eff_exec_u_instr.reg_src_a   = seq_uop_src_a_reg;
                eff_exec_u_instr.reg_src_b   = seq_uop_src_b_reg;
                eff_exec_u_instr.rob_tag     = macro_rob_tag;
                eff_exec_u_instr.br_tag      = '0;
                eff_exec_u_instr.dest_valid  = !ucode_has_eflags_cmd;  // Pure EFLAGS cmds: no PRF write
                eff_exec_u_instr.phys_dest   = rename_com_map[seq_uop_dest_reg];
                eff_exec_u_instr.imm_value   = {16'h0, seq_uop_immediate};
                eff_exec_u_instr.flags_in    = alu_flags_current;
                eff_exec_u_instr.flags_mask  = (seq_uop_op_type == OP_ALU_REG ||
                                                 seq_uop_op_type == OP_ALU_IMM)
                                                ? (seq_uop_special_cmd != UCMD_NOP ? 6'b000000 : 6'b111111)
                                                : 6'b000000;
                eff_exec_u_instr.pred_taken  = 1'b0;
                eff_exec_u_instr.pred_target = 32'd0;
                eff_exec_u_instr.sem_tag     = SEM_NONE;
            end else begin
                eff_exec_u_instr = exec_u_instr;
            end
        end

        // ---------------------------------------------------------
        // Execute operand mux (section i)
        // ---------------------------------------------------------
        assign eff_u_op_a = (ucode_state == UC_ACTIVE) ? prf_data_a : iq_issue_instr.val_a;
        assign eff_u_op_b = (ucode_state == UC_ACTIVE) ? prf_data_b : iq_issue_instr.val_b;

        // ---------------------------------------------------------
        // CDB0 signal split (section j)
        // ---------------------------------------------------------
        // ROB CDB0: suppress intermediate micro-ops, allow last
        // cdb0_valid now includes both execute CDB0 (ALU ops) and
        // ESP CDB0 synthesis (memory ops via gen_lsq_memif mux)
        wire ucode_suppress_rob = (ucode_state == UC_ACTIVE) && seq_busy && !seq_uop_is_last;

        assign eff_rob_cdb0_valid = ucode_suppress_rob ? 1'b0 :    // Intermediate: suppress
                                    cdb0_valid;                      // Normal + ESP CDB0

        assign eff_rob_cdb0_tag = (ucode_state == UC_ACTIVE) ? macro_rob_tag : cdb0_tag;

        // ---------------------------------------------------------
        // Interrupt block (section o)
        // ---------------------------------------------------------
        assign ucode_block_interrupt = seq_block_interrupt;

        // ---------------------------------------------------------
        // Special command routing (section m) — EFLAGS commands
        // ---------------------------------------------------------
        logic ucode_has_eflags_cmd;
        assign ucode_has_eflags_cmd = (seq_uop_special_cmd inside {
            UCMD_CLC, UCMD_STC, UCMD_CMC, UCMD_CLD, UCMD_STD,
            UCMD_POP_FLAGS});

        always_comb begin
            ucode_eflags_din  = 32'h0;
            ucode_eflags_mask = 32'h0;
            case (seq_uop_special_cmd)
                UCMD_CLC: begin  // Clear CF
                    ucode_eflags_mask[EFLAGS_CF] = 1'b1;
                    ucode_eflags_din[EFLAGS_CF]  = 1'b0;
                end
                UCMD_STC: begin  // Set CF
                    ucode_eflags_mask[EFLAGS_CF] = 1'b1;
                    ucode_eflags_din[EFLAGS_CF]  = 1'b1;
                end
                UCMD_CMC: begin  // Complement CF
                    ucode_eflags_mask[EFLAGS_CF] = 1'b1;
                    ucode_eflags_din[EFLAGS_CF]  = ~sys_eflags[EFLAGS_CF];
                end
                UCMD_CLD: begin  // Clear DF
                    ucode_eflags_mask[EFLAGS_DF] = 1'b1;
                    ucode_eflags_din[EFLAGS_DF]  = 1'b0;
                end
                UCMD_STD: begin  // Set DF
                    ucode_eflags_mask[EFLAGS_DF] = 1'b1;
                    ucode_eflags_din[EFLAGS_DF]  = 1'b1;
                end
                UCMD_POP_FLAGS: begin  // Pop EFLAGS from stack
                    // Writable: CF,PF,AF,ZF,SF,TF,IF,DF,OF,IOPL,NT,AC,ID
                    ucode_eflags_mask = 32'h0024_4FD5;
                    ucode_eflags_din  = cdb1_data[31:0];  // Loaded value from LSQ
                end
                default: begin end
            endcase
        end

        assign ucode_eflags_we = ucode_exec_ack && ucode_has_eflags_cmd && !flush;

        // ---------------------------------------------------------
        // Special command routing (section n) — CR access
        // ---------------------------------------------------------
        // CR read mux (combinational, for LOAD_CR CDB0 data)
        logic [31:0] cr_read_mux;
        always_comb begin
            case (macro_modrm_reg)
                3'd0:    cr_read_mux = sys_cr0;
                3'd2:    cr_read_mux = sys_cr2;
                3'd3:    cr_read_mux = sys_cr3;
                3'd4:    cr_read_mux = sys_cr4;
                default: cr_read_mux = 32'd0;
            endcase
        end

        // Register-only CDB0 synthesis (LOAD_CR / STORE_CR)
        assign uc_regonly_cdb0_fire = uc_regonly_done;
        assign uc_regonly_cdb0_data = (seq_uop_special_cmd == UCMD_LOAD_CR) ? cr_read_mux : 32'd0;
        // uc_regonly_phys_dest assigned in gen_lsq_memif (where rob_phys_dest_tbl lives)
        assign uc_regonly_dest_valid = (seq_uop_special_cmd == UCMD_LOAD_CR);

        // CR write port (STORE_CR: write macro_val_a to CR[macro_modrm_reg])
        // Note: no !flush gate — CR3 write itself causes flush (avoid comb loop)
        assign ucode_cr_we  = uc_regonly_done && (seq_uop_special_cmd == UCMD_STORE_CR);
        assign ucode_cr_idx = cr_idx_t'(macro_modrm_reg);
        assign ucode_cr_din = macro_val_a;

        // ---------------------------------------------------------
        // DTR write port (LGDT/LIDT: LOAD_DTR second load completes)
        // ---------------------------------------------------------
        wire dtr_write_fire = uc_mem_done && (uc_mem_special_r == UCMD_LOAD_DTR);
        assign ucode_dtr_we        = dtr_write_fire;
        assign ucode_dtr_idx       = (macro_modrm_reg == 3'd3) ? DTR_IDTR : DTR_GDTR;
        assign ucode_dtr_limit_din = uc_dtr_low_r[15:0];
        assign ucode_dtr_base_din  = {cdb1_data[15:0], uc_dtr_low_r[31:16]};

        // ---------------------------------------------------------
        // Segment cache write port (far JMP + MOV Sreg)
        // ---------------------------------------------------------
        // FAR_CALL commits
        wire uc_far_commit_pm = uc_mem_done && (uc_mem_special_r == UCMD_FAR_CALL);
        wire uc_far_commit_real = uc_regonly_done && (seq_uop_special_cmd == UCMD_FAR_CALL);
        wire uc_far_commit = uc_far_commit_pm || uc_far_commit_real;

        // LOAD_SEG commits
        wire uc_load_seg_commit_pm = uc_mem_done && (uc_mem_special_r == UCMD_LOAD_SEG);
        wire uc_load_seg_commit_real = uc_regonly_done && (seq_uop_special_cmd == UCMD_LOAD_SEG);
        wire uc_load_seg_commit = uc_load_seg_commit_pm || uc_load_seg_commit_real;

        // GDT descriptor = {high_dword, low_dword}
        wire [63:0] gdt_desc = {cdb1_data[31:0], uc_far_desc_lo};

        // Selector for MOV Sreg (from GPR source, register form)
        wire [15:0] seg_load_selector = macro_val_a[15:0];

        // Real-mode CS cache: base = selector << 4, limit=0xFFFF, P=1, S=1, type=code-RX
        wire [31:0] rm_cs_base = {12'd0, macro_far_sel, 4'd0};
        wire [63:0] real_mode_cs_cache = {
            rm_cs_base[31:24],         // [63:56] base[31:24]
            8'h00,                      // [55:48] G=0, D/B=0, res, limit[19:16]=0
            8'h9B,                      // [47:40] P=1, DPL=00, S=1, type=1011 (code,R,accessed)
            rm_cs_base[23:16],         // [39:32] base[23:16]
            rm_cs_base[15:0],          // [31:16] base[15:0]
            16'hFFFF                    // [15:0]  limit=0xFFFF
        };

        // Real-mode data cache: base = selector << 4, limit=0xFFFF, P=1, S=1, type=data-RW
        wire [31:0] rm_data_base = {12'd0, seg_load_selector, 4'd0};
        wire [63:0] real_mode_data_cache = {
            rm_data_base[31:24],       // [63:56] base[31:24]
            8'h00,                      // [55:48] G=0, D/B=0
            8'h93,                      // [47:40] P=1, DPL=00, S=1, type=0011 (data,R/W,accessed)
            rm_data_base[23:16],       // [39:32] base[23:16]
            rm_data_base[15:0],        // [31:16] base[15:0]
            16'hFFFF                    // [15:0]  limit=0xFFFF
        };

        assign ucode_seg_we    = uc_far_commit || uc_load_seg_commit;
        assign ucode_seg_idx   = uc_far_commit ? SEG_CS : seg_idx_t'(macro_modrm_reg);
        assign ucode_seg_sel   = uc_far_commit ? macro_far_sel : seg_load_selector;
        assign ucode_seg_cache = uc_far_commit ?
            (pe_mode ? gdt_desc : real_mode_cs_cache) :
            (pe_mode ? gdt_desc : real_mode_data_cache);

        // ---------------------------------------------------------
        // PC redirect (far JMP: flush pipeline, redirect to new EIP)
        // ---------------------------------------------------------
        assign ucode_redirect_valid = uc_far_commit;
        assign ucode_redirect_pc    = macro_imm;  // New EIP from far JMP offset

        // CR write flush redirect: next fetch block after microcode instruction
        // (V-pipe is always suppressed for OP_MICROCODE, so next block is correct)
        assign ucode_cr_flush_next_pc = {macro_pc[31:4], 4'h0} + 32'd16;

        // Deferred special commands (sim-only log)
        // synopsys translate_off
        always_ff @(posedge clk) begin
            if (ucode_state == UC_ACTIVE && seq_uop_valid && !flush) begin
                if (seq_uop_special_cmd != UCMD_NOP && !ucode_has_eflags_cmd
                    && seq_uop_special_cmd != UCMD_PUSH_PRE
                    && seq_uop_special_cmd != UCMD_POP_POST
                    && seq_uop_special_cmd != UCMD_PUSH_FLAGS
                    && seq_uop_special_cmd != UCMD_LOAD_CR
                    && seq_uop_special_cmd != UCMD_STORE_CR
                    && seq_uop_special_cmd != UCMD_LOAD_DTR
                    && seq_uop_special_cmd != UCMD_FAR_CALL
                    && seq_uop_special_cmd != UCMD_LOAD_SEG) begin
                    case (seq_uop_special_cmd)
                        UCMD_STORE_DTR,                    // deferred P3.2+
                        UCMD_STORE_SEG,                    // deferred P3.4+
                        UCMD_INT_ENTER, UCMD_INT_EXIT,     // deferred P3.3
                        UCMD_LAHF, UCMD_SAHF,              // deferred
                        UCMD_CLI, UCMD_STI,                // deferred P3.2+ (IOPL)
                        UCMD_HALT: begin end                // deferred P3.2+
                        default: begin end
                    endcase
                end
            end
        end
        // synopsys translate_on

    end else begin : gen_no_microcode

        // ---------------------------------------------------------
        // Gate OFF: All signals passthrough (zero behavior change)
        // ---------------------------------------------------------
        assign ucode_active          = 1'b0;
        assign dbg_ucode_state       = 2'd0;
        // Microcode memory engine bridge tie-offs
        assign uc_mem_ld_fire          = 1'b0;
        assign uc_mem_st_fire          = 1'b0;
        assign uc_mem_addr             = 32'd0;
        assign uc_mem_lq_idx           = '0;
        assign uc_mem_sq_idx           = '0;
        assign uc_mem_st_data          = 32'd0;
        assign uc_mem_size             = 2'd0;
        assign uc_mem_byte_en          = 4'd0;
        assign uc_mem_ld_dispatch      = 1'b0;
        assign uc_mem_st_dispatch      = 1'b0;
        assign uc_mem_dispatch_rob_tag = '0;
        assign uc_mem_retire_st        = 1'b0;
        assign uc_mem_retire_sq_idx    = '0;
        assign uc_mem_load_waiting     = 1'b0;
        assign uc_mem_cdb1_phys_dest   = '0;
        assign uc_mem_esp_cdb0_fire    = 1'b0;
        assign uc_mem_esp_cdb0_data    = 32'd0;
        assign uc_mem_esp_phys_dest    = '0;
        assign uc_mem_special_cmd      = 8'd0;
        assign uc_regonly_cdb0_fire    = 1'b0;
        assign uc_regonly_cdb0_data    = 32'd0;
        // uc_regonly_phys_dest assigned in gen_lsq_memif / gen_no_lsq_memif
        assign uc_regonly_dest_valid   = 1'b0;
        assign ucode_cr_we            = 1'b0;
        assign ucode_cr_idx           = CR_0;
        assign ucode_cr_din           = 32'd0;
        assign ucode_dtr_we           = 1'b0;
        assign ucode_dtr_idx          = DTR_GDTR;
        assign ucode_dtr_base_din     = 32'd0;
        assign ucode_dtr_limit_din    = 16'd0;
        assign ucode_seg_we          = 1'b0;
        assign ucode_seg_idx         = SEG_ES;
        assign ucode_seg_sel         = 16'h0;
        assign ucode_seg_cache       = 64'h0;
        assign ucode_redirect_valid  = 1'b0;
        assign ucode_redirect_pc     = 32'd0;
        assign ucode_cr_flush_next_pc = 32'd0;
        assign eff_iq_exec_ready     = exec_u_ready && !lsq_load_issue_stall;
        assign eff_exec_u_valid      = iq_issue_valid;
        assign eff_exec_u_instr      = exec_u_instr;
        assign eff_u_op_a            = iq_issue_instr.val_a;
        assign eff_u_op_b            = iq_issue_instr.val_b;
        assign eff_prf_rd_addr_a     = src_phys_a;
        assign eff_prf_rd_addr_b     = src_phys_b;
        assign eff_rob_cdb0_valid    = cdb0_valid;
        assign eff_rob_cdb0_tag      = cdb0_tag;
        assign ucode_block_interrupt = 1'b0;
        assign ucode_eflags_din      = 32'h0;
        assign ucode_eflags_mask     = 32'h0;
        assign ucode_eflags_we       = 1'b0;

    end endgenerate

endmodule
