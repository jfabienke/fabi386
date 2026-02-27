/*
 * fabi386: Stride-Aware L1 Pre-fetcher
 * Phase 7: Memory Latency Hiding
 * Automatically detects linear access patterns (strides) and
 * proactively pulls next lines from HyperRAM into the L1 cache.
 */

import f386_pkg::*;

module f386_prefetch_unit (
    input  logic         clk,
    input  logic         reset_n,

    // Cache Access Monitor
    input  logic [31:0]  bus_addr,
    input  logic         bus_valid,
    input  logic         bus_ack,

    // Pre-fetch Request to BIU/HyperBus
    output logic [31:0]  prefetch_addr,
    output logic         prefetch_req,
    input  logic         prefetch_ack
);

    // Simple Stride Tracking
    logic [31:0] last_addr;
    logic [31:0] last_stride;
    logic [3:0]  confidence; // Counter to verify stride

    typedef enum logic [1:0] { IDLE, WAIT_ACK } state_t;
    state_t state;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            prefetch_req <= 0;
            confidence <= 0;
            last_addr <= 0;
            last_stride <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (bus_valid && bus_ack) begin
                        logic [31:0] current_stride = bus_addr - last_addr;

                        if (current_stride == last_stride && current_stride != 0) begin
                            if (confidence < 4'hF) confidence <= confidence + 1;
                        end else begin
                            confidence <= 0;
                            last_stride <= current_stride;
                        end

                        last_addr <= bus_addr;

                        // Trigger pre-fetch if we are confident in the stride
                        if (confidence > 4'd3) begin
                            prefetch_addr <= bus_addr + current_stride;
                            prefetch_req <= 1;
                            state <= WAIT_ACK;
                        end
                    end
                end

                WAIT_ACK: begin
                    if (prefetch_ack) begin
                        prefetch_req <= 0;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

endmodule
