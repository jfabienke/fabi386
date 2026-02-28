/*
 * fabi386: Memory Dependency Predictor (MDT)
 * -------------------------------------------
 * Simple PC-indexed 1-bit memory dependence predictor.
 * Predicts whether a load will conflict with an older in-flight store,
 * allowing the LSQ to conservatively stall loads that are likely to
 * need store-to-load forwarding.
 *
 * When a load is replayed due to a memory ordering violation (the load
 * executed before a matching store's address was known), the predictor
 * is trained to mark that PC as "dependent".  Future loads from the
 * same PC will wait until all older store addresses are known.
 *
 * 128 entries, direct-mapped, indexed by load PC[8:2] (word-aligned).
 * 1-bit counter: 0 = predict independent (speculate), 1 = predict dependent (wait).
 *
 * Reference: BOOM MemoryDependencyPredictor, rsd MemoryDependencyPredictor.sv
 */

import f386_pkg::*;

module f386_mem_dep_predictor (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,

    // --- Prediction query (at load dispatch) ---
    input  logic [31:0] query_pc,
    output logic        predict_dependent,   // 1 = wait for stores, 0 = speculate

    // --- Training (on memory ordering violation) ---
    input  logic        train_valid,
    input  logic [31:0] train_pc,            // PC of the replayed load
    input  logic        train_dependent      // 1 = was dependent, 0 = was independent
);

    localparam int MDT_ENTRIES = 128;
    localparam int MDT_IDX_W  = $clog2(MDT_ENTRIES);  // 7

    // 1-bit predictor entries: 0 = independent, 1 = dependent
    logic [MDT_ENTRIES-1:0] mdt_table;

    // Index extraction: PC[8:2] (skip byte offset, word-aligned)
    wire [MDT_IDX_W-1:0] query_idx = query_pc[MDT_IDX_W+1:2];
    wire [MDT_IDX_W-1:0] train_idx = train_pc[MDT_IDX_W+1:2];

    // Combinational prediction
    assign predict_dependent = mdt_table[query_idx];

    // Training update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mdt_table <= '0;  // Start optimistic: predict independent
        end else if (flush) begin
            mdt_table <= '0;
        end else if (train_valid) begin
            mdt_table[train_idx] <= train_dependent;
        end
    end

endmodule
