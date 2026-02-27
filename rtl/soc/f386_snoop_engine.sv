/*
 * fabi386: Bus Master Snoop Engine
 * Monitors external ISA/Motherboard bus for DMA writes to maintain
 * coherency between legacy adapter RAM and internal HyperRAM shadows.
 */

import f386_pkg::*;

module f386_snoop_engine (
    input  wire         clk_core,
    input  wire         reset_n,

    // Motherboard Bus Monitoring
    input  wire [31:0]  m_addr,
    input  wire         m_ads_n,
    input  wire         m_wr_n,     // High for Read, Low for Write
    input  wire         m_hlda,     // Hold Acknowledge (CPU is tri-stated, Master is active)

    // Cache/MMU Coherency Interface
    output reg  [31:0]  snoop_addr,
    output reg          snoop_invalidate,
    output reg          snoop_update_req
);

    // Logic: If HLDA is high, another device (DMA/Bus Master) owns the bus.
    // If that device performs a WRITE (m_wr_n == 0), we must check our shadows.

    always_ff @(posedge clk_core or negedge reset_n) begin
        if (!reset_n) begin
            snoop_invalidate <= 0;
            snoop_update_req <= 0;
        end else begin
            snoop_invalidate <= 0;
            snoop_update_req <= 0;

            // Detect an external write cycle while CPU is on 'HOLD'
            if (m_hlda && !m_ads_n && !m_wr_n) begin
                snoop_addr <= m_addr;

                // For L1 Cache: Always invalidate to be safe
                snoop_invalidate <= 1;

                // For HyperRAM Shadow: Trigger a background update to pull the new
                // data from the ISA bus into our high-speed internal copy.
                snoop_update_req <= 1;
            end
        end
    end

endmodule
