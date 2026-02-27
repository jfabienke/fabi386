/*
 * fabi386: Gshare Branch Predictor
 * Phase 7: Advanced Front-end
 * Uses an 8-bit Global History Register (GHR) XORed with PC[9:2]
 * to index a 256-entry Pattern History Table (PHT).
 */

import f386_pkg::*;

module f386_branch_predict_gshare (
    input  logic         clk,
    input  logic         reset_n,

    // Fetch Stage Interface
    input  logic [31:0]  fetch_pc,
    output logic         predict_taken,

    // Feedback from Resolution (Execution/Commit)
    input  logic         res_valid,
    input  logic [31:0]  res_pc,
    input  logic         res_actually_taken
);

    // 8-bit Global History Register
    logic [7:0] ghr;

    // Pattern History Table (2-bit saturating counters)
    logic [1:0] pht [255:0];

    // XOR Indexing (Gshare)
    wire [7:0] fetch_idx = fetch_pc[9:2] ^ ghr;
    wire [7:0] res_idx   = res_pc[9:2] ^ ghr;

    // Asynchronous Prediction
    assign predict_taken = pht[fetch_idx][1];

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ghr <= 8'h00;
            for (int i = 0; i < 256; i++) pht[i] <= 2'b01; // Weakly Not Taken
        end else if (res_valid) begin
            // Update Global History (Shift in the actual outcome)
            ghr <= {ghr[6:0], res_actually_taken};

            // Update Pattern History Table
            case (pht[res_idx])
                2'b00: pht[res_idx] <= res_actually_taken ? 2'b01 : 2'b00;
                2'b01: pht[res_idx] <= res_actually_taken ? 2'b10 : 2'b00;
                2'b10: pht[res_idx] <= res_actually_taken ? 2'b11 : 2'b01;
                2'b11: pht[res_idx] <= res_actually_taken ? 2'b11 : 2'b10;
            endcase
        end
    end

endmodule
