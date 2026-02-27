/*
 * fabi386: Reorder Buffer (ROB)
 * -----------------------------
 * 16-entry circular buffer tracking in-flight instructions for
 * in-order retirement.  Supports 2-wide dispatch (U+V pipe) and
 * 2-wide retirement.  Execute units mark entries complete via the
 * Common Data Bus (CDB) writeback ports.
 *
 * Key signals:
 *   dispatch_u/v  — decoded instructions entering the ROB
 *   cdb_*         — completion writeback from execute units
 *   retire_u/v    — oldest completed instructions leaving the ROB
 *   flush         — branch misprediction: squash all in-flight entries
 *   rob_tag_u/v   — assigned ROB slot IDs (fed back to issue queue)
 *   full          — back-pressure to dispatch stage
 */

import f386_pkg::*;

module f386_rob (
    input  logic         clk,
    input  logic         rst_n,

    // --- Dispatch Interface (from Rename/Dispatch) ---
    input  ooo_instr_t   dispatch_u,
    input  logic         dispatch_u_valid,
    input  ooo_instr_t   dispatch_v,
    input  logic         dispatch_v_valid,
    output rob_id_t      rob_tag_u,        // Assigned ROB slot for U-pipe
    output rob_id_t      rob_tag_v,        // Assigned ROB slot for V-pipe
    output logic         full,             // ROB cannot accept more instructions

    // --- CDB Writeback (from Execute) ---
    input  logic         cdb0_valid,       // Completion port 0
    input  rob_id_t      cdb0_tag,         // Which ROB entry completed
    input  logic [31:0]  cdb0_data,        // Result value
    input  logic         cdb0_exception,   // Exception during execution

    input  logic         cdb1_valid,       // Completion port 1
    input  rob_id_t      cdb1_tag,
    input  logic [31:0]  cdb1_data,
    input  logic         cdb1_exception,

    // --- Retirement Interface (to Arch Register File / Free List) ---
    output rob_entry_t   retire_u,
    output logic         retire_u_valid,
    output rob_entry_t   retire_v,
    output logic         retire_v_valid,

    // --- Flush (from Branch Resolution) ---
    input  logic         flush
);

    // =========================================================
    // Storage
    // =========================================================
    // ROB is a circular buffer indexed by head (retire) and tail (dispatch).
    // Each entry stores the dispatched instruction, its result data,
    // a 'complete' flag (set by CDB writeback), and an exception flag.

    logic [15:0]  entry_valid;      // Slot is occupied
    logic [15:0]  entry_complete;   // Execution finished (CDB wrote back)
    logic [15:0]  entry_exception;  // Execution raised an exception
    ooo_instr_t   entry_instr [16];
    logic [31:0]  entry_data  [16];

    logic [3:0] head, tail;
    logic [4:0] count;  // 5-bit to represent 0..16

    // =========================================================
    // Occupancy
    // =========================================================
    // How many slots the current dispatch would consume
    logic [1:0] dispatch_count;
    assign dispatch_count = {1'b0, dispatch_u_valid} + {1'b0, dispatch_v_valid};

    // How many slots the current retirement frees
    logic [1:0] retire_count;

    // Full when there aren't enough free slots for both U and V
    logic [4:0] free_slots;
    assign free_slots = 5'd16 - count;
    assign full = (free_slots < {3'd0, dispatch_count});

    // Assigned tags match the actual dispatch slots
    // V-pipe slot: next after U if U is also dispatching, else same as U
    logic [3:0] v_slot;
    assign v_slot   = dispatch_u_valid ? (tail + 4'd1) : tail;
    assign rob_tag_u = tail;
    assign rob_tag_v = v_slot;

    // =========================================================
    // Dispatch (tail advances)
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tail <= 4'd0;
            entry_valid <= 16'd0;
        end else if (flush) begin
            tail <= 4'd0;
            entry_valid <= 16'd0;
        end else if (!full) begin
            if (dispatch_u_valid) begin
                entry_instr[tail]     <= dispatch_u;
                entry_data[tail]      <= 32'd0;
                entry_valid[tail]     <= 1'b1;
                entry_complete[tail]  <= 1'b0;
                entry_exception[tail] <= 1'b0;
            end
            if (dispatch_v_valid) begin
                entry_instr[v_slot]     <= dispatch_v;
                entry_data[v_slot]      <= 32'd0;
                entry_valid[v_slot]     <= 1'b1;
                entry_complete[v_slot]  <= 1'b0;
                entry_exception[v_slot] <= 1'b0;
            end
            tail <= tail + {2'd0, dispatch_count};
        end
    end

    // =========================================================
    // CDB Writeback (mark entries complete)
    // =========================================================
    // CDB writes can happen to any slot at any time (out-of-order completion).
    // This is the critical fix: without this, .ready/complete is never set
    // and the ROB stalls permanently.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            entry_complete  <= 16'd0;
            entry_exception <= 16'd0;
        end else if (flush) begin
            entry_complete  <= 16'd0;
            entry_exception <= 16'd0;
        end else begin
            if (cdb0_valid && entry_valid[cdb0_tag]) begin
                entry_complete[cdb0_tag]  <= 1'b1;
                entry_data[cdb0_tag]      <= cdb0_data;
                entry_exception[cdb0_tag] <= cdb0_exception;
            end
            if (cdb1_valid && entry_valid[cdb1_tag]) begin
                entry_complete[cdb1_tag]  <= 1'b1;
                entry_data[cdb1_tag]      <= cdb1_data;
                entry_exception[cdb1_tag] <= cdb1_exception;
            end
        end
    end

    // =========================================================
    // Retirement (head advances, in-order)
    // =========================================================
    // Retire up to 2 instructions per cycle, strictly in program order.
    // U retires from head, V retires from head+1 only if U also retires.

    logic        can_retire_u, can_retire_v;
    logic [3:0]  head_plus1;

    assign head_plus1 = head + 4'd1;

    // U-pipe: oldest instruction can retire if valid and complete
    assign can_retire_u = entry_valid[head] && entry_complete[head];

    // V-pipe: next-oldest can retire only if U also retires without exception
    assign can_retire_v = can_retire_u && !entry_exception[head] &&
                          entry_valid[head_plus1] && entry_complete[head_plus1] &&
                          !entry_exception[head_plus1];

    // Build retirement outputs
    always_comb begin
        retire_u       = '0;
        retire_u_valid = 1'b0;
        retire_v       = '0;
        retire_v_valid = 1'b0;
        retire_count   = 2'd0;

        if (can_retire_u) begin
            retire_u.instr = entry_instr[head];
            retire_u.data  = entry_data[head];
            retire_u.ready = 1'b1;
            retire_u.valid = 1'b1;
            retire_u_valid = 1'b1;
            retire_count   = 2'd1;

            // V retires only if both U and V are exception-free (precise exceptions)
            if (can_retire_v) begin
                retire_v.instr = entry_instr[head_plus1];
                retire_v.data  = entry_data[head_plus1];
                retire_v.ready = 1'b1;
                retire_v.valid = 1'b1;
                retire_v_valid = 1'b1;
                retire_count   = 2'd2;
            end
        end
    end

    // Advance head pointer and free retired slots
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head <= 4'd0;
        end else if (flush) begin
            head <= 4'd0;
        end else begin
            if (retire_u_valid) begin
                entry_valid[head] <= 1'b0;
                if (retire_v_valid)
                    entry_valid[head_plus1] <= 1'b0;
            end
            head <= head + {2'd0, retire_count};
        end
    end

    // =========================================================
    // Occupancy Counter
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= 5'd0;
        end else if (flush) begin
            count <= 5'd0;
        end else begin
            count <= count + {3'd0, dispatch_count} - {3'd0, retire_count};
        end
    end

endmodule
