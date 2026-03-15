/*
 * fabi386: ETX Display Engine — Dirty Tile Bitmap
 * -------------------------------------------------
 * 60×67 = 4,020 tile bitmap (1920/32 × 1080/16).
 * Set on surface write, clear on tile scanout.
 * Resource stub for Quartus estimation.
 */

import f386_pkg::*;

module f386_etx_tile_tracker (
    input  logic         clk,
    input  logic         rst_n,

    // Set dirty (from CPU write path)
    input  logic [11:0]  set_tile_idx,
    input  logic         set_dirty,

    // Clear on scanout
    input  logic [11:0]  clear_tile_idx,
    input  logic         clear_dirty,

    // Query
    input  logic [11:0]  query_tile_idx,
    output logic         query_is_dirty,

    // Bulk clear (vsync)
    input  logic         clear_all
);

    localparam int NUM_TILES = 4096;  // round up 4020 to power-of-2 for BRAM

    // =========================================================================
    //  Dirty bitmap — 4096 x 1-bit → 1 M10K
    // =========================================================================
    logic [11:0] bm_wr_addr;
    logic        bm_wr_data;
    logic        bm_wr_en;
    logic [11:0] bm_rd_addr;
    logic        bm_rd_data;

    f386_bram_sdp #(.ADDR_W(12), .DATA_W(1)) dirty_bitmap (
        .clk     (clk),
        .wr_addr (bm_wr_addr),
        .wr_data (bm_wr_data),
        .wr_en   (bm_wr_en),
        .rd_addr (bm_rd_addr),
        .rd_data (bm_rd_data)
    );

    // =========================================================================
    //  Clear-all sweep FSM
    // =========================================================================
    logic        clearing;
    logic [11:0] clear_ctr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clearing  <= 1'b0;
            clear_ctr <= '0;
        end else if (clear_all) begin
            clearing  <= 1'b1;
            clear_ctr <= '0;
        end else if (clearing) begin
            if (clear_ctr == 12'hFFF)
                clearing <= 1'b0;
            else
                clear_ctr <= clear_ctr + 1'b1;
        end
    end

    // =========================================================================
    //  Write port mux: clear_all > set_dirty > clear_dirty
    // =========================================================================
    always_comb begin
        if (clearing) begin
            bm_wr_addr = clear_ctr;
            bm_wr_data = 1'b0;
            bm_wr_en   = 1'b1;
        end else if (set_dirty) begin
            bm_wr_addr = set_tile_idx;
            bm_wr_data = 1'b1;
            bm_wr_en   = 1'b1;
        end else if (clear_dirty) begin
            bm_wr_addr = clear_tile_idx;
            bm_wr_data = 1'b0;
            bm_wr_en   = 1'b1;
        end else begin
            bm_wr_addr = '0;
            bm_wr_data = 1'b0;
            bm_wr_en   = 1'b0;
        end
    end

    // Read port
    assign bm_rd_addr    = query_tile_idx;
    assign query_is_dirty = bm_rd_data;

endmodule
