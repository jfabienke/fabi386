/*
 * fabi386: Physical Address Space Characterization (PASC)
 * Version 1.0 (Locked for Phase 3)
 * Measures bus transaction latency to identify memory types:
 * - Internal (HyperRAM): ~40ns
 * - External (MB RAM): ~120ns
 * - Adapter (SRAM/VRAM): >300ns
 */

import f386_pkg::*;

module f386_pasc_classifier (
    input  logic         clk_core,   // 150MHz Internal
    input  logic         reset_n,

    // External Bus Monitor (Asynchronous pins from Motherboard)
    input  logic         m_ads_n,    // Address Status
    input  logic         m_ready_n,  // Ready signal
    input  logic [31:0]  m_addr,

    // Internal Telemetry Output
    output mem_class_t   phys_class,
    output logic [15:0]  measured_latency,
    output logic         class_valid
);

    // Latency thresholds (Cycles @ 150MHz)
    localparam LAT_INT   = 16'd10;   // < 66ns
    localparam LAT_RAM   = 16'd30;   // < 200ns
    localparam LAT_ADPT  = 16'd100;  // < 660ns
    localparam LAT_HOLE  = 16'd1000; // Timeout

    typedef enum logic [1:0] { IDLE, COUNTING, DONE } state_t;
    state_t state;

    logic [15:0] timer;

    always_ff @(posedge clk_core or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            class_valid <= 0;
            timer <= 0;
            phys_class <= CLASS_INTERNAL;
        end else begin
            case (state)
                IDLE: begin
                    class_valid <= 0;
                    if (!m_ads_n) begin
                        timer <= 0;
                        state <= COUNTING;
                    end
                end

                COUNTING: begin
                    if (!m_ready_n) begin
                        measured_latency <= timer;
                        class_valid <= 1;
                        state <= DONE;

                        // Classification logic
                        if (timer < LAT_INT)
                            phys_class <= CLASS_INTERNAL;
                        else if (timer < LAT_RAM)
                            phys_class <= CLASS_EXT_RAM;
                        else
                            phys_class <= CLASS_ADPT_MEM;
                    end else if (timer >= LAT_HOLE) begin
                        measured_latency <= timer;
                        class_valid <= 1;
                        phys_class <= CLASS_HOLE;
                        state <= DONE;
                    end else begin
                        timer <= timer + 1;
                    end
                end

                DONE: begin
                    if (m_ads_n) state <= IDLE;
                    class_valid <= 0;
                end
            endcase
        end
    end

endmodule
