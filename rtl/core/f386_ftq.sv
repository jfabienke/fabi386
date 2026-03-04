/*
 * fabi386: Fetch Target Queue (FTQ)
 * -----------------------------------
 * Decouples the fetch stage from the decode/dispatch pipeline by buffering
 * fetch-block metadata (PC, prediction, GHR snapshot, branch tag).
 *
 * The FTQ serves three purposes:
 *   1. Decouple fetch bandwidth from decode/dispatch stalls — fetch can
 *      run ahead by up to CONF_FTQ_ENTRIES blocks.
 *   2. Store prediction metadata alongside fetch blocks so that branch
 *      resolution can repair the GHR and redirect fetch.
 *   3. Provide the ROB with a compact FTQ index instead of a full 32-bit
 *      PC per entry (ROB stores ftq_idx + offset → saves ~100 ALMs at
 *      16-entry ROB).
 *
 * Interface:
 *   Enqueue: fetch stage pushes a new entry every cycle it fetches.
 *   Dequeue: decode/dispatch stage pops an entry when it consumes a block.
 *   Redirect: on mispredict, the FTQ is flushed from the mispredicted
 *             entry forward, and the GHR/PC are repaired.
 *
 * Reference: BOOM fetch-target-queue.scala
 * Parameterized via CONF_FTQ_ENTRIES (default 8).
 */

import f386_pkg::*;

module f386_ftq (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,               // Full pipeline flush

    // --- Enqueue (from fetch stage) ---
    input  logic        enq_valid,           // Fetch has a new block
    input  logic [31:0] enq_fetch_pc,        // Fetch block start PC
    input  logic        enq_pred_taken,      // Predictor said taken?
    input  logic [31:0] enq_pred_target,     // Predicted next-fetch PC
    input  br_tag_t     enq_br_tag,          // Branch tag (if block has branch)
    input  logic        enq_has_branch,      // This block contains a branch
    input  logic [CONF_GHR_WIDTH-1:0] enq_ghr, // GHR snapshot at prediction time
    output logic        enq_ready,           // FTQ can accept a new entry
    output ftq_idx_t    enq_ftq_idx,         // Assigned FTQ index (for ROB)

    // --- Dequeue (to decode/dispatch) ---
    output logic        deq_valid,           // Entry available for decode
    output logic [31:0] deq_fetch_pc,        // Fetch block PC
    output logic        deq_pred_taken,
    output logic [31:0] deq_pred_target,
    output br_tag_t     deq_br_tag,
    output logic        deq_has_branch,
    output ftq_idx_t    deq_ftq_idx,         // Index of dequeued entry
    input  logic        deq_ready,           // Decode consumed this entry

    // --- Redirect (from branch resolution / mispredict) ---
    input  logic        redirect_valid,      // Mispredict: redirect fetch
    input  ftq_idx_t    redirect_ftq_idx,    // FTQ entry that mispredicted
    output logic [31:0] redirect_repair_pc,  // Correct PC to resume fetch
    output logic [CONF_GHR_WIDTH-1:0] redirect_repair_ghr, // GHR to restore

    // --- ROB PC lookup (for retirement / exception reporting) ---
    input  ftq_idx_t    lookup_idx,
    output logic [31:0] lookup_pc,
    output logic [CONF_GHR_WIDTH-1:0] lookup_ghr
);

    localparam int N     = CONF_FTQ_ENTRIES;   // 8
    localparam int IDX_W = FTQ_ID_WIDTH;       // 3

    // =========================================================
    // Storage: circular buffer of FTQ entries
    // =========================================================
    ftq_entry_t entries [N];

    ftq_idx_t   head;    // Dequeue pointer (oldest un-consumed entry)
    ftq_idx_t   tail;    // Enqueue pointer (next free slot)
    logic [IDX_W:0] count;  // +1 bit for full/empty disambiguation

    // =========================================================
    // Occupancy
    // =========================================================
    logic [IDX_W:0] free_slots;
    assign free_slots = N[IDX_W:0] - count;
    assign enq_ready  = (free_slots > '0);
    assign enq_ftq_idx = tail;

    // =========================================================
    // Dequeue output
    // =========================================================
    assign deq_valid       = (count > '0);
    assign deq_fetch_pc    = entries[head].fetch_pc;
    assign deq_pred_taken  = entries[head].pred_taken;
    assign deq_pred_target = entries[head].pred_target;
    assign deq_br_tag      = entries[head].br_tag;
    assign deq_has_branch  = entries[head].has_branch;
    assign deq_ftq_idx     = head;

    // =========================================================
    // Redirect: repair PC and GHR from the mispredicted entry
    // =========================================================
    // The "correct" PC is not stored here — it comes from the
    // execute stage's branch_target output.  What we provide is
    // the GHR at prediction time so the front-end can restore it.
    // redirect_repair_pc: fetch_pc of the mispredicted entry
    // (the execute stage provides the corrected target separately).
    assign redirect_repair_pc  = entries[redirect_ftq_idx].fetch_pc;
    assign redirect_repair_ghr = entries[redirect_ftq_idx].ghr_snap;

    // =========================================================
    // ROB PC lookup (combinational read port)
    // =========================================================
    assign lookup_pc = entries[lookup_idx].fetch_pc;
    assign lookup_ghr = entries[lookup_idx].ghr_snap;

    // =========================================================
    // Enqueue
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tail  <= '0;
        end else if (flush) begin
            tail  <= '0;
        end else if (redirect_valid) begin
            // On redirect, rewind tail to one past the mispredicted entry
            // All entries after the mispredict are invalid
            tail <= redirect_ftq_idx + ftq_idx_t'(1);
        end else if (enq_valid && enq_ready) begin
            entries[tail].valid      <= 1'b1;
            entries[tail].fetch_pc   <= enq_fetch_pc;
            entries[tail].pred_taken <= enq_pred_taken;
            entries[tail].pred_target<= enq_pred_target;
            entries[tail].br_tag     <= enq_br_tag;
            entries[tail].has_branch <= enq_has_branch;
            entries[tail].ghr_snap   <= enq_ghr;
            tail <= tail + ftq_idx_t'(1);
        end
    end

    // =========================================================
    // Dequeue
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head <= '0;
        end else if (flush) begin
            head <= '0;
        end else if (deq_valid && deq_ready) begin
            entries[head].valid <= 1'b0;
            head <= head + ftq_idx_t'(1);
        end
    end

    // =========================================================
    // Count tracking
    // =========================================================
    // On redirect, count becomes distance from head to new tail
    logic [IDX_W:0] redirect_count;
    always_comb begin
        // Compute entries remaining after redirect
        if (redirect_ftq_idx >= head)
            redirect_count = {1'b0, redirect_ftq_idx} - {1'b0, head} + (IDX_W+1)'(1);
        else
            redirect_count = {1'b0, redirect_ftq_idx} + N[IDX_W:0] - {1'b0, head} + (IDX_W+1)'(1);
    end

    logic enq_fire, deq_fire;
    assign enq_fire = enq_valid && enq_ready && !redirect_valid;
    assign deq_fire = deq_valid && deq_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= '0;
        end else if (flush) begin
            count <= '0;
        end else if (redirect_valid) begin
            // Recompute count based on redirect position
            count <= redirect_count - (deq_fire ? (IDX_W+1)'(1) : '0);
        end else begin
            count <= count + (enq_fire ? (IDX_W+1)'(1) : '0)
                           - (deq_fire ? (IDX_W+1)'(1) : '0);
        end
    end

endmodule
