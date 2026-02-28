/*
 * fabi386: Ready Bit Table
 * ------------------------
 * Tracks per-physical-register readiness for the OoO wakeup system.
 * One bit per phys reg (32 bits total, indexed by phys_reg_t).
 *
 * - CDB broadcast marks a destination register as ready.
 * - Dispatch clears the destination register (in-flight, not yet ready).
 * - Same-cycle conflict: dispatch wins over CDB (the new instruction's
 *   destination is not yet produced; the CDB result was for the OLD
 *   mapping of that physical register).
 * - On reset/flush: all bits = 1 (architectural regs ready; free-list
 *   regs don't matter until allocated).
 *
 * Feature-gated by CONF_ENABLE_PRODUCER_MTX.
 */

import f386_pkg::*;

module f386_ready_bit_table (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,

    // CDB broadcast (marks registers ready)
    input  logic        cdb0_valid,
    input  phys_reg_t   cdb0_dest,
    input  logic        cdb1_valid,
    input  phys_reg_t   cdb1_dest,

    // Dispatch (marks destination not-ready)
    input  logic        dispatch_u_valid,
    input  phys_reg_t   dispatch_u_dest,
    input  logic        dispatch_v_valid,
    input  phys_reg_t   dispatch_v_dest,

    // Query ports (combinational read)
    input  phys_reg_t   query_a,
    input  phys_reg_t   query_b,
    output logic        ready_a,
    output logic        ready_b
);

    // One ready bit per physical register
    logic [CONF_PHYS_REG_NUM-1:0] ready_bits;

    // Combinational next-state for single-cycle update ordering
    logic [CONF_PHYS_REG_NUM-1:0] ready_bits_next;

    always_comb begin
        ready_bits_next = ready_bits;

        // Step 1: CDB broadcast sets ready
        if (cdb0_valid) ready_bits_next[cdb0_dest] = 1'b1;
        if (cdb1_valid) ready_bits_next[cdb1_dest] = 1'b1;

        // Step 2: Dispatch clears ready (dispatch wins on same-cycle conflict)
        if (dispatch_u_valid) ready_bits_next[dispatch_u_dest] = 1'b0;
        if (dispatch_v_valid) ready_bits_next[dispatch_v_dest] = 1'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ready_bits <= {CONF_PHYS_REG_NUM{1'b1}};
        else if (flush)
            ready_bits <= {CONF_PHYS_REG_NUM{1'b1}};
        else
            ready_bits <= ready_bits_next;
    end

    // Combinational query: read through the next-state for bypass
    // (allows same-cycle CDB → IQ allocation to see updated readiness)
    assign ready_a = ready_bits_next[query_a];
    assign ready_b = ready_bits_next[query_b];

endmodule
