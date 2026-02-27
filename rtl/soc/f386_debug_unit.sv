/*
 * fabi386: Hardware Debug Unit (HDU) - v2.1
 * Provides "Invisible" hardware breakpoints and watchpoints.
 * v2.1: Added Host-Side Programming Interface for internal debuggers.
 */

import f386_pkg::*;

module f386_debug_unit (
    input  wire         clk,
    input  wire         reset_n,

    // Core Monitoring
    input  wire [31:0]  curr_pc,
    input  wire         pc_valid,
    input  instr_info_t instr_info,

    // Bus Monitoring (for Watchpoints)
    input  wire [31:0]  bus_addr,
    input  wire [31:0]  bus_data,
    input  wire         bus_req,
    input  wire         bus_ack,
    input  wire         bus_we,

    // --- Control Inputs ---
    // Source A: fabi386 Console (External UART/JTAG)
    input  wire [31:0]  ext_trig_pc      [3:0],
    input  wire [3:0]   ext_trig_en,

    // Source B: Host CPU (Internal MSR/IO Bridge)
    input  wire [31:0]  host_trig_pc    [3:0],
    input  wire [3:0]   host_trig_en,
    input  wire         host_unlock,     // Must be high to allow host control

    // Control
    output reg          debug_halt,  // Freezes the CPU Pipeline
    output reg          debug_irq    // Signal to fabi386 Supervisor (Host IRQ)
);

    // Active Trigger Sets (Muxed between External and Host)
    wire [31:0] active_pc [3:0];
    wire [3:0]  active_en;

    genvar j;
    generate
        for (j = 0; j < 4; j++) begin : trigger_mux
            assign active_pc[j] = (host_unlock && host_trig_en[j]) ? host_trig_pc[j] : ext_trig_pc[j];
            assign active_en[j] = (host_unlock) ? (host_trig_en[j] | ext_trig_en[j]) : ext_trig_en[j];
        end
    endgenerate

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            debug_halt <= 0;
            debug_irq  <= 0;
        end else begin
            debug_halt <= 0;
            debug_irq  <= 0;

            for (int i = 0; i < 4; i++) begin
                if (active_en[i]) begin
                    // 1. Hardware PC Breakpoint
                    if (pc_valid && curr_pc == active_pc[i]) begin
                        debug_halt <= 1;
                        debug_irq  <= 1; // Traps the host if configured
                    end

                    // 2. Data Watchpoint Logic (Simplified for brevity)
                    // [Watchpoint logic mirrors the PC match logic above]
                end
            end
        end
    end

endmodule
