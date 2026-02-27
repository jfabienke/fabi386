/*
 * fabi386: Data Structure Inference / Stride Detector (v18.0)
 * ------------------------------------------------------------
 * Monitors bus address offsets to detect linear memory access patterns.
 * Identifies arrays of bytes, words, and structs for telemetry export.
 *
 * When the same stride is seen 4 consecutive times, emits the detected
 * stride value and estimated base address.
 *
 * Adapted from Neo-386 Pro n386_stride_detector.
 */

import f386_pkg::*;

module f386_stride_detector (
    input  logic         clk,
    input  logic         reset_n,

    // Internal bus monitoring
    input  logic [31:0]  bus_addr,
    input  logic         bus_req,
    input  logic         bus_ack,

    // Inference output
    output logic [31:0]  stride_val,
    output logic [31:0]  stride_base,
    output logic         stride_valid
);

    logic [31:0] last_addr;
    logic [31:0] last_delta;
    logic [31:0] current_delta;
    logic [7:0]  confidence;

    assign current_delta = bus_addr - last_addr;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            confidence   <= 8'd0;
            stride_valid <= 1'b0;
            stride_val   <= 32'd0;
            stride_base  <= 32'd0;
            last_addr    <= 32'd0;
            last_delta   <= 32'd0;
        end else begin
            stride_valid <= 1'b0;

            if (bus_req && bus_ack) begin
                if (current_delta == last_delta && current_delta != 32'd0) begin
                    if (confidence < 8'hFF)
                        confidence <= confidence + 8'd1;

                    // Threshold: 4 consecutive matching strides = array detected
                    if (confidence == 8'd3) begin
                        stride_valid <= 1'b1;
                        stride_val   <= current_delta;
                        stride_base  <= last_addr - {current_delta[29:0], 2'b00};
                    end
                end else begin
                    confidence <= 8'd0;
                    last_delta <= current_delta;
                end

                last_addr <= bus_addr;
            end
        end
    end

endmodule
