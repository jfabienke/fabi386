/*
 * fabi386: Dual-Mode Hardware Shadow Stack (v1.0)
 * --------------------------------------------------
 * Dedicated LIFO for CALL/RET validation with isolated
 * Host (Protected Mode) and Guest (V86/Real Mode) stacks.
 *
 * Key features:
 *   - 32-entry shadow stack per mode (Host + Guest)
 *   - Zero-cycle validation at retirement (combinational compare)
 *   - Automatic mode switching on PM ↔ V86 transitions
 *   - Overflow/underflow detection with saturation
 *   - Mismatch counter for security telemetry
 *
 * On CALL: push return address onto active shadow stack
 * On RET:  compare popped shadow entry against actual return address
 *          mismatch → signal to ROB (optionally #GP or telemetry event)
 *
 * Security model:
 *   - Guest (V86) code cannot corrupt Host shadow stack
 *   - Mode switch flushes neither stack (preserves context)
 *   - Speculative pushes tracked via spec_depth; squash restores pointer
 *
 * Resource estimate: ~200 ALMs + 2 M10K blocks
 *
 * Reference: Intel CET Shadow Stack concept, fabi386 Neo-386 Pro analysis
 */

import f386_pkg::*;

module f386_shadow_stack (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,          // Pipeline flush (mispredict)

    // --- Mode Select ---
    input  logic        v86_mode,       // 1 = Guest (V86), 0 = Host (PM)

    // --- Speculative Push (at dispatch) ---
    input  logic        push_valid,     // CALL dispatched
    input  logic [31:0] push_ret_addr,  // Expected return address (PC after CALL)

    // --- Speculative Pop (at dispatch) ---
    input  logic        pop_valid,      // RET dispatched

    // --- Retirement Validation ---
    input  logic        retire_ret_valid,     // RET retiring
    input  logic [31:0] retire_ret_target,    // Actual return target from RET

    // --- Validation Result ---
    output logic        ret_mismatch,         // Shadow stack mismatch
    output logic [31:0] shadow_expected_addr,  // What shadow stack expected

    // --- Speculative Recovery ---
    input  logic        squash_valid,    // Branch mispredict squash
    input  logic [4:0]  squash_depth,    // How many speculative entries to undo

    // --- Telemetry ---
    output logic [7:0]  mismatch_count,  // Rolling mismatch counter
    output logic        stack_overflow,   // Shadow stack overflow
    output logic        stack_underflow   // Shadow stack underflow
);

    localparam int SS_DEPTH = 32;
    localparam int SS_PTR_W = $clog2(SS_DEPTH);

    // =========================================================================
    // Dual Stack Storage (Host + Guest)
    // =========================================================================
    // Using M10K inference for the stacks
    (* ramstyle = "M10K" *) logic [31:0] host_stack  [SS_DEPTH];
    (* ramstyle = "M10K" *) logic [31:0] guest_stack [SS_DEPTH];

    // Per-mode stack pointers (top of stack = next write position)
    logic [SS_PTR_W:0] host_sp;    // Extra bit for overflow detection
    logic [SS_PTR_W:0] guest_sp;

    // Active stack pointer based on mode
    wire [SS_PTR_W:0] active_sp = v86_mode ? guest_sp : host_sp;

    // Stack full/empty
    wire host_full   = host_sp[SS_PTR_W];
    wire host_empty  = (host_sp == '0);
    wire guest_full  = guest_sp[SS_PTR_W];
    wire guest_empty = (guest_sp == '0);

    wire active_full  = v86_mode ? guest_full  : host_full;
    wire active_empty = v86_mode ? guest_empty : host_empty;

    // =========================================================================
    // Speculative Depth Tracking
    // =========================================================================
    // Track net speculative push/pop count for squash recovery
    logic [5:0] spec_depth;  // Signed: positive = net pushes, negative = net pops

    // =========================================================================
    // Shadow Stack Read (for validation)
    // =========================================================================
    // Read from top-of-stack (sp - 1) for RET validation
    wire [SS_PTR_W-1:0] read_addr = active_sp[SS_PTR_W-1:0] - 1'b1;
    logic [31:0] shadow_read;

    always_comb begin
        if (v86_mode)
            shadow_read = guest_stack[read_addr];
        else
            shadow_read = host_stack[read_addr];
    end

    assign shadow_expected_addr = shadow_read;

    // =========================================================================
    // Retirement Validation (combinational — zero extra cycles)
    // =========================================================================
    assign ret_mismatch = retire_ret_valid && !active_empty &&
                          (shadow_read != retire_ret_target);

    // =========================================================================
    // Stack Operations
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            host_sp        <= '0;
            guest_sp       <= '0;
            spec_depth     <= '0;
            mismatch_count <= '0;
            stack_overflow <= 1'b0;
            stack_underflow<= 1'b0;
        end else if (flush) begin
            // On flush: revert speculative pointer changes
            if (v86_mode)
                guest_sp <= guest_sp - {{(SS_PTR_W+1-6){spec_depth[5]}}, spec_depth};
            else
                host_sp  <= host_sp  - {{(SS_PTR_W+1-6){spec_depth[5]}}, spec_depth};
            spec_depth <= '0;
        end else begin
            stack_overflow  <= 1'b0;
            stack_underflow <= 1'b0;

            // Push (CALL dispatch)
            if (push_valid && !active_full) begin
                if (v86_mode) begin
                    guest_stack[guest_sp[SS_PTR_W-1:0]] <= push_ret_addr;
                    guest_sp <= guest_sp + 1'b1;
                end else begin
                    host_stack[host_sp[SS_PTR_W-1:0]] <= push_ret_addr;
                    host_sp <= host_sp + 1'b1;
                end
                spec_depth <= spec_depth + 1'b1;
            end else if (push_valid && active_full) begin
                stack_overflow <= 1'b1;
                // Saturate: don't push, but keep tracking
            end

            // Pop (RET dispatch)
            if (pop_valid && !active_empty) begin
                if (v86_mode)
                    guest_sp <= guest_sp - 1'b1;
                else
                    host_sp  <= host_sp  - 1'b1;
                spec_depth <= spec_depth - 1'b1;
            end else if (pop_valid && active_empty) begin
                stack_underflow <= 1'b1;
            end

            // Squash recovery (from specbits)
            if (squash_valid) begin
                if (v86_mode)
                    guest_sp <= guest_sp - {{(SS_PTR_W+1-5){squash_depth[4]}}, squash_depth};
                else
                    host_sp  <= host_sp  - {{(SS_PTR_W+1-5){squash_depth[4]}}, squash_depth};
                spec_depth <= spec_depth - {squash_depth[4], squash_depth};
            end

            // Mismatch counting (at retirement)
            if (ret_mismatch && mismatch_count != 8'hFF)
                mismatch_count <= mismatch_count + 1'b1;
        end
    end

endmodule
