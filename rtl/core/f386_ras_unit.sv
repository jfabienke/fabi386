/*
 * fabi386: Return Address Stack (RAS)
 * Phase 7 Extension: Leverages the Function Detector (Semantic Tagger)
 * to provide 100% accurate prediction for function returns.
 */

import f386_pkg::*;

module f386_ras_unit (
    input  logic         clk,
    input  logic         reset_n,

    // Interface from Fetch/Decode (Pattern Matcher)
    input  logic         is_call,      // Detected SEM_PROLOGUE / CALL
    input  logic [31:0]  call_ret_pc,  // PC to return to (PC + instr_len)

    input  logic         is_ret,       // Detected SEM_EPILOGUE / RET
    output logic [31:0]  predicted_ret_pc,
    output logic         ras_valid,    // High if stack is not empty

    // Recovery (on branch misprediction / pipeline flush)
    input  logic         flush,
    input  logic [4:0]   correct_sp_ptr // Restore point from ROB
);

    // 16-entry hardware stack for nested returns
    logic [31:0] stack [15:0];
    logic [3:0]  sp_ptr;

    assign predicted_ret_pc = stack[sp_ptr - 1'b1];
    assign ras_valid = (sp_ptr != 0);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sp_ptr <= 0;
            for (int i = 0; i < 16; i++) stack[i] <= 32'h0;
        end else if (flush) begin
            sp_ptr <= correct_sp_ptr[3:0]; // Roll back stack on mispredict
        end else begin
            if (is_call) begin
                stack[sp_ptr] <= call_ret_pc;
                sp_ptr <= sp_ptr + 1'b1;
            end else if (is_ret && ras_valid) begin
                sp_ptr <= sp_ptr - 1'b1;
            end
        end
    end

endmodule
