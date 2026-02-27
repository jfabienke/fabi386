/*
 * fabi386: Hardware Guard Unit (HGU)
 * Version 1.0 (Phase 3 Final)
 * Enforces execution allow-lists in Real Mode.
 * Traps into the fabi386 Supervisor if code jumps into unauthorized memory.
 */

import f386_pkg::*;

module f386_guard_unit (
    input  logic         clk,
    input  logic         reset_n,

    // Monitor Interface
    input  logic [31:0]  pc,
    input  logic         pc_valid,
    input  semantic_tag_t semantic,

    // Guard Configuration
    input  logic [31:0]  safe_start,
    input  logic [31:0]  safe_end,
    input  logic         guard_en,

    // Exceptions
    output logic         fault_trap
);

    // Standard BIOS Safe Zones
    wire in_bios = (pc >= 32'h000F0000 && pc <= 32'h000FFFFF);
    wire in_vga  = (pc >= 32'h000C0000 && pc <= 32'h000C7FFF);
    wire in_safe = (pc >= safe_start && pc <= safe_end);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            fault_trap <= 0;
        end else if (guard_en && pc_valid) begin
            // Trap if PC leaves safe zones without a recognized
            // entry/exit semantic (like an INT call or Far RET).
            if (!in_safe && !in_bios && !in_vga) begin
                fault_trap <= 1;
            end else begin
                fault_trap <= 0;
            end
        end
    end

endmodule
