/*
 * fabi386: RTC (Real-Time Clock) Stub - v1.0
 * --------------------------------------------
 * Minimal MC146818 / DS1287 RTC stub for DOS compatibility.
 * Responds to I/O ports 0x70 (CMOS address) and 0x71 (CMOS data).
 *
 * Returns a fixed date/time of 2024-01-01 00:00:00 (Monday).
 * All CMOS RAM reads beyond the RTC registers return 0x00.
 * NMI mask bit (port 0x70 bit 7) is captured but not acted upon.
 *
 * DOS reads the RTC at boot for date/time initialization.
 * A full RTC with battery-backed CMOS RAM is deferred to Phase P2.
 */

import f386_pkg::*;

module f386_rtc_stub (
    input  logic        clk,
    input  logic        rst_n,

    // I/O port interface
    input  logic [15:0] io_addr,
    input  logic [7:0]  io_wdata,
    output logic [7:0]  io_rdata,
    input  logic        io_wr,
    input  logic        io_rd,
    input  logic        io_cs,
    // NMI mask (active when bit 7 of port 0x70 write is set)
    output logic        nmi_mask
);

    // CMOS address register (bits [6:0] = register index, bit 7 = NMI mask)
    logic [7:0] cmos_addr;
    assign nmi_mask = cmos_addr[7];

    // ---- Fixed RTC time: 2024-01-01 00:00:00 (BCD format) ----
    // MC146818 register map (standard offsets):
    //   0x00 = Seconds        0x02 = Minutes        0x04 = Hours
    //   0x06 = Day of Week    0x07 = Day of Month   0x08 = Month
    //   0x09 = Year           0x0A = Status Reg A    0x0B = Status Reg B
    //   0x0C = Status Reg C   0x0D = Status Reg D    0x32 = Century (IBM)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmos_addr <= 8'h00;
            io_rdata  <= 8'h00;
        end else begin
            // Port 0x70: CMOS address register (write-only from CPU perspective)
            if (io_cs && io_wr && io_addr == 16'h0070)
                cmos_addr <= io_wdata;

            // Port 0x71: CMOS data register (read/write)
            if (io_cs && io_rd && io_addr == 16'h0071) begin
                case (cmos_addr[6:0])
                    7'h00:   io_rdata <= 8'h00;  // Seconds       = 00
                    7'h02:   io_rdata <= 8'h00;  // Minutes       = 00
                    7'h04:   io_rdata <= 8'h00;  // Hours         = 00 (24h)
                    7'h06:   io_rdata <= 8'h02;  // Day of Week   = Monday (2)
                    7'h07:   io_rdata <= 8'h01;  // Day of Month  = 01
                    7'h08:   io_rdata <= 8'h01;  // Month         = 01 (January)
                    7'h09:   io_rdata <= 8'h24;  // Year          = 24 (2024)
                    7'h0A:   io_rdata <= 8'h26;  // Status A: UIP=0, divider=010, rate=0110
                    7'h0B:   io_rdata <= 8'h02;  // Status B: 24h mode, BCD format
                    7'h0C:   io_rdata <= 8'h00;  // Status C: no IRQ pending
                    7'h0D:   io_rdata <= 8'h80;  // Status D: valid RAM, battery OK
                    7'h32:   io_rdata <= 8'h20;  // Century       = 20 (BCD)
                    default: io_rdata <= 8'h00;  // All other CMOS RAM = 0
                endcase
            end
        end
    end

endmodule
