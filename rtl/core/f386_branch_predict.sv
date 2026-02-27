/*
 * fabi386: 2-bit Bimodal Branch Predictor
 * Phase 4: Reduces pipeline stalls by predicting branch outcomes.
 * Uses a Pattern History Table (PHT) indexed by PC[9:2].
 */

import f386_pkg::*;

module f386_branch_predict (
    input  logic         clk,
    input  logic         reset_n,

    // Fetch Stage Interface
    input  logic [31:0]  fetch_pc,
    output logic         predict_taken,

    // Feedback from Execution Stage (Resolution)
    input  logic         res_valid,
    input  logic [31:0]  res_pc,
    input  logic         res_actually_taken
);

    // Pattern History Table: 256 entries x 2 bits
    // 00: Strongly Not Taken
    // 01: Weakly Not Taken
    // 10: Weakly Taken
    // 11: Strongly Taken
    logic [1:0] pht [255:0];

    // Indexing logic
    wire [7:0] fetch_idx = fetch_pc[9:2];
    wire [7:0] res_idx   = res_pc[9:2];

    // Prediction (Asynchronous)
    assign predict_taken = pht[fetch_idx][1]; // Bit 1 is the prediction

    // Update Logic
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (int i = 0; i < 256; i++) pht[i] <= 2'b01; // Initialize to Weakly Not Taken
        end else if (res_valid) begin
            case (pht[res_idx])
                2'b00: pht[res_idx] <= res_actually_taken ? 2'b01 : 2'b00;
                2'b01: pht[res_idx] <= res_actually_taken ? 2'b10 : 2'b00;
                2'b10: pht[res_idx] <= res_actually_taken ? 2'b11 : 2'b01;
                2'b11: pht[res_idx] <= res_actually_taken ? 2'b11 : 2'b10;
            endcase
        end
    end

endmodule
