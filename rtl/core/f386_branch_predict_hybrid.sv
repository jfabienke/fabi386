/*
 * fabi386: Hybrid Branch Predictor
 * Phase 7 Final: Combines Gshare for conditional jumps
 * with RAS for function returns.
 */

import f386_pkg::*;

module f386_branch_predict_hybrid (
    input  logic         clk,
    input  logic         reset_n,

    // Fetch Stage Interface
    input  logic [31:0]  fetch_pc,
    input  logic         is_ret_op,      // From BTB / Instruction Cache tags
    output logic [31:0]  next_pc_pred,
    output logic         predict_taken,

    // Feedback from Decode (Function Detector)
    input  logic         dec_is_call,
    input  logic [31:0]  dec_ret_addr,
    input  logic         dec_is_ret,

    // Feedback from Resolution (Execution/Commit)
    input  logic         res_valid,
    input  logic [31:0]  res_pc,
    input  logic         res_actually_taken,
    input  logic         res_is_mispredict,
    input  logic [CONF_GHR_WIDTH-1:0] res_ghr_snap,

    // Snapshot to enqueue into FTQ with each fetch block
    output logic [CONF_GHR_WIDTH-1:0] ghr_snapshot
);

    // 1. Gshare Component (Conditional logic)
    logic gshare_taken;
    f386_branch_predict_gshare gshare_inst (
        .clk(clk), .reset_n(reset_n),
        .fetch_pc(fetch_pc),
        .predict_taken(gshare_taken),
        .res_valid(res_valid),
        .res_pc(res_pc),
        .res_actually_taken(res_actually_taken),
        .res_ghr_snap(res_ghr_snap),
        .ghr_snapshot(ghr_snapshot)
    );

    // 2. RAS Component (Function returns)
    logic [31:0] ras_target;
    logic        ras_ready;
    f386_ras_unit ras_inst (
        .clk(clk), .reset_n(reset_n),
        .is_call(dec_is_call),
        .call_ret_pc(dec_ret_addr),
        .is_ret(dec_is_ret),
        .predicted_ret_pc(ras_target),
        .ras_valid(ras_ready),
        .flush(res_is_mispredict),
        .correct_sp_ptr(5'd0) // Simplified recovery
    );

    // 3. Selection Mux
    always_comb begin
        if (is_ret_op && ras_ready) begin
            predict_taken = 1'b1;
            next_pc_pred  = ras_target;
        end else begin
            predict_taken = gshare_taken;
            next_pc_pred  = fetch_pc + 32'd4; // Default linear path
        end
    end

endmodule
