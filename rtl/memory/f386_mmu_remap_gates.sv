/*
 * fabi386: MMU Address Remapping Table
 * Implements "Shadow-Packing" for Option ROMs and UMB Optimization.
 * Redirects CPU addresses to compacted HyperRAM physical addresses.
 */

import f386_pkg::*;

module f386_mmu_remap_gates (
    input  wire         clk,
    input  wire         reset_n,

    // CPU Request
    input  wire [31:0]  cpu_addr,
    input  wire         cpu_req,

    // Remap Configuration (Set by fabi386 Supervisor)
    // We provide 8 programmable "Shadow Gates" for ROM relocation
    input  wire [31:0]  gate_start  [7:0],
    input  wire [31:0]  gate_end    [7:0],
    input  wire [31:0]  gate_offset [7:0], // Physical Offset in HyperRAM
    input  wire [7:0]   gate_en,

    // Output Address
    output reg  [31:0]  phys_addr,
    output reg          is_remapped
);

    // Logic to detect an address hit in one of the gates
    // This must be extremely fast to avoid adding wait-states
    always_comb begin
        phys_addr   = cpu_addr; // Default: 1:1 Mapping
        is_remapped = 0;

        // Priority Encoder for the 8 Shadow Gates
        for (int i = 0; i < 8; i++) begin
            if (gate_en[i] && (cpu_addr >= gate_start[i]) && (cpu_addr <= gate_end[i])) begin
                // Translate: New Addr = Base Offset + (Original Addr - Start)
                phys_addr   = gate_offset[i] + (cpu_addr - gate_start[i]);
                is_remapped = 1;
            end
        end
    end

endmodule
