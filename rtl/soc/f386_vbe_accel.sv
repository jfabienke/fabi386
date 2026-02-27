/*
 * fabi386: SVGA BitBlt Accelerator (Finalized)
 * Phase 6: SoC Acceleration
 * Added support for Solid Fills and Raster Operations (ROP).
 * Optimized for high-throughput block moves in HyperRAM.
 */

import f386_pkg::*;

module f386_svga_accel (
    input  logic         clk,
    input  logic         reset_n,

    // Command Interface (Memory-Mapped Registers)
    input  logic [31:0]  reg_src_addr,
    input  logic [31:0]  reg_dst_addr,
    input  logic [15:0]  reg_width,
    input  logic [15:0]  reg_height,
    input  logic [31:0]  reg_pattern,  // For Solid Fills
    input  logic [3:0]   reg_rop_mode, // 0:Copy, 1:XOR, 2:AND, 3:SolidFill
    input  logic         reg_start,
    output logic         reg_busy,

    // Master Interface to HyperRAM
    output logic [31:0]  hr_addr,
    output logic [31:0]  hr_data_o,
    input  logic [31:0]  hr_data_i,
    output logic         hr_req,
    output logic         hr_we,
    input  logic         hr_ack
);

    typedef enum logic [2:0] { IDLE, READ_SRC, WAIT_READ, WRITE_DST, WAIT_WRITE, NEXT_PIXEL } state_t;
    state_t state;

    logic [15:0] cur_x, cur_y;
    logic [31:0] pixel_src_data;
    logic [31:0] pixel_final_o;

    // Raster Operation Logic
    always_comb begin
        case (reg_rop_mode)
            4'd0:    pixel_final_o = pixel_src_data;                // Copy
            4'd1:    pixel_final_o = pixel_src_data ^ reg_pattern;  // XOR (Pattern)
            4'd2:    pixel_final_o = pixel_src_data & reg_pattern;  // AND (Pattern)
            4'd3:    pixel_final_o = reg_pattern;                   // Solid Fill
            default: pixel_final_o = pixel_src_data;
        endcase
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= IDLE;
            reg_busy <= 0;
            hr_req <= 0;
            cur_x <= 0;
            cur_y <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (reg_start) begin
                        reg_busy <= 1;
                        cur_x <= 0;
                        cur_y <= 0;
                        // Skip source read if doing a Solid Fill
                        state <= (reg_rop_mode == 3) ? WRITE_DST : READ_SRC;
                    end
                end

                READ_SRC: begin
                    hr_addr <= reg_src_addr + ((cur_y * reg_width) + cur_x) * 4;
                    hr_we <= 0;
                    hr_req <= 1;
                    state <= WAIT_READ;
                end

                WAIT_READ: begin
                    if (hr_ack) begin
                        hr_req <= 0;
                        pixel_src_data <= hr_data_i;
                        state <= WRITE_DST;
                    end
                end

                WRITE_DST: begin
                    hr_addr <= reg_dst_addr + ((cur_y * reg_width) + cur_x) * 4;
                    hr_data_o <= pixel_final_o;
                    hr_we <= 1;
                    hr_req <= 1;
                    state <= WAIT_WRITE;
                end

                WAIT_WRITE: begin
                    if (hr_ack) begin
                        hr_req <= 0;
                        state <= NEXT_PIXEL;
                    end
                end

                NEXT_PIXEL: begin
                    if (cur_x < reg_width - 1) begin
                        cur_x <= cur_x + 1;
                        state <= (reg_rop_mode == 3) ? WRITE_DST : READ_SRC;
                    end else if (cur_y < reg_height - 1) begin
                        cur_x <= 0;
                        cur_y <= cur_y + 1;
                        state <= (reg_rop_mode == 3) ? WRITE_DST : READ_SRC;
                    end else begin
                        reg_busy <= 0;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

endmodule
