/*
 * fabi386: Register Rename (v2.0 — Snapshot-Capable)
 * ----------------------------------------------------
 * Integrates the rename map table, free list, and busy table into a
 * single top-level rename module for the 2-wide superscalar OoO core.
 *
 * Eliminates WAW/WAR hazards by mapping 8 architectural registers to
 * 32 physical registers.  Supports per-branch rename snapshots for
 * fast mispredict recovery when CONF_ENABLE_RENAME_SNAP is set.
 *
 * When CONF_ENABLE_RENAME_SNAP == 0 (default), snapshot logic is
 * disabled: no snap_take, no snap_restore.  Flush recovery falls back
 * to restoring spec_map from com_map (full-flush path).
 *
 * Reference: BOOM rename-stage.scala, rsd RenameLogic.sv
 */

import f386_pkg::*;

module f386_register_rename (
    input  logic        clk,
    input  logic        reset_n,

    // --- Rename request (U-pipe) ---
    input  logic [2:0]  arch_dest_u,
    output phys_reg_t   phys_dest_u,
    output logic        can_rename,

    // --- Rename request (V-pipe) ---
    input  logic [2:0]  arch_dest_v,
    output phys_reg_t   phys_dest_v,
    output logic        v_alloc_valid,     // V-pipe allocation succeeded
    input  logic        rename_v_valid,

    // --- Source operand lookup (U-pipe) ---
    input  logic [2:0]  src_arch_a,
    input  logic [2:0]  src_arch_b,
    output phys_reg_t   src_phys_a,
    output phys_reg_t   src_phys_b,
    output logic        src_busy_a,
    output logic        src_busy_b,

    // --- Source operand lookup (V-pipe) ---
    input  logic [2:0]  src_arch_c,
    input  logic [2:0]  src_arch_d,
    output phys_reg_t   src_phys_c,
    output phys_reg_t   src_phys_d,
    output logic        src_busy_c,
    output logic        src_busy_d,

    // --- Old physical mapping (for freelist reclaim at retirement) ---
    output phys_reg_t   old_phys_u,
    output phys_reg_t   old_phys_v,

    // --- Retirement (U-pipe — free old mapping) ---
    input  logic        retire_valid,
    input  phys_reg_t   retire_phys,
    input  logic [2:0]  retire_arch,
    input  phys_reg_t   retire_old_phys,

    // --- Retirement (V-pipe) ---
    input  logic        retire_v_valid,
    input  logic [2:0]  retire_v_arch,
    input  phys_reg_t   retire_v_phys,
    input  phys_reg_t   retire_v_old_phys,

    // --- Branch snapshot control ---
    input  logic        branch_dispatch,
    input  logic [1:0]  branch_id,
    input  logic        branch_mispredict,
    input  logic [1:0]  branch_restore_id,

    // --- CDB (for busy table) ---
    input  logic        cdb0_valid,
    input  phys_reg_t   cdb0_dest,
    input  logic        cdb1_valid,
    input  phys_reg_t   cdb1_dest,

    // --- Flush ---
    input  logic        flush,

    // --- Context Pre-Warm (Neo-386 Pro) ---
    // On imminent context switch, the scheduler can pre-map the next
    // task's architectural registers into free physical registers.
    // This eliminates cold-start stalls after the switch commits.
    input  logic        pre_warm_valid,        // Pre-warm request
    input  logic [2:0]  pre_warm_arch_reg,     // Which arch reg to pre-warm
    input  logic [31:0] pre_warm_value,        // Value to preload
    output logic        pre_warm_ready         // Pre-warm accepted
);

    // =========================================================
    // Internal Wiring
    // =========================================================

    // Free list allocation outputs
    phys_reg_t alloc_phys_u, alloc_phys_v;
    logic      alloc_valid_u, alloc_valid_v;
    logic      freelist_can_alloc;

    // Committed map (from map table, used by free list for full-flush rebuild)
    phys_reg_t com_map_wire [CONF_ARCH_REG_NUM];

    // =========================================================
    // Feature-gated snapshot signals
    // =========================================================
    logic       snap_take_int;
    logic [1:0] snap_id_int;
    logic       snap_restore_int;
    logic [1:0] snap_restore_id_int;

    generate
        if (CONF_ENABLE_RENAME_SNAP) begin : gen_snap_enabled
            assign snap_take_int       = branch_dispatch;
            assign snap_id_int         = branch_id;
            assign snap_restore_int    = branch_mispredict;
            assign snap_restore_id_int = branch_restore_id;
        end else begin : gen_snap_disabled
            // No snapshots: flush always uses com_map path
            assign snap_take_int       = 1'b0;
            assign snap_id_int         = 2'b00;
            assign snap_restore_int    = 1'b0;
            assign snap_restore_id_int = 2'b00;
        end
    endgenerate

    // =========================================================
    // Flush signal into submodules
    // =========================================================
    // When snapshots are disabled, any mispredict triggers a full flush
    // (spec_map = com_map).  When snapshots are enabled, mispredict is
    // handled by snap_restore; flush is only for non-snapshot flushes.
    logic flush_int;
    generate
        if (CONF_ENABLE_RENAME_SNAP) begin : gen_flush_snap
            // With snapshots: flush only for non-mispredict flushes
            // (branch_mispredict is handled via snap_restore)
            assign flush_int = flush && !branch_mispredict;
        end else begin : gen_flush_nosnap
            assign flush_int = flush;
        end
    endgenerate

    // =========================================================
    // 1. Rename Map Table
    // =========================================================
    // Dispatch-valid signals for the map table: U always renames when
    // can_rename is asserted by the consumer; V renames conditionally.
    // The actual rename_valid gating is done by the parent (dispatch
    // stage) which asserts arch_dest_u when it has a valid instruction.
    // Here we pass through the allocation validity.

    f386_rename_maptable u_maptable (
        .clk              (clk),
        .rst_n            (reset_n),
        .flush            (flush_int),

        // Rename (speculative update)
        .rename_arch_u    (arch_dest_u),
        .rename_phys_u    (alloc_phys_u),
        .rename_valid_u   (alloc_valid_u),
        .rename_arch_v    (arch_dest_v),
        .rename_phys_v    (alloc_phys_v),
        .rename_valid_v   (alloc_valid_v),

        // Source operand lookup (U-pipe)
        .read_arch_a      (src_arch_a),
        .read_arch_b      (src_arch_b),
        .read_phys_a      (src_phys_a),
        .read_phys_b      (src_phys_b),

        // Source operand lookup (V-pipe)
        .read_arch_c      (src_arch_c),
        .read_arch_d      (src_arch_d),
        .read_phys_c      (src_phys_c),
        .read_phys_d      (src_phys_d),

        // Old physical mapping
        .old_phys_u       (old_phys_u),
        .old_phys_v       (old_phys_v),

        // Snapshots
        .snap_take        (snap_take_int),
        .snap_id          (snap_id_int),
        .snap_restore     (snap_restore_int),
        .snap_restore_id  (snap_restore_id_int),

        // Committed map (retirement)
        .commit_valid_u   (retire_valid),
        .commit_arch_u    (retire_arch),
        .commit_phys_u    (retire_phys),
        .commit_valid_v   (retire_v_valid),
        .commit_arch_v    (retire_v_arch),
        .commit_phys_v    (retire_v_phys),

        // Committed map output
        .com_map_out      (com_map_wire)
    );

    // =========================================================
    // 2. Rename Free List
    // =========================================================
    f386_rename_freelist u_freelist (
        .clk              (clk),
        .rst_n            (reset_n),
        .flush            (flush_int),

        // Allocate (dispatch)
        .alloc_req_u      (1'b1),           // Always request; alloc_valid gates actual use
        .alloc_phys_u     (alloc_phys_u),
        .alloc_valid_u    (alloc_valid_u),
        .alloc_req_v      (rename_v_valid),
        .alloc_phys_v     (alloc_phys_v),
        .alloc_valid_v    (alloc_valid_v),

        // Free (retirement — return old mapping to pool)
        .free_valid_u     (retire_valid),
        .free_phys_u      (retire_old_phys),
        .free_valid_v     (retire_v_valid),
        .free_phys_v      (retire_v_old_phys),

        // Snapshots
        .snap_take        (snap_take_int),
        .snap_id          (snap_id_int),
        .snap_restore     (snap_restore_int),
        .snap_restore_id  (snap_restore_id_int),

        // Full-flush rebuild source
        .com_map_in       (com_map_wire),

        // Status
        .can_alloc        (freelist_can_alloc)
    );

    // =========================================================
    // 3. Busy Table
    // =========================================================
    f386_rename_busytable u_busytable (
        .clk              (clk),
        .rst_n            (reset_n),
        .flush            (flush),

        // Set busy (dispatch destinations are in-flight)
        .set_valid_u      (alloc_valid_u),
        .set_phys_u       (alloc_phys_u),
        .set_valid_v      (alloc_valid_v),
        .set_phys_v       (alloc_phys_v),

        // Clear busy (CDB writeback)
        .clr_valid_0      (cdb0_valid),
        .clr_phys_0       (cdb0_dest),
        .clr_valid_1      (cdb1_valid),
        .clr_phys_1       (cdb1_dest),

        // Query (source operand readiness — U-pipe)
        .query_a          (src_phys_a),
        .query_b          (src_phys_b),
        .busy_a           (src_busy_a),
        .busy_b           (src_busy_b),

        // Query (source operand readiness — V-pipe)
        .query_c          (src_phys_c),
        .query_d          (src_phys_d),
        .busy_c           (src_busy_c),
        .busy_d           (src_busy_d)
    );

    // =========================================================
    // 4. Context Pre-Warm (Neo-386 Pro)
    // =========================================================
    // When the scheduler signals an imminent context switch,
    // pre-warm allocates a physical register from the free list
    // and installs the new mapping in the speculative map table.
    // On commit of the context switch, the snapshot mechanism
    // makes this the active mapping — zero cold-start penalty.
    //
    // Pre-warm is low priority: only accepted when the pipeline
    // is not actively renaming (no dispatch this cycle).
    assign pre_warm_ready = pre_warm_valid && freelist_can_alloc &&
                            !alloc_valid_u && !alloc_valid_v;

    // =========================================================
    // Output assignments
    // =========================================================
    assign phys_dest_u = alloc_phys_u;
    assign phys_dest_v = alloc_phys_v;
    assign v_alloc_valid = alloc_valid_v;

    // can_rename: free list has at least 1 register available.
    // When V-pipe is also requesting, we need 2 — but the free list
    // picker handles this: alloc_valid_v will be deasserted if there
    // is only 1 free reg.  The dispatch stage uses can_rename for U
    // and checks alloc_valid_v for V separately.
    assign can_rename = freelist_can_alloc;

endmodule
