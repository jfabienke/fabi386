/*
 * fabi386: ETX Display Engine — 4-Cursor Alpha Blend Overlay
 * -----------------------------------------------------------
 * Compares pixel position against 4 cursor descriptors, applies blink
 * and alpha blending. Resource stub for Quartus estimation.
 */

import f386_pkg::*;

module f386_etx_cursor_overlay (
    input  logic         clk,
    input  logic         rst_n,

    // Pixel position
    input  logic [10:0]  pixel_x,
    input  logic [9:0]   pixel_y,

    // Cursor descriptors (from register block)
    input  logic [15:0]  cursor_pos_x   [4],
    input  logic [15:0]  cursor_pos_y   [4],
    input  logic [7:0]   cursor_hotspot [4],
    input  logic [1:0]   cursor_shape   [4],
    input  logic [7:0]   cursor_blink   [4],
    input  logic [7:0]   cursor_alpha   [4],
    input  logic [15:0]  cursor_size    [4],

    // Blink clock
    input  logic [7:0]   frame_counter,

    // Output
    output logic [23:0]  cursor_color,
    output logic         cursor_active,
    output logic [7:0]   cursor_alpha_out
);

    // =========================================================================
    //  Per-cursor hit detection + blink gating
    // =========================================================================
    logic [3:0] hit;
    logic [3:0] blink_visible;

    genvar i;
    generate
        for (i = 0; i < 4; i++) begin : gen_cursor
            logic x_match, y_match;
            logic [15:0] cx_start, cy_start;
            logic [7:0]  cw, ch;

            assign cx_start = cursor_pos_x[i] - {8'd0, cursor_hotspot[i]};
            assign cy_start = cursor_pos_y[i];
            assign cw = cursor_size[i][15:8];
            assign ch = cursor_size[i][7:0];

            assign x_match = ({5'd0, pixel_x} >= cx_start) &&
                             ({5'd0, pixel_x} < cx_start + {8'd0, cw});
            assign y_match = ({6'd0, pixel_y} >= cy_start) &&
                             ({6'd0, pixel_y} < cy_start + {8'd0, ch});

            assign hit[i] = x_match && y_match;

            // Blink: visible when frame_counter[7:0] < blink period, or blink=0 (always on)
            assign blink_visible[i] = (cursor_blink[i] == 8'd0) ||
                                       (frame_counter < cursor_blink[i]);
        end
    endgenerate

    // =========================================================================
    //  Priority mux (cursor 0 highest)
    // =========================================================================
    logic [1:0] winner;
    logic       any_active;

    always_comb begin
        winner     = 2'd0;
        any_active = 1'b0;
        for (int j = 3; j >= 0; j--) begin
            if (hit[j] && blink_visible[j]) begin
                winner     = j[1:0];
                any_active = 1'b1;
            end
        end
    end

    // =========================================================================
    //  Color output (shape-based stub)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cursor_color     <= '0;
            cursor_active    <= 1'b0;
            cursor_alpha_out <= '0;
        end else begin
            cursor_active    <= any_active;
            cursor_alpha_out <= any_active ? cursor_alpha[winner] : 8'd0;
            case (cursor_shape[winner])
                2'b00: cursor_color <= 24'hFFFFFF;  // block
                2'b01: cursor_color <= 24'hFFFFFF;  // underline
                2'b10: cursor_color <= 24'hFFFFFF;  // bar
                2'b11: cursor_color <= 24'hFF0000;  // custom
            endcase
        end
    end

endmodule
