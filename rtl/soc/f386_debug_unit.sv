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
    input  wire [31:0]  ext_trig_pc_0,
    input  wire [31:0]  ext_trig_pc_1,
    input  wire [31:0]  ext_trig_pc_2,
    input  wire [31:0]  ext_trig_pc_3,
    input  wire [3:0]   ext_trig_en,

    // Source B: Host CPU (Internal MSR/IO Bridge)
    input  wire [31:0]  host_trig_pc_0,
    input  wire [31:0]  host_trig_pc_1,
    input  wire [31:0]  host_trig_pc_2,
    input  wire [31:0]  host_trig_pc_3,
    input  wire [3:0]   host_trig_en,
    input  wire         host_unlock,     // Must be high to allow host control

    // Control
    output reg          debug_halt,  // Freezes the CPU Pipeline
    output reg          debug_irq    // Signal to fabi386 Supervisor (Host IRQ)
);

    // Active Trigger Sets (Muxed between External and Host)
    wire [31:0] active_pc [0:3];
    wire [3:0]  active_en;

    assign active_pc[0] = (host_unlock && host_trig_en[0]) ? host_trig_pc_0 : ext_trig_pc_0;
    assign active_pc[1] = (host_unlock && host_trig_en[1]) ? host_trig_pc_1 : ext_trig_pc_1;
    assign active_pc[2] = (host_unlock && host_trig_en[2]) ? host_trig_pc_2 : ext_trig_pc_2;
    assign active_pc[3] = (host_unlock && host_trig_en[3]) ? host_trig_pc_3 : ext_trig_pc_3;

    assign active_en[0] = host_unlock ? (host_trig_en[0] | ext_trig_en[0]) : ext_trig_en[0];
    assign active_en[1] = host_unlock ? (host_trig_en[1] | ext_trig_en[1]) : ext_trig_en[1];
    assign active_en[2] = host_unlock ? (host_trig_en[2] | ext_trig_en[2]) : ext_trig_en[2];
    assign active_en[3] = host_unlock ? (host_trig_en[3] | ext_trig_en[3]) : ext_trig_en[3];

    integer i;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            debug_halt <= 1'b0;
            debug_irq  <= 1'b0;
        end else begin
            debug_halt <= 1'b0;
            debug_irq  <= 1'b0;

            for (i = 0; i < 4; i = i + 1) begin
                if (active_en[i]) begin
                    // 1. Hardware PC Breakpoint
                    if (pc_valid && curr_pc == active_pc[i]) begin
                        debug_halt <= 1'b1;
                        debug_irq  <= 1'b1; // Traps the host if configured
                    end

                    // 2. Data Watchpoint Logic (Simplified for brevity)
                    // [Watchpoint logic mirrors the PC match logic above]
                end
            end
        end
    end

endmodule
