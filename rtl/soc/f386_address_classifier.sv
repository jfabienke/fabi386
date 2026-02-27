/*
 * fabi386: Address Space Classifier (PASC)
 * Identifies memory types (SRAM, MMIO, External RAM) by measuring
 * bus transaction latency and handshake patterns.
 */

import f386_pkg::*;

module f386_address_classifier (
    input  wire         clk_core,   // 150MHz
    input  wire         reset_n,

    // BIU Interface Monitor
    input  wire [31:0]  m_addr,
    input  wire         m_ads_n,
    input  wire         m_ready_n,
    input  wire         m_is_io,

    // Classification Output
    output reg [2:0]    mem_class, // 0:Internal, 1:Ext_RAM, 2:SRAM, 3:MMIO, 4:HOLE
    output reg          class_valid
);

    reg [15:0] latency_counter;
    reg        measuring;

    // Thresholds (Cycle counts at 150MHz)
    localparam THRESH_RAM  = 16'd20;  // Motherboard RAM usually < 150ns
    localparam THRESH_SRAM = 16'd60;  // ISA Cards usually > 400ns
    localparam THRESH_HOLE = 16'd500; // Timeout

    always_ff @(posedge clk_core or negedge reset_n) begin
        if (!reset_n) begin
            measuring <= 0;
            class_valid <= 0;
        end else begin
            class_valid <= 0;

            // Start measurement on ADS# pulse
            if (!m_ads_n && !measuring) begin
                measuring <= 1;
                latency_counter <= 0;
            end

            if (measuring) begin
                if (!m_ready_n) begin // Motherboard finished transaction
                    measuring <= 0;
                    class_valid <= 1;

                    // Classify based on how long the legacy hardware took
                    if (latency_counter < THRESH_RAM)
                        mem_class <= 3'd1; // Ext_RAM
                    else if (latency_counter < THRESH_SRAM)
                        mem_class <= 3'd2; // ADPT_SRAM
                    else
                        mem_class <= 3'd3; // Slow MMIO / Buffer
                end else if (latency_counter > THRESH_HOLE) begin
                    measuring <= 0;
                    class_valid <= 1;
                    mem_class <= 3'd4; // HOLE (No hardware responded)
                end else begin
                    latency_counter <= latency_counter + 1;
                end
            end
        end
    end

endmodule
