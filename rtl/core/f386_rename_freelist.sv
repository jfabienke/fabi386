/*
 * fabi386: Rename Free List with Checkpoint Support
 * ---------------------------------------------------
 * Bitmap-based free list tracking which of the 32 physical registers
 * are available for allocation.  Uses f386_picker for lowest-free-bit
 * selection (2-wide: U-pipe and V-pipe).
 *
 * Snapshot protocol (matches map table):
 *   snap_take     — save free_map at branch dispatch
 *   snap_restore  — restore free_map on mispredict
 *   flush w/o restore — rebuild free_map from committed map (all regs
 *                        not in com_map are marked free)
 *
 * Registers 0-7 are reserved for the architectural identity mapping
 * and are never placed into the free pool at reset.
 *
 * Reference: BOOM rename-freelist.scala, rsd RenameLogic.sv
 */

import f386_pkg::*;

module f386_rename_freelist (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,

    // --- Allocate (dispatch) ---
    input  logic        alloc_req_u,
    output phys_reg_t   alloc_phys_u,
    output logic        alloc_valid_u,
    input  logic        alloc_req_v,
    output phys_reg_t   alloc_phys_v,
    output logic        alloc_valid_v,

    // --- Free (retirement — return old mapping) ---
    input  logic        free_valid_u,
    input  phys_reg_t   free_phys_u,
    input  logic        free_valid_v,
    input  phys_reg_t   free_phys_v,

    // --- Snapshot for branch recovery ---
    input  logic        snap_take,
    input  logic [1:0]  snap_id,
    input  logic        snap_restore,
    input  logic [1:0]  snap_restore_id,

    // --- Full-flush rebuild from committed map ---
    input  phys_reg_t   com_map_in [CONF_ARCH_REG_NUM],

    // --- Status ---
    output logic        can_alloc           // At least 1 free register available
);

    localparam int N = CONF_PHYS_REG_NUM;   // 32
    localparam int R = CONF_ARCH_REG_NUM;   // 8

    // Bitmap: 1 = free, 0 = allocated
    // Initial: bits [31:8] free, bits [7:0] reserved (arch identity)
    localparam logic [N-1:0] INIT_MAP = {{(N-R){1'b1}}, {R{1'b0}}};

    logic [N-1:0] free_map;
    logic [N-1:0] snap_map [CONF_MAX_BR_COUNT];

    // =========================================================
    // Picker: find 2 free registers (lowest-bit priority)
    // =========================================================
    logic [N-1:0]           pick_grant [2];
    logic [PHYS_REG_WIDTH-1:0] pick_idx  [2];
    logic                   pick_valid [2];

    f386_picker #(
        .WIDTH    (N),
        .NUM_PICK (2)
    ) u_picker (
        .request   (free_map),
        .grant     (pick_grant),
        .grant_idx (pick_idx),
        .valid     (pick_valid)
    );

    // =========================================================
    // Allocation outputs (combinational)
    // =========================================================
    assign alloc_phys_u  = pick_idx[0];
    assign alloc_valid_u = alloc_req_u & pick_valid[0];
    assign alloc_phys_v  = pick_idx[1];
    assign alloc_valid_v = alloc_req_v & pick_valid[1];

    // Can allocate if at least the first picker slot found a free reg
    assign can_alloc = pick_valid[0];

    // =========================================================
    // Full-flush rebuild: mark everything NOT in com_map as free
    // =========================================================
    logic [N-1:0] rebuild_map;
    always_comb begin
        rebuild_map = {N{1'b1}};  // Start with all free
        for (int i = 0; i < R; i++)
            rebuild_map[com_map_in[i]] = 1'b0;  // Mark committed mappings as allocated
    end

    // =========================================================
    // Free map update
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            free_map <= INIT_MAP;
        end else if (snap_restore) begin
            free_map <= snap_map[snap_restore_id];
        end else if (flush) begin
            // Full flush: rebuild from committed map
            free_map <= rebuild_map;
        end else begin
            // Allocations (clear bits — register is now in use)
            if (alloc_valid_u)
                free_map[alloc_phys_u] <= 1'b0;
            if (alloc_valid_v)
                free_map[alloc_phys_v] <= 1'b0;
            // Frees (set bits — old mapping returned to pool)
            // Free takes priority over alloc on same-register conflict
            if (free_valid_u)
                free_map[free_phys_u] <= 1'b1;
            if (free_valid_v)
                free_map[free_phys_v] <= 1'b1;
        end
    end

    // =========================================================
    // Snapshot capture
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < CONF_MAX_BR_COUNT; s++)
                snap_map[s] <= INIT_MAP;
        end else if (snap_take) begin
            // Capture free_map after this cycle's allocations
            snap_map[snap_id] <= free_map;
            // Apply in-flight allocations to the snapshot
            if (alloc_valid_u)
                snap_map[snap_id][alloc_phys_u] <= 1'b0;
            if (alloc_valid_v)
                snap_map[snap_id][alloc_phys_v] <= 1'b0;
        end
    end

endmodule
