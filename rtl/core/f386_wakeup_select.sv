/*
 * fabi386: Wakeup Select Logic
 * -----------------------------
 * Selects the oldest ready instruction from the issue queue for issue.
 * Uses a simple priority encoder (lowest index wins) which approximates
 * age ordering since IQ entries are allocated in dispatch order.
 *
 * For a more precise age comparison, the ROB tags are available but
 * the priority encoder is sufficient for the initial implementation
 * and avoids the ROB-tag wraparound comparison logic.
 *
 * Feature-gated by CONF_ENABLE_PRODUCER_MTX.
 */

import f386_pkg::*;

module f386_wakeup_select (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,

    // Ready vector from producer matrix
    input  logic [CONF_IQ_ENTRIES-1:0] ready_vec,

    // Age ordering (ROB tags for each entry, for future precise-age select)
    input  rob_id_t     entry_rob_tag [CONF_IQ_ENTRIES],
    input  logic [CONF_IQ_ENTRIES-1:0] entry_valid,

    // Issue output
    output logic [$clog2(CONF_IQ_ENTRIES)-1:0] issue_idx,
    output logic        issue_valid,

    // Execute consumed the issued instruction
    input  logic        exec_ack
);

    localparam int N = CONF_IQ_ENTRIES;
    localparam int IDX_W = $clog2(N);

    // Candidates: must be both ready (deps satisfied) and valid (allocated)
    logic [N-1:0] candidates;
    assign candidates = ready_vec & entry_valid;

    // Priority encoder: lowest index wins (approximates oldest-first)
    logic [IDX_W-1:0] selected_idx;
    logic              selected_valid;

    always_comb begin
        selected_idx   = '0;
        selected_valid = 1'b0;
        for (int i = 0; i < N; i++) begin
            if (candidates[i] && !selected_valid) begin
                selected_idx   = IDX_W'(i);
                selected_valid = 1'b1;
            end
        end
    end

    // Register the issue output for timing (1-cycle select latency)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_idx   <= '0;
            issue_valid <= 1'b0;
        end else if (flush) begin
            issue_idx   <= '0;
            issue_valid <= 1'b0;
        end else begin
            issue_idx   <= selected_idx;
            issue_valid <= selected_valid;
        end
    end

endmodule
