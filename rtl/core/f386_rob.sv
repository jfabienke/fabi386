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
    input  logic [5:0]   cdb0_flags,       // ALU flags result {OF,SF,ZF,AF,PF,CF}
    input  logic [5:0]   cdb0_flags_mask,  // Which flags this instruction writes
    input  logic         cdb0_exception,   // Exception during execution
    input  logic [7:0]   cdb0_exc_vector,  // Exception vector (P3.EXC.a)
    input  logic [31:0]  cdb0_exc_code,    // Exception error code
    input  logic         cdb0_exc_has_error, // Error code valid

    input  logic         cdb1_valid,       // Completion port 1
    input  rob_id_t      cdb1_tag,
    input  logic [31:0]  cdb1_data,
    input  logic [5:0]   cdb1_flags,
    input  logic [5:0]   cdb1_flags_mask,
    input  logic         cdb1_exception,
    input  logic [7:0]   cdb1_exc_vector,
    input  logic [31:0]  cdb1_exc_code,
    input  logic         cdb1_exc_has_error,

    // --- Retirement Interface (to Arch Register File / Free List) ---
    output rob_entry_t   retire_u,
    output logic         retire_u_valid,
    output logic [5:0]   retire_u_flags,       // Flags result from this instruction
    output logic [5:0]   retire_u_flags_mask,  // Which flags to commit
    output logic         retire_u_has_exc,     // P3.EXC.a: exception at retirement
    output logic [7:0]   retire_u_exc_vector,
    output logic [31:0]  retire_u_exc_code,
    output logic         retire_u_exc_has_error,
    output rob_entry_t   retire_v,
    output logic         retire_v_valid,
    output logic [5:0]   retire_v_flags,
    output logic [5:0]   retire_v_flags_mask,
    output logic         retire_v_has_exc,
    output logic [7:0]   retire_v_exc_vector,
    output logic [31:0]  retire_v_exc_code,
    output logic         retire_v_exc_has_error,

    // --- LSQ Index Pairing ---
    input  lq_idx_t      dispatch_u_lq_idx,  // Load queue index for U-pipe
    input  sq_idx_t      dispatch_u_sq_idx,  // Store queue index for U-pipe
    input  lq_idx_t      dispatch_v_lq_idx,
    input  sq_idx_t      dispatch_v_sq_idx,

    // Store retirement coordination
    output sq_idx_t      retire_u_sq_idx,    // SQ index of retiring store (U-pipe)
    output logic         retire_u_is_store,  // U-pipe retiring a store
    output sq_idx_t      retire_v_sq_idx,
    output logic         retire_v_is_store,

    // --- SpecBits (Phase P1) ---
    input  specbits_t    dispatch_u_specbits, // Speculation mask at dispatch
    input  specbits_t    dispatch_v_specbits,
    input  ftq_idx_t     dispatch_u_ftq_idx,  // FTQ index for compact PC
    input  ftq_idx_t     dispatch_v_ftq_idx,
    input  logic         specbits_resolve_valid, // Branch resolved correctly
    input  br_tag_t      specbits_resolve_tag,
    input  logic         specbits_squash_valid,  // Branch mispredicted
    input  specbits_t    specbits_squash_mask,

    // --- Old physical register (for freelist reclaim at retirement) ---
    input  phys_reg_t    dispatch_u_old_phys,
    input  phys_reg_t    dispatch_v_old_phys,
    output phys_reg_t    retire_u_old_phys,
    output phys_reg_t    retire_v_old_phys,

    // --- Flush (from Branch Resolution) ---
    input  logic         flush,

    // --- P3: Head pointer export (for microcode drain) ---
    output rob_id_t      rob_head_out
);

    // =========================================================
    // Storage
    // =========================================================
    // ROB is a circular buffer indexed by head (retire) and tail (dispatch).
    // Each entry stores the dispatched instruction, its result data,
    // a 'complete' flag (set by CDB writeback), and an exception flag.

    localparam int N = CONF_ROB_ENTRIES;  // Parameterized depth (default 16)

    logic [N-1:0]  entry_valid;      // Slot is occupied
    logic [N-1:0]  entry_complete;   // Execution finished (CDB wrote back)
    logic [N-1:0]  entry_exception;  // Execution raised an exception
    ooo_instr_t    entry_instr [N];
    logic [31:0]   entry_data  [N];

    // Per-entry exception metadata (P3.EXC.a)
    logic [7:0]    entry_exc_vector   [N];  // Exception vector (0-31)
    logic [31:0]   entry_exc_code     [N];  // Error code
    logic [N-1:0]  entry_exc_has_error;     // Error code valid flag

    // Per-entry old physical register (for freelist reclaim at retirement)
    phys_reg_t     entry_old_phys [N];

    // Per-entry flags (BOOM/RSD pattern: flags travel through ROB alongside data)
    logic [5:0]    entry_flags      [N];  // ALU flags result
    logic [5:0]    entry_flags_mask [N];  // Which flags this instruction modifies

    // Per-entry LSQ indices (for store retirement coordination)
    lq_idx_t       entry_lq_idx [N];     // Load queue index (if OP_LOAD)
    sq_idx_t       entry_sq_idx [N];     // Store queue index (if OP_STORE)

    // Per-entry speculation bits (Phase P1: which branches this entry depends on)
    specbits_t     entry_specbits [N];   // Bitmask of in-flight branch tags
    ftq_idx_t      entry_ftq_idx [N];   // FTQ index for compact PC storage

    rob_id_t head, tail;
    logic [ROB_ID_WIDTH:0] count;  // +1 bit to represent 0..N
    assign rob_head_out = head;

    // =========================================================
    // Occupancy
    // =========================================================
    // How many slots the current dispatch would consume
    logic [1:0] dispatch_count;
    assign dispatch_count = {1'b0, dispatch_u_valid} + {1'b0, dispatch_v_valid};

    // How many slots the current retirement frees
    logic [1:0] retire_count;

    // Full when there aren't enough free slots for both U and V
    logic [ROB_ID_WIDTH:0] free_slots;
    assign free_slots = N[ROB_ID_WIDTH:0] - count;
