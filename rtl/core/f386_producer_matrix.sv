/*
 * fabi386: Producer Matrix (Dependency Matrix)
 * ---------------------------------------------
 * NxN dependency matrix where N = CONF_IQ_ENTRIES (8).
 * Entry matrix[i][j] = 1 means IQ entry i depends on IQ entry j
 * (j produces a value that i needs).
 *
 * When j completes (CDB broadcast), column j is cleared across all
 * rows, waking up entries whose last dependency was j.
 *
 * Reference: rsd/Processor/Src/Scheduler/ProducerMatrix.sv
 *
 * Fmax note: Wake signals are registered before use (1-cycle wakeup
 * latency). The matrix update is purely combinational on the registered
 * wake/alloc inputs.
 *
 * Feature-gated by CONF_ENABLE_PRODUCER_MTX.
 */

import f386_pkg::*;

module f386_producer_matrix (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,

    // Dispatch: allocate a new IQ entry
    input  logic        alloc_valid,
    input  logic [$clog2(CONF_IQ_ENTRIES)-1:0] alloc_idx,   // Which IQ slot
    input  logic [CONF_IQ_ENTRIES-1:0]         alloc_deps,  // Dependency vector

    // Wakeup: CDB completion clears a column
    input  logic        wake0_valid,
    input  logic [$clog2(CONF_IQ_ENTRIES)-1:0] wake0_idx,   // Which IQ entry completed
    input  logic        wake1_valid,
    input  logic [$clog2(CONF_IQ_ENTRIES)-1:0] wake1_idx,

    // Ready vector output
    output logic [CONF_IQ_ENTRIES-1:0] ready_vec  // Entry i ready when row i == 0
);

    localparam int N = CONF_IQ_ENTRIES;

    // The NxN dependency matrix: matrix[i] is the dependency vector for IQ entry i
    logic [N-1:0] matrix [N];

    // Entry validity tracking (set on alloc, cleared on wake/flush)
    logic [N-1:0] entry_valid;

    // Registered wake signals for Fmax (1-cycle wakeup latency)
    logic        wake0_valid_r, wake1_valid_r;
    logic [$clog2(N)-1:0] wake0_idx_r, wake1_idx_r;

    // Register wake inputs
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wake0_valid_r <= 1'b0;
            wake1_valid_r <= 1'b0;
            wake0_idx_r   <= '0;
            wake1_idx_r   <= '0;
        end else if (flush) begin
            wake0_valid_r <= 1'b0;
            wake1_valid_r <= 1'b0;
        end else begin
            wake0_valid_r <= wake0_valid;
            wake0_idx_r   <= wake0_idx;
            wake1_valid_r <= wake1_valid;
            wake1_idx_r   <= wake1_idx;
        end
    end

    // Column-clear mask from registered wakeup signals
    logic [N-1:0] wake_clear_mask;

    always_comb begin
        wake_clear_mask = '0;
        if (wake0_valid_r) wake_clear_mask[wake0_idx_r] = 1'b1;
        if (wake1_valid_r) wake_clear_mask[wake1_idx_r] = 1'b1;
    end

    // Matrix and validity update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            entry_valid <= '0;
            for (int i = 0; i < N; i++)
                matrix[i] <= '0;
        end else if (flush) begin
            entry_valid <= '0;
            for (int i = 0; i < N; i++)
                matrix[i] <= '0;
        end else begin
            // Step 1: Clear woken columns across all rows
            for (int i = 0; i < N; i++) begin
                matrix[i] <= matrix[i] & ~wake_clear_mask;
            end

            // Step 2: Clear validity for woken entries (they have issued)
            if (wake0_valid_r) entry_valid[wake0_idx_r] <= 1'b0;
            if (wake1_valid_r) entry_valid[wake1_idx_r] <= 1'b0;

            // Step 3: Allocate new entry (overwrites any column-clear on that row)
            if (alloc_valid) begin
                matrix[alloc_idx] <= alloc_deps;
                entry_valid[alloc_idx] <= 1'b1;
            end
        end
    end

    // Ready vector: entry i is ready when its dependency row is all zeros
    // and the entry is valid (has been allocated and not yet issued)
    always_comb begin
        for (int i = 0; i < N; i++) begin
            ready_vec[i] = entry_valid[i] && (matrix[i] == '0);
        end
    end

endmodule
