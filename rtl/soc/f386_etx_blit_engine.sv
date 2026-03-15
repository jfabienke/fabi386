/*
 * fabi386: ETX Display Engine — 2D Blit/Render Engine
 * -----------------------------------------------------
 * Address generators, ROP unit (COPY/XOR/AND/SOLID_FILL), color-key
 * comparator, pattern tile, Bresenham line drawing.
 * Resource stub for Quartus estimation.
 */

import f386_pkg::*;

module f386_etx_blit_engine (
    input  logic         clk,
    input  logic         rst_n,

    // Command interface (from cmd_decoder)
    input  logic [3:0]   opcode,
    input  logic [24:0]  src_addr,
    input  logic [24:0]  dst_addr,
    input  logic [15:0]  width,
    input  logic [15:0]  height,
    input  logic [15:0]  src_stride,
    input  logic [15:0]  dst_stride,
    input  logic [31:0]  fill_color,
    input  logic [23:0]  colorkey,
    input  logic         start,
    output logic         done,

    // Memory hub interface (channel B, port 2)
    output logic         mem_req,
    output logic [24:0]  mem_addr,
    output logic         mem_wr,
    output logic [31:0]  mem_wdata,
    input  logic [31:0]  mem_rdata,
    input  logic         mem_ack,

    // Tile tracker dirty-set
    output logic [11:0]  dirty_tile_idx,
    output logic         dirty_set
);

    // =========================================================================
    //  ROP modes
    // =========================================================================
    localparam logic [1:0] ROP_COPY       = 2'd0;
    localparam logic [1:0] ROP_XOR        = 2'd1;
    localparam logic [1:0] ROP_AND        = 2'd2;
    localparam logic [1:0] ROP_SOLID_FILL = 2'd3;

    // =========================================================================
    //  Pattern tile: 8x8 x 32-bit = 2,048 bits (distributed RAM)
    // =========================================================================
    logic [31:0] pattern_tile [64];
    logic [5:0]  pattern_idx;
    logic [31:0] pattern_data;

    assign pattern_data = pattern_tile[pattern_idx];

    // =========================================================================
    //  Blit FSM
    // =========================================================================
    typedef enum logic [3:0] {
        BLIT_IDLE,
        BLIT_SETUP,
        BLIT_READ_SRC,
        BLIT_WAIT_SRC,
        BLIT_ROP,
        BLIT_WRITE_DST,
        BLIT_WAIT_DST,
        BLIT_NEXT_PIXEL,
        BLIT_NEXT_ROW,
        BLIT_LINE_SETUP,
        BLIT_LINE_STEP,
        BLIT_DONE
    } blit_state_t;

    blit_state_t state;

    // Address generators
    logic [24:0] cur_src_addr, cur_dst_addr;
    logic [15:0] cur_x, cur_y;
    logic [31:0] src_data_r;

    // Bresenham line state
    logic signed [15:0] line_dx, line_dy;
    logic signed [15:0] line_err;
    logic [15:0] line_x0, line_y0, line_x1, line_y1;

    // ROP result
    logic [31:0] rop_result;
    logic [1:0]  rop_mode;

    assign rop_mode = opcode[1:0];

    // Byte-enable mask (simplified — full word)
    logic [3:0] byte_en;
    assign byte_en = 4'b1111;

    // Color-key match
    logic colorkey_match;
    assign colorkey_match = (src_data_r[23:0] == colorkey);

    always_comb begin
        case (rop_mode)
            ROP_COPY:       rop_result = src_data_r;
            ROP_XOR:        rop_result = src_data_r ^ fill_color;
            ROP_AND:        rop_result = src_data_r & fill_color;
            ROP_SOLID_FILL: rop_result = fill_color;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= BLIT_IDLE;
            cur_src_addr <= '0;
            cur_dst_addr <= '0;
            cur_x        <= '0;
            cur_y        <= '0;
            src_data_r   <= '0;
            done         <= 1'b0;
            mem_req      <= 1'b0;
            mem_addr     <= '0;
            mem_wr       <= 1'b0;
            mem_wdata    <= '0;
            dirty_tile_idx <= '0;
            dirty_set    <= 1'b0;
            line_dx      <= '0;
            line_dy      <= '0;
            line_err     <= '0;
            line_x0      <= '0;
            line_y0      <= '0;
            line_x1      <= '0;
            line_y1      <= '0;
            pattern_idx  <= '0;
        end else begin
            done      <= 1'b0;
            dirty_set <= 1'b0;
            mem_req   <= 1'b0;

            case (state)
                BLIT_IDLE: begin
                    if (start) begin
                        cur_src_addr <= src_addr;
                        cur_dst_addr <= dst_addr;
                        cur_x <= '0;
                        cur_y <= '0;
                        if (opcode == 4'd5)  // LINE
                            state <= BLIT_LINE_SETUP;
                        else
                            state <= BLIT_SETUP;
                    end
                end

                BLIT_SETUP: begin
                    if (opcode == 4'd1) begin  // FILL_RECT — no source read
                        state <= BLIT_WRITE_DST;
                    end else begin
                        state <= BLIT_READ_SRC;
                    end
                end

                BLIT_READ_SRC: begin
                    mem_req  <= 1'b1;
                    mem_addr <= cur_src_addr;
                    mem_wr   <= 1'b0;
                    state    <= BLIT_WAIT_SRC;
                end

                BLIT_WAIT_SRC: begin
                    if (mem_ack) begin
                        src_data_r <= mem_rdata;
                        state      <= BLIT_ROP;
                    end
                end

                BLIT_ROP: begin
                    // Color-key: skip write if match (for BLIT_COLORKEY opcode)
                    if (opcode == 4'd3 && colorkey_match)
                        state <= BLIT_NEXT_PIXEL;
                    else
                        state <= BLIT_WRITE_DST;
                end

                BLIT_WRITE_DST: begin
                    mem_req   <= 1'b1;
                    mem_addr  <= cur_dst_addr;
                    mem_wr    <= 1'b1;
                    mem_wdata <= (opcode == 4'd1) ? fill_color : rop_result;
                    state     <= BLIT_WAIT_DST;
                end

                BLIT_WAIT_DST: begin
                    if (mem_ack) begin
                        // Mark tile dirty
                        dirty_tile_idx <= cur_dst_addr[24:13];
                        dirty_set      <= 1'b1;
                        state          <= BLIT_NEXT_PIXEL;
                    end
                end

                BLIT_NEXT_PIXEL: begin
                    if (cur_x + 1'b1 >= width) begin
                        state <= BLIT_NEXT_ROW;
                    end else begin
                        cur_x        <= cur_x + 1'b1;
                        cur_src_addr <= cur_src_addr + 25'd4;
                        cur_dst_addr <= cur_dst_addr + 25'd4;
                        state <= BLIT_SETUP;
                    end
                end

                BLIT_NEXT_ROW: begin
                    if (cur_y + 1'b1 >= height) begin
                        state <= BLIT_DONE;
                    end else begin
                        cur_y        <= cur_y + 1'b1;
                        cur_x        <= '0;
                        cur_src_addr <= src_addr + {9'd0, (cur_y + 1'b1)} * {9'd0, src_stride};
                        cur_dst_addr <= dst_addr + {9'd0, (cur_y + 1'b1)} * {9'd0, dst_stride};
                        state <= BLIT_SETUP;
                    end
                end

                // Bresenham line drawing
                BLIT_LINE_SETUP: begin
                    line_x0 <= '0;
                    line_y0 <= '0;
                    line_x1 <= width;
                    line_y1 <= height;
                    line_dx <= $signed({1'b0, width});
                    line_dy <= -$signed({1'b0, height});
                    line_err <= $signed({1'b0, width}) - $signed({1'b0, height});
                    state   <= BLIT_WRITE_DST;
                end

                BLIT_LINE_STEP: begin
                    if (line_x0 == line_x1 && line_y0 == line_y1) begin
                        state <= BLIT_DONE;
                    end else begin
                        if (2 * line_err >= line_dy) begin
                            line_err <= line_err + line_dy;
                            line_x0  <= line_x0 + 1'b1;
                            cur_dst_addr <= cur_dst_addr + 25'd4;
                        end
                        if (2 * line_err <= line_dx) begin
                            line_err <= line_err + line_dx;
                            line_y0  <= line_y0 + 1'b1;
                            cur_dst_addr <= cur_dst_addr + {9'd0, dst_stride};
                        end
                        state <= BLIT_WRITE_DST;
                    end
                end

                BLIT_DONE: begin
                    done  <= 1'b1;
                    state <= BLIT_IDLE;
                end

                default: state <= BLIT_IDLE;
            endcase
        end
    end

endmodule
