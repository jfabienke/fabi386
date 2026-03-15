/*
 * fabi386: ETX Display Engine — L1 Glyph Cache
 * ----------------------------------------------
 * Direct-mapped glyph cache: 1024 entries, 8x16 1bpp (16 bytes/glyph).
 * Tag RAM: 1024 x 16-bit (2 M10K), Data RAM: 1024 x 128-bit (13 M10K).
 * Resource stub for Quartus estimation.
 */

import f386_pkg::*;

module f386_etx_glyph_cache (
    input  logic         clk,
    input  logic         rst_n,

    // Lookup port (from scanout pipe)
    input  logic [15:0]  lookup_glyph_id,
    input  logic         lookup_valid,
    output logic         lookup_hit,
    output logic [127:0] lookup_data,
    output logic         lookup_ready,

    // Fill port (from mem hub on miss)
    input  logic [15:0]  fill_glyph_id,
    input  logic [127:0] fill_data,
    input  logic         fill_valid,

    // Flush (font bank switch)
    input  logic         flush
);

    localparam int ENTRIES  = 1024;
    localparam int IDX_W    = 10;   // $clog2(1024)
    localparam int TAG_W    = 16;
    localparam int DATA_W   = 128;  // 16 bytes per glyph

    // =========================================================================
    //  Valid array (flip-flops)
    // =========================================================================
    logic [ENTRIES-1:0] valid_r;

    // =========================================================================
    //  Tag RAM — 1024 x 16-bit → 2 M10K
    // =========================================================================
    logic [IDX_W-1:0]  tag_rd_addr, tag_wr_addr;
    logic [TAG_W-1:0]  tag_rd_data, tag_wr_data;
    logic              tag_wr_en;

    f386_bram_sdp #(.ADDR_W(IDX_W), .DATA_W(TAG_W)) tag_ram (
        .clk     (clk),
        .wr_addr (tag_wr_addr),
        .wr_data (tag_wr_data),
        .wr_en   (tag_wr_en),
        .rd_addr (tag_rd_addr),
        .rd_data (tag_rd_data)
    );

    // =========================================================================
    //  Data RAM — 1024 x 128-bit → 13 M10K
    // =========================================================================
    logic [IDX_W-1:0]  data_rd_addr, data_wr_addr;
    logic [DATA_W-1:0] data_rd_data, data_wr_data;
    logic              data_wr_en;

    f386_bram_sdp #(.ADDR_W(IDX_W), .DATA_W(DATA_W)) data_ram (
        .clk     (clk),
        .wr_addr (data_wr_addr),
        .wr_data (data_wr_data),
        .wr_en   (data_wr_en),
        .rd_addr (data_rd_addr),
        .rd_data (data_rd_data)
    );

    // =========================================================================
    //  Lookup pipeline (1-cycle BRAM latency)
    // =========================================================================
    logic [IDX_W-1:0] lookup_idx;
    logic [TAG_W-1:0] lookup_tag;
    logic             lookup_valid_r;
    logic [TAG_W-1:0] lookup_tag_r;
    logic [IDX_W-1:0] lookup_idx_r;

    assign lookup_idx = lookup_glyph_id[IDX_W-1:0];
    assign lookup_tag = lookup_glyph_id[TAG_W-1:0];
    assign tag_rd_addr  = lookup_idx;
    assign data_rd_addr = lookup_idx;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_valid_r <= 1'b0;
            lookup_tag_r   <= '0;
            lookup_idx_r   <= '0;
        end else begin
            lookup_valid_r <= lookup_valid;
            lookup_tag_r   <= lookup_tag;
            lookup_idx_r   <= lookup_idx;
        end
    end

    // Hit compare (cycle after lookup issue)
    assign lookup_hit   = lookup_valid_r && valid_r[lookup_idx_r] &&
                          (tag_rd_data == lookup_tag_r);
    assign lookup_data  = data_rd_data;
    assign lookup_ready = lookup_valid_r;

    // =========================================================================
    //  Fill path
    // =========================================================================
    logic [IDX_W-1:0] fill_idx;
    assign fill_idx = fill_glyph_id[IDX_W-1:0];

    assign tag_wr_addr  = fill_idx;
    assign tag_wr_data  = fill_glyph_id[TAG_W-1:0];
    assign tag_wr_en    = fill_valid;
    assign data_wr_addr = fill_idx;
    assign data_wr_data = fill_data;
    assign data_wr_en   = fill_valid;

    // =========================================================================
    //  Valid array management
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_r <= '0;
        end else if (flush) begin
            valid_r <= '0;
        end else if (fill_valid) begin
            valid_r[fill_idx] <= 1'b1;
        end
    end

endmodule
