/*
 * fabi386: MMU Shadow-Packing Unit (v2.0)
 * ----------------------------------------
 * Handles zero-wait-state address remapping for 386 compatibility.
 */

import f386_pkg::*;

module f386_mmu_remap (
    input  logic [31:0]  addr_in,
    output logic [31:0]  addr_out,
    output mem_class_t   m_class
);

    // 8 Programmable Shadow Gates
    // Redirections for 0xA0000 (VGA), 0xC0000 (BIOS), etc.

    always_comb begin
        addr_out = addr_in;
        m_class  = CLASS_INTERNAL;

        // VGA Hole
        if (addr_in >= 32'h000A0000 && addr_in <= 32'h000BFFFF) begin
            m_class = CLASS_MMIO;
        end

        // Option ROM Redirection (Shadowing)
        if (addr_in >= 32'h000C0000 && addr_in <= 32'h000EFFFF) begin
            addr_out = 32'h10000000 + (addr_in - 32'h000C0000);
            m_class  = CLASS_INTERNAL;
        end
    end

endmodule
