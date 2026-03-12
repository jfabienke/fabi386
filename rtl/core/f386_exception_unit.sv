/*
 * fabi386: Exception Priority Unit
 * -----------------------------------
 * Handles x86 exception priority encoding, precise exception delivery
 * at retirement, and double/triple fault detection.
 *
 * Exception priority (highest first, per Intel SDM):
 *   #DB (1) > #BP (3) > #UD (6) > #NM (7) > #DF (8) >
 *   #TS (10) > #NP (11) > #SS (12) > #GP (13) > #PF (14) > #AC (17)
 *
 * Design:
 *   - Exceptions are recorded speculatively per ROB entry
 *   - Only the oldest (head) entry's exception is delivered at retirement
 *   - Delivery triggers microcode: push EFLAGS/CS/EIP, read IDT, jump
 *   - Double fault: exception during exception delivery → #DF (vector 8)
 *   - Triple fault: exception during #DF delivery → CPU reset
 *
 * Reference: ao486_MiSTer/rtl/ao486/exception.v
 */

import f386_pkg::*;

module f386_exception_unit (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         flush,

    // --- Exception Sources (from execute stage / TLB / microcode) ---
    input  logic         exc_from_exec,      // Execute stage exception
    input  logic [7:0]   exc_exec_vector,
    input  logic [31:0]  exc_exec_error_code,
    input  logic         exc_exec_has_error,
    input  rob_id_t      exc_exec_rob_tag,

    input  logic         exc_from_tlb,       // Page fault from TLB
    input  logic [31:0]  exc_tlb_fault_addr, // CR2 value
    input  logic [3:0]   exc_tlb_fault_code, // {RSVD, U/S, W/R, P}
    input  rob_id_t      exc_tlb_rob_tag,

    // --- Retirement Interface ---
    input  logic         retire_valid,       // Head of ROB is retiring
    input  rob_id_t      retire_rob_tag,
    input  logic [31:0]  retire_pc,          // PC of retiring instruction
    input  logic         retire_has_exc,     // This entry has an exception
    input  logic [7:0]   retire_exc_vector,  // P3.EXC.b: from ROB exception metadata
    input  logic [31:0]  retire_exc_code,
    input  logic         retire_exc_has_error,

    // --- Microcode completion feedback ---
    input  logic         microcode_done,     // P3.EXC.b: exception handler complete

    // --- Exception Delivery (to microcode sequencer) ---
    output logic         deliver_exc,        // Start exception delivery
    output logic [7:0]   deliver_vector,     // Exception vector
    output logic [31:0]  deliver_error_code, // Error code
    output logic         deliver_has_error,
    output logic [31:0]  deliver_eip,        // Faulting EIP (return address)

    // --- CR2 Update (for #PF) ---
    output logic         cr2_we,
    output logic [31:0]  cr2_value,

    // --- Triple Fault (CPU reset) ---
    output logic         triple_fault,

    // --- Status ---
    output logic         handling_exception,  // Exception delivery in progress
    output logic         handling_double_fault
);

    // =========================================================
    // Exception State Machine
    // =========================================================
    typedef enum logic [2:0] {
        EXC_IDLE       = 3'd0,
        EXC_DELIVER    = 3'd1,  // Delivering exception via microcode
        EXC_WAIT_DONE  = 3'd2,  // Waiting for microcode to finish
        EXC_DOUBLE     = 3'd3,  // Double fault delivery
        EXC_TRIPLE     = 3'd4   // Triple fault → reset
    } exc_state_t;

    exc_state_t state;

    // Pending exception storage (per ROB tag)
    // For simplicity, store just the current exception being delivered
    logic [7:0]  pending_vector;
    logic [31:0] pending_error_code;
    logic        pending_has_error;
    logic [31:0] pending_eip;
    logic [31:0] pending_cr2;

    assign handling_exception    = (state != EXC_IDLE);
    assign handling_double_fault = (state == EXC_DOUBLE);
    assign triple_fault          = (state == EXC_TRIPLE);

    // =========================================================
    // Exception Priority Encoder
    // =========================================================
    // When multiple exceptions are pending, select highest priority.
    // This is used when both exec and TLB report exceptions on the same cycle.

    logic        final_exc_valid;
    logic [7:0]  final_exc_vector;
    logic [31:0] final_exc_error_code;
    logic        final_exc_has_error;
    logic [31:0] final_exc_cr2;

    // Priority encoding function
    // Returns priority value (lower = higher priority)
    function automatic logic [4:0] exc_priority(input logic [7:0] vector);
        case (vector)
            EXC_DB: return 5'd1;
            EXC_BP: return 5'd3;
            EXC_UD: return 5'd6;
            EXC_NM: return 5'd7;
            EXC_DF: return 5'd8;
            EXC_TS: return 5'd10;
            EXC_NP: return 5'd11;
            EXC_SS: return 5'd12;
            EXC_GP: return 5'd13;
            EXC_PF: return 5'd14;
            EXC_AC: return 5'd17;
            EXC_DE: return 5'd0;
            default: return 5'd31;
        endcase
    endfunction

    // Vectors that push an error code
    function automatic logic exc_has_error_code(input logic [7:0] vector);
        case (vector)
            EXC_DF, EXC_TS, EXC_NP, EXC_SS, EXC_GP, EXC_PF, EXC_AC: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    // Select highest-priority exception from concurrent sources
    always_comb begin
        final_exc_valid      = 1'b0;
        final_exc_vector     = 8'd0;
        final_exc_error_code = 32'd0;
        final_exc_has_error  = 1'b0;
        final_exc_cr2        = 32'd0;

        if (exc_from_tlb && exc_from_exec) begin
            // Both sources — pick higher priority
            if (exc_priority(EXC_PF) < exc_priority(exc_exec_vector)) begin
                final_exc_valid      = 1'b1;
                final_exc_vector     = EXC_PF;
                final_exc_error_code = {28'd0, exc_tlb_fault_code};
                final_exc_has_error  = 1'b1;
                final_exc_cr2        = exc_tlb_fault_addr;
            end else begin
                final_exc_valid      = 1'b1;
                final_exc_vector     = exc_exec_vector;
                final_exc_error_code = exc_exec_error_code;
                final_exc_has_error  = exc_exec_has_error;
            end
        end else if (exc_from_tlb) begin
            final_exc_valid      = 1'b1;
            final_exc_vector     = EXC_PF;
            final_exc_error_code = {28'd0, exc_tlb_fault_code};
            final_exc_has_error  = 1'b1;
            final_exc_cr2        = exc_tlb_fault_addr;
        end else if (exc_from_exec) begin
            final_exc_valid      = 1'b1;
            final_exc_vector     = exc_exec_vector;
            final_exc_error_code = exc_exec_error_code;
            final_exc_has_error  = exc_exec_has_error;
        end
    end

    // =========================================================
    // Exception Delivery FSM
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= EXC_IDLE;
            deliver_exc  <= 1'b0;
            cr2_we       <= 1'b0;
        end else if (flush) begin
            state        <= EXC_IDLE;
            deliver_exc  <= 1'b0;
            cr2_we       <= 1'b0;
        end else begin
            deliver_exc <= 1'b0;
            cr2_we      <= 1'b0;

            case (state)
                EXC_IDLE: begin
                    // Check for exception at retirement
                    if (retire_valid && retire_has_exc) begin
                        // Use ROB-provided exception metadata (already decided at CDB time)
                        pending_vector     <= retire_exc_vector;
                        pending_error_code <= retire_exc_code;
                        pending_has_error  <= retire_exc_has_error;
                        pending_eip        <= retire_pc;
                        pending_cr2        <= (retire_exc_vector == EXC_PF) ?
                                              exc_tlb_fault_addr : 32'd0;

                        // Deliver exception
                        deliver_exc        <= 1'b1;
                        deliver_vector     <= retire_exc_vector;
                        deliver_error_code <= retire_exc_code;
                        deliver_has_error  <= retire_exc_has_error;
                        deliver_eip        <= retire_pc;

                        // Update CR2 for #PF
                        if (retire_exc_vector == EXC_PF) begin
                            cr2_we    <= 1'b1;
                            cr2_value <= exc_tlb_fault_addr;
                        end

                        state <= EXC_DELIVER;
                    end
                end

                EXC_DELIVER: begin
                    // Monitor for exception during delivery → double fault
                    if (final_exc_valid) begin
                        // Exception during exception delivery
                        deliver_exc        <= 1'b1;
                        deliver_vector     <= EXC_DF;
                        deliver_error_code <= 32'd0;
                        deliver_has_error  <= 1'b1;
                        deliver_eip        <= pending_eip;
                        state              <= EXC_DOUBLE;
                    end else begin
                        // Normal delivery complete (microcode will signal done)
                        state <= EXC_WAIT_DONE;
                    end
                end

                EXC_WAIT_DONE: begin
                    // Wait for microcode exception handler to complete
                    if (microcode_done)
                        state <= EXC_IDLE;
                end

                EXC_DOUBLE: begin
                    // Exception during double fault → triple fault
                    if (final_exc_valid) begin
                        state <= EXC_TRIPLE;
                    end else begin
                        state <= EXC_WAIT_DONE;
                    end
                end

                EXC_TRIPLE: begin
                    // Triple fault: hold in reset state
                    // External logic must reset the CPU
                    // triple_fault output is asserted
                end

                default: state <= EXC_IDLE;
            endcase
        end
    end

endmodule
