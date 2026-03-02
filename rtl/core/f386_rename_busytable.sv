/*
 * fabi386: Rename Busy Table
 * ---------------------------
 * Tracks which physical registers have pending writes (in-flight,
 * not yet completed via CDB writeback).  Used by the issue queue
 * to determine operand readiness at dispatch time.
 *
 * Priority ordering for same-cycle conflicts:
 *   1. CDB clears (older instruction completing)
 *   2. Dispatch sets (new instruction destination is in-flight)
 *   If both CDB and dispatch target the SAME register, the dispatch
 *   wins because the CDB completed the OLD mapping while dispatch is
 *   allocating the register for a NEW instruction.
 *
 * Query ports provide combinational read with bypass for same-cycle
 * CDB clears (a source reading a register that CDB just completed
 * sees it as not-busy).
 */

import f386_pkg::*;

module f386_rename_busytable (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,

    // --- Set busy (dispatch — destination is in-flight) ---
    input  logic        set_valid_u,
    input  phys_reg_t   set_phys_u,
    input  logic        set_valid_v,
    input  phys_reg_t   set_phys_v,

    // --- Clear busy (CDB writeback — result is available) ---
    input  logic        clr_valid_0,
    input  phys_reg_t   clr_phys_0,
    input  logic        clr_valid_1,
    input  phys_reg_t   clr_phys_1,

    // --- Query (combinational read) ---
    input  phys_reg_t   query_a,
    input  phys_reg_t   query_b,
    output logic        busy_a,
    output logic        busy_b,

    // --- V-pipe query ports ---
    input  phys_reg_t   query_c,
    input  phys_reg_t   query_d,
    output logic        busy_c,
    output logic        busy_d
);

    logic [CONF_PHYS_REG_NUM-1:0] busy;
    logic [CONF_PHYS_REG_NUM-1:0] busy_next;

    // =========================================================
    // Next-state computation (single-cycle update ordering)
    // =========================================================
    always_comb begin
        busy_next = busy;

        // Step 1: CDB clears (mark completed registers as ready)
        if (clr_valid_0) busy_next[clr_phys_0] = 1'b0;
        if (clr_valid_1) busy_next[clr_phys_1] = 1'b0;

        // Step 2: Dispatch sets (new destinations are in-flight)
        // Dispatch wins on same-cycle conflict with CDB
        if (set_valid_u) busy_next[set_phys_u] = 1'b1;
        if (set_valid_v) busy_next[set_phys_v] = 1'b1;
    end

    // =========================================================
    // Registered state
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            busy <= {CONF_PHYS_REG_NUM{1'b0}};
        else if (flush)
            busy <= {CONF_PHYS_REG_NUM{1'b0}};
        else
            busy <= busy_next;
    end

    // =========================================================
    // Query: combinational read with CDB bypass
    // =========================================================
    // Sources reading a register that CDB just cleared this cycle
    // should see it as not-busy.  We read through busy_next which
    // already incorporates CDB clears (and dispatch sets).
    assign busy_a = busy_next[query_a];
    assign busy_b = busy_next[query_b];
    assign busy_c = busy_next[query_c];
    assign busy_d = busy_next[query_d];

endmodule
