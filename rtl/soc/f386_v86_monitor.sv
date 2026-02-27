/*
 * fabi386: V86 Monitor Unit
 * Tracks transitions between Protected Mode and V86 Mode.
 * Enriches telemetry with Virtual-Machine state information.
 */

import f386_pkg::*;

module f386_v86_monitor (
    input  wire         clk,
    input  wire         reset_n,

    // CPU State
    input  wire [31:0]  eflags,     // CPU EFLAGS Register
    input  wire         pe_mode,    // CR0.PE
    input  wire         pc_valid,

    // Telemetry Output
    output reg          is_v86,
    output semantic_tag_t v86_tag
);

    // EFLAGS Bit 17 is the VM (Virtual 8086) bit
    wire vm_bit = eflags[17];

    // Logic: V86 is active only if Protected Mode is ON and VM bit is SET
    wire v86_active = pe_mode && vm_bit;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            is_v86 <= 0;
            v86_tag <= SEM_NONE;
        end else begin
            v86_tag <= SEM_NONE;

            if (pc_valid) begin
                if (v86_active && !is_v86) begin
                    // Just entered V86 Mode
                    v86_tag <= SEM_V86_ENTER;
                end else if (!v86_active && is_v86) begin
                    // Just exited V86 Mode (Trap to Monitor)
                    v86_tag <= SEM_V86_EXIT;
                end
                is_v86 <= v86_active;
            end
        end
    end

endmodule
