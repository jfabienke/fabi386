/*
 * fabi386: Semantic Transition Logger (v1.0)
 * ---------------------------------------------
 * Zero-cycle hardware logger that captures mode transitions and
 * context-switching events at retirement, generating DMA-ready
 * log entries for the HARE instrumentation suite.
 *
 * Detects transitions by comparing current vs previous mode state:
 *   - PE mode changes (CR0.PE flip)
 *   - V86 mode enter/exit (EFLAGS.VM flip)
 *   - Ring transitions (CPL changes)
 *   - Exception delivery events
 *   - Shadow stack mismatches
 *
 * Each detected event generates a 128-bit log entry:
 *   [127:124] event_type (4-bit semantic_tag_t)
 *   [123:120] prev_cpl
 *   [119:116] new_cpl
 *   [115:112] flags (PE, VM, IF, NT)
 *   [111:80]  PC at transition
 *   [79:48]   EFLAGS snapshot
 *   [47:16]   CR0 snapshot
 *   [15:0]    CS selector
 *
 * Log entries are written to a small FIFO (8-deep) that the HARE
 * DMA engine drains asynchronously — zero pipeline stall cost.
 *
 * Reference: Neo-386 Pro semantic transition concept, HARE suite
 */

import f386_pkg::*;

module f386_semantic_logger (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         flush,

    // --- Mode State (current, from sys_regs) ---
    input  logic         pe_mode,
    input  logic         v86_mode,
    input  logic [1:0]   cpl,
    input  logic [31:0]  eflags,
    input  logic [31:0]  cr0,
    input  logic [15:0]  cs_sel,

    // --- Retirement Events ---
    input  logic         retire_valid,
    input  logic [31:0]  retire_pc,
    input  logic         retire_is_iret,     // IRET retiring
    input  logic         retire_is_int,      // INT/exception retiring

    // --- Exception Events ---
    input  logic         exc_delivered,       // Exception delivery started
    input  logic [7:0]   exc_vector,

    // --- Shadow Stack Events ---
    input  logic         shadow_mismatch,     // From f386_shadow_stack

    // --- Log Output FIFO ---
    output logic         log_valid,
    output logic [127:0] log_entry,
    input  logic         log_ready,          // DMA engine consumed entry
    output logic [3:0]   log_count           // Entries in FIFO
);

    // =========================================================================
    // Previous-Cycle State Tracking
    // =========================================================================
    logic        prev_pe;
    logic        prev_v86;
    logic [1:0]  prev_cpl;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_pe  <= 1'b0;
            prev_v86 <= 1'b0;
            prev_cpl <= 2'b00;
        end else if (retire_valid) begin
            prev_pe  <= pe_mode;
            prev_v86 <= v86_mode;
            prev_cpl <= cpl;
        end
    end

    // =========================================================================
    // Transition Detection
    // =========================================================================
    logic             event_detected;
    semantic_tag_t    event_type;

    always_comb begin
        event_detected = 1'b0;
        event_type     = SEM_NONE;

        if (retire_valid) begin
            // PE mode change (real ↔ protected)
            if (pe_mode != prev_pe) begin
                event_detected = 1'b1;
                event_type     = SEM_MODE_SW;
            end
            // V86 enter
            else if (v86_mode && !prev_v86) begin
                event_detected = 1'b1;
                event_type     = SEM_V86_ENTER;
            end
            // V86 exit
            else if (!v86_mode && prev_v86) begin
                event_detected = 1'b1;
                event_type     = SEM_V86_EXIT;
            end
            // Ring transition (CPL change)
            else if (cpl != prev_cpl) begin
                event_detected = 1'b1;
                if (retire_is_int)
                    event_type = SEM_INT_CALL;
                else if (retire_is_iret)
                    event_type = SEM_FAR_RET;
                else
                    event_type = SEM_MODE_SW;
            end
        end

        // Exception delivery (always log, regardless of mode change)
        if (exc_delivered) begin
            event_detected = 1'b1;
            event_type     = SEM_INT_CALL;
        end

        // Shadow stack mismatch (security event)
        if (shadow_mismatch) begin
            event_detected = 1'b1;
            event_type     = SEM_SMC;  // Reuse SMC tag for security events
        end
    end

    // =========================================================================
    // Log Entry Construction
    // =========================================================================
    logic [127:0] new_entry;

    always_comb begin
        new_entry = '0;
        new_entry[127:124] = event_type;
        new_entry[123:122] = prev_cpl;
        new_entry[121:120] = cpl;
        new_entry[115]     = pe_mode;
        new_entry[114]     = v86_mode;
        new_entry[113]     = eflags[EFLAGS_IF];
        new_entry[112]     = eflags[EFLAGS_NT];
        new_entry[111:80]  = retire_pc;
        new_entry[79:48]   = eflags;
        new_entry[47:16]   = cr0;
        new_entry[15:0]    = cs_sel;
    end

    // =========================================================================
    // Log FIFO (8-deep, 128-bit wide)
    // =========================================================================
    localparam int LOG_DEPTH = 8;
    localparam int LOG_PTR_W = $clog2(LOG_DEPTH);

    logic [127:0] fifo_mem [LOG_DEPTH];
    logic [LOG_PTR_W:0] wr_ptr, rd_ptr;

    wire [LOG_PTR_W-1:0] wr_addr = wr_ptr[LOG_PTR_W-1:0];
    wire [LOG_PTR_W-1:0] rd_addr = rd_ptr[LOG_PTR_W-1:0];

    wire fifo_empty = (wr_ptr == rd_ptr);
    wire fifo_full  = (wr_ptr[LOG_PTR_W-1:0] == rd_ptr[LOG_PTR_W-1:0]) &&
                      (wr_ptr[LOG_PTR_W]      != rd_ptr[LOG_PTR_W]);

    assign log_valid = !fifo_empty;
    assign log_entry = fifo_mem[rd_addr];
    assign log_count = wr_ptr - rd_ptr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else if (flush) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            // Write on event detection (drop if full — non-blocking)
            if (event_detected && !fifo_full) begin
                fifo_mem[wr_addr] <= new_entry;
                wr_ptr <= wr_ptr + 1'b1;
            end

            // Read when DMA engine consumes
            if (log_ready && log_valid) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
        end
    end

endmodule
