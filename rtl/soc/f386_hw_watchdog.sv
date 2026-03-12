/*
 * fabi386: Hardware Watchdog / NMI Timeout (P3.WDG)
 * --------------------------------------------------
 * Configurable 24-bit countdown timer that fires a single-cycle NMI pulse
 * when the core fails to retire any instruction within ~16M cycles.
 *
 * Reset sources:
 *   - heartbeat (any valid U-pipe retirement)
 *   - !enable (holds counter at max, no timeout)
 *
 * NMI vector: 2 (consumed by exception unit when NMI path is wired).
 */

import f386_pkg::*;

module f386_hw_watchdog (
    input  logic        clk,
    input  logic        rst_n,

    // Configuration
    input  logic        enable,           // Gate: CONF_ENABLE_HW_WATCHDOG

    // Heartbeat (reset on valid retirement)
    input  logic        heartbeat,        // rob_retire_u_valid

    // NMI output
    output logic        nmi_timeout       // Asserted for 1 cycle on timeout
);

    localparam int COUNTER_WIDTH = 24;
    localparam logic [COUNTER_WIDTH-1:0] COUNTER_MAX = {COUNTER_WIDTH{1'b1}};  // 2^24 - 1

    logic [COUNTER_WIDTH-1:0] count_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            count_r     <= COUNTER_MAX;
            nmi_timeout <= 1'b0;
        end else if (!enable) begin
            // Gate off: hold at max, no timeout
            count_r     <= COUNTER_MAX;
            nmi_timeout <= 1'b0;
        end else if (heartbeat) begin
            // Any valid retirement resets the countdown
            count_r     <= COUNTER_MAX;
            nmi_timeout <= 1'b0;
        end else if (count_r == {COUNTER_WIDTH{1'b0}}) begin
            // Timeout: fire NMI for 1 cycle, then reload
            count_r     <= COUNTER_MAX;
            nmi_timeout <= 1'b1;
        end else begin
            // Normal countdown
            count_r     <= count_r - 1'b1;
            nmi_timeout <= 1'b0;
        end
    end

endmodule