`ifdef VERILATOR
    // Simulation bench mode: avoid combinational full<->dispatch feedback loop
    // through top-level dispatch gating by using a conservative fullness rule.
    // This may stall earlier (requires >=2 free slots) but keeps behavior safe.
    assign full = (free_slots < {{(ROB_ID_WIDTH-1){1'b0}}, 2'd2});
`else
    assign full = (free_slots < {{(ROB_ID_WIDTH-1){1'b0}}, dispatch_count});
`endif

    // Assigned tags match the actual dispatch slots
    // V-pipe slot: next after U if U is also dispatching, else same as U
    rob_id_t v_slot;
    assign v_slot   = dispatch_u_valid ? (tail + rob_id_t'(1)) : tail;
    assign rob_tag_u = tail;
    assign rob_tag_v = v_slot;

    // =========================================================
    // Retirement signals (combinational)
    // =========================================================
    // Retire up to 2 instructions per cycle, strictly in program order.
    // U retires from head, V retires from head+1 only if U also retires.

    logic        can_retire_u, can_retire_v;
    rob_id_t     head_plus1;

    assign head_plus1 = head + rob_id_t'(1);

    // U-pipe: oldest instruction can retire if valid and complete
    assign can_retire_u = entry_valid[head] && entry_complete[head];

    // V-pipe: next-oldest can retire only if U also retires without exception
    assign can_retire_v = can_retire_u && !entry_exception[head] &&
                          entry_valid[head_plus1] && entry_complete[head_plus1] &&
                          !entry_exception[head_plus1];

    // Build retirement outputs
    always_comb begin
        retire_u            = '0;
        retire_u_valid      = 1'b0;
        retire_u_flags      = 6'd0;
        retire_u_flags_mask = 6'd0;
        retire_u_has_exc       = 1'b0;
        retire_u_exc_vector    = 8'd0;
        retire_u_exc_code      = 32'd0;
        retire_u_exc_has_error = 1'b0;
        retire_v            = '0;
        retire_v_valid      = 1'b0;
        retire_v_flags      = 6'd0;
        retire_v_flags_mask = 6'd0;
        retire_v_has_exc       = 1'b0;
        retire_v_exc_vector    = 8'd0;
        retire_v_exc_code      = 32'd0;
        retire_v_exc_has_error = 1'b0;
        retire_count        = 2'd0;

        // Default LSQ retirement outputs
        retire_u_sq_idx   = entry_sq_idx[head];
        retire_u_is_store = 1'b0;
        retire_v_sq_idx   = entry_sq_idx[head_plus1];
        retire_v_is_store = 1'b0;

        // Old physical register for freelist reclaim
        retire_u_old_phys = entry_old_phys[head];
        retire_v_old_phys = entry_old_phys[head_plus1];

        if (can_retire_u) begin
            retire_u.instr      = entry_instr[head];
            retire_u.data       = entry_data[head];
            retire_u.ready      = 1'b1;
            retire_u.valid      = 1'b1;
            retire_u_valid      = 1'b1;
            retire_u_flags      = entry_flags[head];
            retire_u_flags_mask = entry_flags_mask[head];
            retire_u_is_store   = (entry_instr[head].op_cat == OP_STORE);
            retire_u_has_exc       = entry_exception[head];
            retire_u_exc_vector    = entry_exc_vector[head];
            retire_u_exc_code      = entry_exc_code[head];
            retire_u_exc_has_error = entry_exc_has_error[head];
            retire_count        = 2'd1;

            // V retires only if both U and V are exception-free (precise exceptions)
            if (can_retire_v) begin
                retire_v.instr      = entry_instr[head_plus1];
                retire_v.data       = entry_data[head_plus1];
                retire_v.ready      = 1'b1;
                retire_v.valid      = 1'b1;
                retire_v_valid      = 1'b1;
                retire_v_flags      = entry_flags[head_plus1];
                retire_v_flags_mask = entry_flags_mask[head_plus1];
                retire_v_is_store   = (entry_instr[head_plus1].op_cat == OP_STORE);
                retire_v_has_exc       = entry_exception[head_plus1];
                retire_v_exc_vector    = entry_exc_vector[head_plus1];
                retire_v_exc_code      = entry_exc_code[head_plus1];
                retire_v_exc_has_error = entry_exc_has_error[head_plus1];
                retire_count        = 2'd2;
            end
        end
    end

    // =========================================================
    // Unified Sequential Block (Dispatch + CDB + Retirement + SpecBits)
    // =========================================================
    // Merged into a single always_ff to avoid Quartus multiple-driver errors
    // on shared arrays (entry_valid, entry_complete, entry_data, etc.).
    //
    // Priority (last-write-wins in NBA semantics):
    //   1. Dispatch writes new entries at tail
    //   2. CDB writeback marks entries complete
    //   3. Retirement clears entry_valid at head
    //   4. SpecBits squash can also clear entry_valid
    integer rob_i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tail            <= '0;
            head            <= '0;
            entry_valid     <= '0;
            entry_complete  <= '0;
            entry_exception    <= '0;
            entry_exc_has_error <= '0;
        end else if (flush) begin
            tail            <= '0;
            head            <= '0;
            entry_valid     <= '0;
            entry_complete  <= '0;
            entry_exception    <= '0;
            entry_exc_has_error <= '0;
        end else begin
            // --- Dispatch (tail advances) ---
            if (!full) begin
                if (dispatch_u_valid) begin
                    entry_instr[tail]      <= dispatch_u;
                    entry_data[tail]       <= 32'd0;
                    entry_flags[tail]      <= 6'd0;
                    entry_flags_mask[tail] <= 6'd0;
                    entry_old_phys[tail]   <= dispatch_u_old_phys;
                    entry_lq_idx[tail]     <= dispatch_u_lq_idx;
                    entry_sq_idx[tail]     <= dispatch_u_sq_idx;
                    entry_specbits[tail]   <= dispatch_u_specbits;
                    entry_ftq_idx[tail]    <= dispatch_u_ftq_idx;
                    entry_valid[tail]      <= 1'b1;
                    entry_complete[tail]   <= 1'b0;
                    entry_exception[tail]  <= 1'b0;
                end
                if (dispatch_v_valid) begin
                    entry_instr[v_slot]      <= dispatch_v;
                    entry_data[v_slot]       <= 32'd0;
                    entry_flags[v_slot]      <= 6'd0;
                    entry_flags_mask[v_slot] <= 6'd0;
                    entry_old_phys[v_slot]   <= dispatch_v_old_phys;
                    entry_lq_idx[v_slot]     <= dispatch_v_lq_idx;
                    entry_sq_idx[v_slot]     <= dispatch_v_sq_idx;
                    entry_specbits[v_slot]   <= dispatch_v_specbits;
                    entry_ftq_idx[v_slot]    <= dispatch_v_ftq_idx;
                    entry_valid[v_slot]      <= 1'b1;
                    entry_complete[v_slot]   <= 1'b0;
                    entry_exception[v_slot]  <= 1'b0;
                end
                tail <= tail + rob_id_t'(dispatch_count);
            end

            // --- CDB Writeback (mark entries complete) ---
            // Accept CDB for entries that are valid OR being dispatched this
            // cycle (same-cycle V-pipe completion: dispatch + CDB in one clock).
            if (cdb0_valid && (entry_valid[cdb0_tag] ||
                    (dispatch_u_valid && !full && cdb0_tag == tail) ||
                    (dispatch_v_valid && !full && cdb0_tag == v_slot))) begin
                entry_complete[cdb0_tag]   <= 1'b1;
                entry_data[cdb0_tag]       <= cdb0_data;
                entry_flags[cdb0_tag]      <= cdb0_flags;
                entry_flags_mask[cdb0_tag] <= cdb0_flags_mask;
                entry_exception[cdb0_tag]     <= cdb0_exception;
                entry_exc_vector[cdb0_tag]    <= cdb0_exc_vector;
                entry_exc_code[cdb0_tag]      <= cdb0_exc_code;
                entry_exc_has_error[cdb0_tag] <= cdb0_exc_has_error;
            end
            if (cdb1_valid && (entry_valid[cdb1_tag] ||
                    (dispatch_u_valid && !full && cdb1_tag == tail) ||
                    (dispatch_v_valid && !full && cdb1_tag == v_slot))) begin
                entry_complete[cdb1_tag]      <= 1'b1;
                entry_data[cdb1_tag]          <= cdb1_data;
                entry_flags[cdb1_tag]         <= cdb1_flags;
                entry_flags_mask[cdb1_tag]    <= cdb1_flags_mask;
                entry_exception[cdb1_tag]     <= cdb1_exception;
                entry_exc_vector[cdb1_tag]    <= cdb1_exc_vector;
                entry_exc_code[cdb1_tag]      <= cdb1_exc_code;
                entry_exc_has_error[cdb1_tag] <= cdb1_exc_has_error;
            end

            // --- SpecBits: clear resolved branch bit from all entries ---
            if (specbits_resolve_valid) begin
                for (rob_i = 0; rob_i < N; rob_i = rob_i + 1) begin
                    if (entry_valid[rob_i])
                        entry_specbits[rob_i][specbits_resolve_tag] <= 1'b0;
                end
            end

            // --- SpecBits: squash entries that depend on mispredicted branch ---
            if (specbits_squash_valid) begin
                for (rob_i = 0; rob_i < N; rob_i = rob_i + 1) begin
                    if (entry_valid[rob_i] && |(entry_specbits[rob_i] & specbits_squash_mask)) begin
                        entry_valid[rob_i] <= 1'b0;
                    end
                end
            end

            // --- Retirement (head advances, frees slots) ---
            if (retire_u_valid) begin
                entry_valid[head] <= 1'b0;
                if (retire_v_valid)
                    entry_valid[head_plus1] <= 1'b0;
            end
            head <= head + rob_id_t'(retire_count);
        end
    end

    // =========================================================
    // Occupancy Counter
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= '0;
        end else if (flush) begin
            count <= '0;
        end else begin
            count <= count + (ROB_ID_WIDTH+1)'(dispatch_count)
                           - (ROB_ID_WIDTH+1)'(retire_count);
        end
    end

endmodule
