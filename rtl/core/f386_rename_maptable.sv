/*
 * fabi386: Rename Map Table with Snapshots
 * -----------------------------------------
 * Maps 8 architectural registers (x86 GPRs EAX-EDI) to 32 physical
 * registers.  Maintains a speculative map (updated at dispatch), a
 * committed map (updated at retirement), and up to 4 branch snapshots
 * for fast mispredict recovery.
 *
 * Snapshot protocol (BOOM rename-maptable pattern):
 *   snap_take     — capture spec_map into snap[snap_id] at branch dispatch
 *   snap_restore  — restore spec_map from snap[snap_restore_id] on mispredict
 *   flush w/o snap_restore — restore spec_map from com_map (full flush)
 *
 * Reference: BOOM rename-maptable.scala, rsd RenameLogic.sv
 */

import f386_pkg::*;

module f386_rename_maptable (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,

    // --- Rename port (dispatch-time speculative update) ---
    input  logic [2:0]  rename_arch_u,      // U-pipe arch dest
    input  phys_reg_t   rename_phys_u,      // New phys reg for U-pipe dest
    input  logic        rename_valid_u,
    input  logic [2:0]  rename_arch_v,      // V-pipe arch dest
    input  phys_reg_t   rename_phys_v,
    input  logic        rename_valid_v,

    // --- Read ports (source operand lookup at dispatch) ---
    input  logic [2:0]  read_arch_a,        // U-pipe source A arch reg
    input  logic [2:0]  read_arch_b,        // U-pipe source B arch reg
    output phys_reg_t   read_phys_a,        // Current phys mapping for A
    output phys_reg_t   read_phys_b,        // Current phys mapping for B
    input  logic [2:0]  read_arch_c,        // V-pipe source A arch reg
    input  logic [2:0]  read_arch_d,        // V-pipe source B arch reg
    output phys_reg_t   read_phys_c,
    output phys_reg_t   read_phys_d,

    // --- Old physical mapping (pre-rename, for freelist reclaim) ---
    output phys_reg_t   old_phys_u,
    output phys_reg_t   old_phys_v,

    // --- Snapshot control ---
    input  logic        snap_take,          // Take snapshot (branch dispatch)
    input  logic [1:0]  snap_id,            // Which snapshot slot (0-3)
    input  logic        snap_restore,       // Restore snapshot (mispredict)
    input  logic [1:0]  snap_restore_id,

    // --- Committed map update (retirement) ---
    input  logic        commit_valid_u,
    input  logic [2:0]  commit_arch_u,
    input  phys_reg_t   commit_phys_u,
    input  logic        commit_valid_v,
    input  logic [2:0]  commit_arch_v,
    input  phys_reg_t   commit_phys_v,

    // --- Committed map read (for full-flush restore) ---
    output phys_reg_t   com_map_out [CONF_ARCH_REG_NUM]
);

    // =========================================================
    // Storage
    // =========================================================
    phys_reg_t spec_map [CONF_ARCH_REG_NUM];   // Speculative map
    phys_reg_t com_map  [CONF_ARCH_REG_NUM];   // Committed map
    phys_reg_t snap     [CONF_MAX_BR_COUNT][CONF_ARCH_REG_NUM];  // Snapshots

    // =========================================================
    // Combinational read ports with same-cycle rename bypass
    // =========================================================
    // U-pipe sources (a,b) read the PRE-rename mapping — no bypass.
    // If U renames EAX and reads EAX (ADD EAX,1), the source must see
    // the OLD physical register, not the newly-allocated destination.
    //
    // V-pipe sources (c,d) bypass U's rename only — V is younger
    // and may read a register that U just renamed.  V does NOT see
    // its own rename (sources always read pre-rename for own slot).
    always_comb begin
        // U-pipe sources: pre-rename mapping only
        read_phys_a = spec_map[read_arch_a];
        read_phys_b = spec_map[read_arch_b];

        // V-pipe sources: bypass U rename (V reads U's new mapping)
        read_phys_c = spec_map[read_arch_c];
        read_phys_d = spec_map[read_arch_d];
        if (rename_valid_u && rename_arch_u == read_arch_c)
            read_phys_c = rename_phys_u;
        if (rename_valid_u && rename_arch_u == read_arch_d)
            read_phys_d = rename_phys_u;

    end

    // Old physical mapping: pre-rename value for freelist reclaim at retirement
    assign old_phys_u = spec_map[rename_arch_u];
    assign old_phys_v = (rename_valid_u && rename_arch_u == rename_arch_v)
                        ? rename_phys_u : spec_map[rename_arch_v];

    // =========================================================
    // Committed map output (for external full-flush rebuild)
    // =========================================================
    genvar i;
    generate
        for (i = 0; i < CONF_ARCH_REG_NUM; i++) begin : gen_com_out
            assign com_map_out[i] = com_map[i];
        end
    endgenerate

    // =========================================================
    // Speculative map update
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < CONF_ARCH_REG_NUM; i++)
                spec_map[i] <= phys_reg_t'(i);
        end else if (snap_restore) begin
            // Mispredict: restore from branch snapshot
            for (int i = 0; i < CONF_ARCH_REG_NUM; i++)
                spec_map[i] <= snap[snap_restore_id][i];
        end else if (flush) begin
            // Full flush (no valid snapshot): fall back to committed map
            for (int i = 0; i < CONF_ARCH_REG_NUM; i++)
                spec_map[i] <= com_map[i];
        end else begin
            // Normal dispatch rename
            if (rename_valid_u)
                spec_map[rename_arch_u] <= rename_phys_u;
            if (rename_valid_v)
                spec_map[rename_arch_v] <= rename_phys_v;
        end
    end

    // =========================================================
    // Snapshot capture
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < CONF_MAX_BR_COUNT; s++)
                for (int i = 0; i < CONF_ARCH_REG_NUM; i++)
                    snap[s][i] <= phys_reg_t'(i);
        end else if (snap_take) begin
            // Capture current spec_map (after this cycle's renames apply)
            for (int i = 0; i < CONF_ARCH_REG_NUM; i++) begin
                // Apply in-flight renames to the snapshot so the snapshot
                // reflects the state AFTER the branch's rename cycle.
                if (rename_valid_v && rename_arch_v == i[2:0])
                    snap[snap_id][i] <= rename_phys_v;
                else if (rename_valid_u && rename_arch_u == i[2:0])
                    snap[snap_id][i] <= rename_phys_u;
                else
                    snap[snap_id][i] <= spec_map[i];
            end
        end
    end

    // =========================================================
    // Committed map update (retirement — in-order)
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < CONF_ARCH_REG_NUM; i++)
                com_map[i] <= phys_reg_t'(i);
        end else begin
            if (commit_valid_u)
                com_map[commit_arch_u] <= commit_phys_u;
            if (commit_valid_v)
                com_map[commit_arch_v] <= commit_phys_v;
        end
    end

endmodule
