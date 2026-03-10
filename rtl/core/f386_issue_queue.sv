/*
 * fabi386: Unified Issue Queue (v2.0 - Producer Matrix Wakeup)
 * ------------------------------------------------------------
 * 8-entry reservation station with two wakeup modes:
 *
 *   CONF_ENABLE_PRODUCER_MTX = 1:
 *     Uses f386_ready_bit_table + f386_producer_matrix + f386_wakeup_select
 *     for dependency-matrix-based wakeup. CDB broadcasts update operand
 *     values and clear producer matrix columns. 1-cycle wakeup latency.
 *
 *   CONF_ENABLE_PRODUCER_MTX = 0:
 *     Falls back to the original naive ready-bit scan (src_a_ready &&
 *     src_b_ready priority encoder). No submodule instantiation.
 *
 * External interface is unchanged from v1.0 except for the addition of
 * CDB inputs and flush. These must be wired in f386_ooo_core_top.sv.
 */

import f386_pkg::*;

module f386_issue_queue (
    input  logic         clk,
    input  logic         reset_n,

    // Dispatch (1-wide; V-pipe bypasses IQ in ooo_core_top)
    input  ooo_instr_t   dispatch_instr,
    input  logic         dispatch_valid,

    // Issue output
    output ooo_instr_t   issue_instr,
    output logic         issue_valid,
    input  logic         exec_ready,

    // CDB (for wakeup and operand capture)
    input  logic         cdb0_valid,
    input  rob_id_t      cdb0_tag,
    input  logic [31:0]  cdb0_data,
    input  phys_reg_t    cdb0_dest,
    input  logic         cdb1_valid,
    input  rob_id_t      cdb1_tag,
    input  logic [31:0]  cdb1_data,
    input  phys_reg_t    cdb1_dest,

    // Flush
    input  logic         flush,

    // Microcode: skip OP_MICROCODE unless it's at ROB head and sequencer is idle
    input  logic         ucode_active,
    input  rob_id_t      rob_head
);

    localparam int N     = CONF_IQ_ENTRIES;
    localparam int IDX_W = $clog2(N);

    // ---------------------------------------------------------------
    // IQ Entry Storage
    // ---------------------------------------------------------------
    ooo_instr_t    queue [N];
    logic [N-1:0]  entry_valid;

    // ---------------------------------------------------------------
    // Free-slot finder: returns the lowest-indexed free slot
    // ---------------------------------------------------------------
    logic [IDX_W-1:0] free_idx;
    logic             free_found;

    always_comb begin
        free_idx   = '0;
        free_found = 1'b0;
        for (int i = 0; i < N; i++) begin
            if (!entry_valid[i] && !free_found) begin
                free_idx   = IDX_W'(i);
                free_found = 1'b1;
            end
        end
    end

    // =================================================================
    // Generate: Producer Matrix Path vs. Naive Path
    // =================================================================
    generate
    if (CONF_ENABLE_PRODUCER_MTX) begin : gen_producer_mtx

        // ---------------------------------------------------------------
        // Producer-matrix wakeup datapath
        // ---------------------------------------------------------------

        // --- Ready Bit Table ---
        logic rbt_ready_a, rbt_ready_b;

        f386_ready_bit_table rbt (
            .clk              (clk),
            .rst_n            (reset_n),
            .flush            (flush),
            .cdb0_valid       (cdb0_valid),
            .cdb0_dest        (cdb0_dest),
            .cdb1_valid       (cdb1_valid),
            .cdb1_dest        (cdb1_dest),
            .dispatch_u_valid (dispatch_valid),
            .dispatch_u_dest  (dispatch_instr.p_dest),
            .dispatch_v_valid (1'b0),         // V-pipe bypasses IQ
            .dispatch_v_dest  (5'd0),
            .query_a          (dispatch_instr.p_src_a),
            .query_b          (dispatch_instr.p_src_b),
            .ready_a          (rbt_ready_a),
            .ready_b          (rbt_ready_b)
        );

        // --- Build dependency vector for dispatch ---
        // For each existing IQ entry, check if it produces a register
        // that the dispatching instruction needs as a source.
        logic [N-1:0] alloc_deps;

        always_comb begin
            alloc_deps = '0;
            for (int i = 0; i < N; i++) begin
                if (entry_valid[i]) begin
                    // Entry i produces p_dest; does the new instr need it?
                    if (!rbt_ready_a && queue[i].p_dest == dispatch_instr.p_src_a)
                        alloc_deps[i] = 1'b1;
                    if (!rbt_ready_b && queue[i].p_dest == dispatch_instr.p_src_b)
                        alloc_deps[i] = 1'b1;
                end
            end
        end

        // --- Map CDB dest to IQ index for wake signals ---
        // When a CDB fires, find which IQ entry has a matching p_dest
        // to determine which column to clear in the producer matrix.
        logic        wake0_valid_iq, wake1_valid_iq;
        logic [IDX_W-1:0] wake0_idx_iq, wake1_idx_iq;

        always_comb begin
            wake0_valid_iq = 1'b0;
            wake0_idx_iq   = '0;
            for (int i = 0; i < N; i++) begin
                if (cdb0_valid && entry_valid[i] &&
                    queue[i].p_dest == cdb0_dest && !wake0_valid_iq) begin
                    wake0_valid_iq = 1'b1;
                    wake0_idx_iq   = IDX_W'(i);
                end
            end

            wake1_valid_iq = 1'b0;
            wake1_idx_iq   = '0;
            for (int i = 0; i < N; i++) begin
                if (cdb1_valid && entry_valid[i] &&
                    queue[i].p_dest == cdb1_dest && !wake1_valid_iq) begin
                    wake1_valid_iq = 1'b1;
                    wake1_idx_iq   = IDX_W'(i);
                end
            end
        end

        // --- Producer Matrix ---
        logic [N-1:0] pm_ready_vec;

        f386_producer_matrix pm (
            .clk         (clk),
            .rst_n       (reset_n),
            .flush       (flush),
            .alloc_valid (dispatch_valid && free_found),
            .alloc_idx   (free_idx),
            .alloc_deps  (alloc_deps),
            .wake0_valid (wake0_valid_iq),
            .wake0_idx   (wake0_idx_iq),
            .wake1_valid (wake1_valid_iq),
            .wake1_idx   (wake1_idx_iq),
            .ready_vec   (pm_ready_vec)
        );

        // --- Wakeup Select ---
        rob_id_t entry_rob_tags [N];
        always_comb begin
            for (int i = 0; i < N; i++)
                entry_rob_tags[i] = queue[i].rob_tag;
        end

        logic [IDX_W-1:0] ws_issue_idx;
        logic              ws_issue_valid;

        f386_wakeup_select ws (
            .clk           (clk),
            .rst_n         (reset_n),
            .flush         (flush),
            .ready_vec     (pm_ready_vec),
            .entry_rob_tag (entry_rob_tags),
            .entry_valid   (entry_valid),
            .issue_idx     (ws_issue_idx),
            .issue_valid   (ws_issue_valid),
            .exec_ack      (exec_ready && issue_valid)
        );

        // --- Issue Output (producer matrix path) ---
        always_comb begin
            issue_valid = ws_issue_valid;
            issue_instr = ws_issue_valid ? queue[ws_issue_idx] : '0;
        end

        // --- Entry Storage + CDB Operand Capture ---
        always_ff @(posedge clk or negedge reset_n) begin
            if (!reset_n) begin
                entry_valid <= '0;
            end else if (flush) begin
                entry_valid <= '0;
            end else begin
                // CDB operand capture: snoop CDB and update stored values
                for (int i = 0; i < N; i++) begin
                    if (entry_valid[i]) begin
                        // CDB0 match on src_a
                        if (cdb0_valid && queue[i].p_src_a == cdb0_dest &&
                            !queue[i].src_a_ready) begin
                            queue[i].val_a       <= cdb0_data;
                            queue[i].src_a_ready <= 1'b1;
                        end
                        // CDB0 match on src_b
                        if (cdb0_valid && queue[i].p_src_b == cdb0_dest &&
                            !queue[i].src_b_ready) begin
                            queue[i].val_b       <= cdb0_data;
                            queue[i].src_b_ready <= 1'b1;
                        end
                        // CDB1 match on src_a
                        if (cdb1_valid && queue[i].p_src_a == cdb1_dest &&
                            !queue[i].src_a_ready) begin
                            queue[i].val_a       <= cdb1_data;
                            queue[i].src_a_ready <= 1'b1;
                        end
                        // CDB1 match on src_b
                        if (cdb1_valid && queue[i].p_src_b == cdb1_dest &&
                            !queue[i].src_b_ready) begin
                            queue[i].val_b       <= cdb1_data;
                            queue[i].src_b_ready <= 1'b1;
                        end
                    end
                end

                // Dispatch: allocate new entry
                if (dispatch_valid && free_found) begin
                    queue[free_idx]        <= dispatch_instr;
                    entry_valid[free_idx]  <= 1'b1;
                end

                // Issue: free the slot when execute acknowledges
                if (ws_issue_valid && exec_ready) begin
                    entry_valid[ws_issue_idx] <= 1'b0;
                end
            end
        end

    end else begin : gen_naive_iq

        // ---------------------------------------------------------------
        // Naive fallback: simple ready-bit scan (original v1.0 behavior)
        // ---------------------------------------------------------------

        // --- Issue Output (naive path) ---
        // Priority encoder: lowest ready entry wins
        logic [IDX_W-1:0] naive_issue_idx;
        logic              naive_issue_valid;

        always_comb begin
            naive_issue_valid = 1'b0;
            naive_issue_idx   = '0;
            issue_instr       = '0;
            for (int i = 0; i < N; i++) begin
                if (entry_valid[i] && queue[i].src_a_ready &&
                    queue[i].src_b_ready && !naive_issue_valid &&
                    !(queue[i].op_cat == OP_MICROCODE &&
                      (ucode_active || queue[i].rob_tag != rob_head))) begin
                    issue_instr       = queue[i];
                    naive_issue_valid = 1'b1;
                    naive_issue_idx   = IDX_W'(i);
                end
            end
            issue_valid = naive_issue_valid;
        end

        // --- Entry Storage + CDB Operand Capture ---
        always_ff @(posedge clk or negedge reset_n) begin
            if (!reset_n) begin
                entry_valid <= '0;
            end else if (flush) begin
                entry_valid <= '0;
            end else begin
                // CDB operand capture: snoop CDB and update stored values
                for (int i = 0; i < N; i++) begin
                    if (entry_valid[i]) begin
                        if (cdb0_valid && queue[i].p_src_a == cdb0_dest &&
                            !queue[i].src_a_ready) begin
                            queue[i].val_a       <= cdb0_data;
                            queue[i].src_a_ready <= 1'b1;
                        end
                        if (cdb0_valid && queue[i].p_src_b == cdb0_dest &&
                            !queue[i].src_b_ready) begin
                            queue[i].val_b       <= cdb0_data;
                            queue[i].src_b_ready <= 1'b1;
                        end
                        if (cdb1_valid && queue[i].p_src_a == cdb1_dest &&
                            !queue[i].src_a_ready) begin
                            queue[i].val_a       <= cdb1_data;
                            queue[i].src_a_ready <= 1'b1;
                        end
                        if (cdb1_valid && queue[i].p_src_b == cdb1_dest &&
                            !queue[i].src_b_ready) begin
                            queue[i].val_b       <= cdb1_data;
                            queue[i].src_b_ready <= 1'b1;
                        end
                    end
                end

                // Dispatch: allocate new entry
                if (dispatch_valid && free_found) begin
                    queue[free_idx]        <= dispatch_instr;
                    entry_valid[free_idx]  <= 1'b1;
                end

                // Issue: free the slot when execute acknowledges
                if (naive_issue_valid && exec_ready) begin
                    entry_valid[naive_issue_idx] <= 1'b0;
                end
            end
        end

    end
    endgenerate

endmodule
