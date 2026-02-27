/*
 * fabi386: Unified Issue Queue
 * ----------------------------
 * Reservation stations implementing Wakeup and Select logic.
 */

import f386_pkg::*;

module f386_issue_queue (
    input  logic         clk,
    input  logic         reset_n,

    input  ooo_instr_t   dispatch_instr,
    input  logic         dispatch_valid,

    output ooo_instr_t   issue_instr,
    output logic         issue_valid,
    input  logic         exec_ready
);

    ooo_instr_t queue [8];
    logic [7:0] entry_valid;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) entry_valid <= 8'h0;
        else if (dispatch_valid) begin
            for (int i=0; i<8; i++) if (!entry_valid[i]) begin
                queue[i] <= dispatch_instr;
                entry_valid[i] <= 1'b1;
                break;
            end
        end
    end

    always_comb begin
        issue_valid = 1'b0;
        issue_instr = '0;
        for (int i=0; i<8; i++) begin
            if (entry_valid[i] && queue[i].src_a_ready && queue[i].src_b_ready) begin
                issue_instr = queue[i];
                issue_valid = 1'b1;
                break;
            end
        end
    end

endmodule
