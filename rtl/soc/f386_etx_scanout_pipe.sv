/*
 * fabi386: ETX Display Engine — 12-Stage Scanout Pipeline
 * --------------------------------------------------------
 * Per-pixel rendering pipeline: cell fetch → glyph cache → effects → cursor → output.
 * Resource stub: real pipeline register stages for Quartus ALM estimation.
 */

import f386_pkg::*;

module f386_etx_scanout_pipe (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         pixel_valid,

    // Timing inputs
    input  logic [10:0]  pixel_x,
    input  logic [9:0]   pixel_y,

    // Config
    input  logic [7:0]   cell_w,
    input  logic [7:0]   cell_h,
    input  logic [7:0]   layout_cols,
    input  logic [7:0]   layout_rows,
    input  logic [31:0]  surf_base_addr,
    input  logic [15:0]  surf_stride,
    input  logic [3:0]   surf_format,
    input  logic [15:0]  effects_basic,
    input  logic [15:0]  effects_advanced,

    // Glyph cache interface
    output logic [15:0]  cache_lookup_id,
    output logic         cache_lookup_valid,
    input  logic         cache_lookup_hit,
    input  logic [127:0] cache_lookup_data,
    input  logic         cache_lookup_ready,

    // Cursor interface
    output logic [10:0]  cursor_pixel_x,
    output logic [9:0]   cursor_pixel_y,
    input  logic [23:0]  cursor_color,
    input  logic         cursor_active,
    input  logic [7:0]   cursor_alpha,

    // Pixel output
    output logic [7:0]   out_r,
    output logic [7:0]   out_g,
    output logic [7:0]   out_b,
    output logic         out_valid
);

    // =========================================================================
    //  Pipeline data structure (~89 bits per stage)
    // =========================================================================
    typedef struct packed {
        logic [10:0] pixel_x;
        logic [9:0]  pixel_y;
        logic [7:0]  glyph_pixel;
        logic [23:0] fg_color;
        logic [23:0] bg_color;
        logic [7:0]  effect_flags;
        logic [3:0]  cursor_hit;
        logic        valid;
    } pipe_data_t;

    pipe_data_t pipe [12];

    // =========================================================================
    //  Stage 1: Cell address calculation
    // =========================================================================
    logic [7:0] col_idx, row_idx;
    logic [31:0] cell_addr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe[0] <= '0;
        end else begin
            col_idx  <= pixel_x[10:3];  // pixel_x / 8
            row_idx  <= pixel_y[9:4];   // pixel_y / 16
            cell_addr <= surf_base_addr + {16'd0, pixel_y[9:4]} * {16'd0, surf_stride}
                       + {24'd0, pixel_x[10:3]};
            pipe[0].pixel_x <= pixel_x;
            pipe[0].pixel_y <= pixel_y;
            pipe[0].valid   <= pixel_valid;
            pipe[0].glyph_pixel  <= '0;
            pipe[0].fg_color     <= 24'hC0C0C0;
            pipe[0].bg_color     <= 24'h000000;
            pipe[0].effect_flags <= '0;
            pipe[0].cursor_hit   <= '0;
        end
    end

    // =========================================================================
    //  Stage 2: Cell fetch latch
    // =========================================================================
    logic [31:0] cell_addr_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe[1] <= '0;
            cell_addr_r <= '0;
        end else begin
            pipe[1] <= pipe[0];
            cell_addr_r <= cell_addr;
        end
    end

    // =========================================================================
    //  Stage 3: Cell decode (VGA8 / EXT16 format demux)
    // =========================================================================
    logic [15:0] cell_data;
    logic [7:0]  glyph_id_raw;
    logic [7:0]  attr_byte;

    assign cell_data = {8'h07, cell_addr_r[7:0]};  // stub: attr=07, char=addr LSB
    assign glyph_id_raw = cell_data[7:0];
    assign attr_byte    = cell_data[15:8];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe[2] <= '0;
        end else begin
            pipe[2] <= pipe[1];
            pipe[2].fg_color <= {attr_byte[3:0], 4'd0, attr_byte[3:0], 4'd0, attr_byte[3:0], 4'd0};
            pipe[2].bg_color <= {attr_byte[7:4], 4'd0, attr_byte[7:4], 4'd0, attr_byte[7:4], 4'd0};
        end
    end

    // =========================================================================
    //  Stage 4: Glyph ID extract + cache lookup issue
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe[3] <= '0;
            cache_lookup_id    <= '0;
            cache_lookup_valid <= 1'b0;
        end else begin
            pipe[3] <= pipe[2];
            cache_lookup_id    <= {8'd0, glyph_id_raw};
            cache_lookup_valid <= pipe[2].valid;
        end
    end

    // =========================================================================
    //  Stage 5: Cache tag compare + hit/miss
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe[4] <= '0;
        end else begin
            pipe[4] <= pipe[3];
        end
    end

    // =========================================================================
    //  Stage 6: Glyph data latch (128-bit cache line)
    // =========================================================================
    logic [127:0] glyph_line;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe[5] <= '0;
            glyph_line <= '0;
        end else begin
            pipe[5] <= pipe[4];
            glyph_line <= cache_lookup_hit ? cache_lookup_data : '0;
        end
    end

    // =========================================================================
    //  Stage 7: Pixel select (row-within-glyph bit select)
    // =========================================================================
    logic [3:0] glyph_row;
    logic [2:0] glyph_col;
    logic       pixel_bit;

    assign glyph_row = pipe[5].pixel_y[3:0];  // row within 16-row glyph
    assign glyph_col = pipe[5].pixel_x[2:0];  // col within 8-pixel row
    assign pixel_bit = glyph_line[{glyph_row, glyph_col[2:0]}];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe[6] <= '0;
        end else begin
            pipe[6] <= pipe[5];
            pipe[6].glyph_pixel <= {7'd0, pixel_bit};
        end
    end

    // =========================================================================
    //  Stage 8: Effects 1 — bold/italic (bit-shift/OR)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe[7] <= '0;
        end else begin
            pipe[7] <= pipe[6];
            if (effects_basic[0])  // bold
                pipe[7].glyph_pixel <= pipe[6].glyph_pixel | {1'b0, pipe[6].glyph_pixel[7:1]};
        end
    end

    // =========================================================================
    //  Stage 9: Effects 2 — underline/overline/strikethrough (row compare)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe[8] <= '0;
        end else begin
            pipe[8] <= pipe[7];
            if (effects_basic[1] && pipe[7].pixel_y[3:0] == 4'd15)  // underline
                pipe[8].glyph_pixel <= 8'hFF;
            if (effects_basic[2] && pipe[7].pixel_y[3:0] == 4'd0)   // overline
                pipe[8].glyph_pixel <= 8'hFF;
            if (effects_basic[3] && pipe[7].pixel_y[3:0] == 4'd7)   // strikethrough
                pipe[8].glyph_pixel <= 8'hFF;
        end
    end

    // =========================================================================
    //  Stage 10: Effects 3 — shadow/outline (neighbor pixel)
    // =========================================================================
    logic [7:0] shadow_pixel;
    assign shadow_pixel = pipe[8].glyph_pixel;  // simplified stub

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe[9] <= '0;
        end else begin
            pipe[9] <= pipe[8];
            if (effects_advanced[0])  // shadow
                pipe[9].glyph_pixel <= pipe[8].glyph_pixel | shadow_pixel;
        end
    end

    // =========================================================================
    //  Stage 11: Cursor overlay
    // =========================================================================
    assign cursor_pixel_x = pipe[9].pixel_x;
    assign cursor_pixel_y = pipe[9].pixel_y;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe[10] <= '0;
        end else begin
            pipe[10] <= pipe[9];
            if (cursor_active)
                pipe[10].cursor_hit <= 4'b0001;
        end
    end

    // =========================================================================
    //  Stage 12: Final — palette lookup + RGB pack
    // =========================================================================
    logic [23:0] final_color;
    always_comb begin
        if (pipe[10].cursor_hit != '0) begin
            // Alpha blend: simplified (full replace at alpha=FF)
            final_color = cursor_color;
        end else if (pipe[10].glyph_pixel[0]) begin
            final_color = pipe[10].fg_color;
        end else begin
            final_color = pipe[10].bg_color;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe[11] <= '0;
            out_r <= '0; out_g <= '0; out_b <= '0; out_valid <= 1'b0;
        end else begin
            pipe[11] <= pipe[10];
            out_r     <= final_color[23:16];
            out_g     <= final_color[15:8];
            out_b     <= final_color[7:0];
            out_valid <= pipe[10].valid;
        end
    end

endmodule
