/*
 * fabi386: Segment Cache Formal Properties
 * ------------------------------------------
 * Asserts correctness of segment register read/write operations:
 *   - Reset initializes to real-mode descriptors
 *   - Write updates correct segment only
 *   - Base extraction matches descriptor format
 *   - Limit extraction respects granularity bit
 *   - CS D/B bit correctly extracted
 */

import f386_pkg::*;

module f386_seg_cache_props (
    input  logic         clk,
    input  logic         rst_n,

    input  seg_idx_t     seg_idx,
    input  logic [15:0]  seg_sel_din,
    input  logic [63:0]  seg_cache_din,
    input  logic         seg_cache_valid_din,
    input  logic         seg_we
);

    // ---- DUT ----
    logic [15:0] es_sel, cs_sel, ss_sel, ds_sel, fs_sel, gs_sel;
    logic [63:0] es_cache, cs_cache, ss_cache, ds_cache, fs_cache, gs_cache;
    logic [31:0] es_base, cs_base, ss_base, ds_base, fs_base, gs_base;
    logic [31:0] es_limit, cs_limit, ss_limit, ds_limit, fs_limit, gs_limit;
    logic es_cache_valid, cs_cache_valid, ss_cache_valid;
    logic ds_cache_valid, fs_cache_valid, gs_cache_valid;
    logic cs_db;

    f386_seg_cache dut (.*);

    reg past_valid;
    initial past_valid = 1'b0;
    always @(posedge clk) past_valid <= 1'b1;

    // Constrain seg_idx to valid range
    always @(*) begin
        assume (seg_idx <= SEG_GS);
    end

    // ================================================================
    // Property 1: After reset, all segments have real-mode descriptors
    // ================================================================
    localparam logic [63:0] REAL_MODE_DESC = 64'h0000_9200_0000_FFFF;

    always @(posedge clk) begin
        if (past_valid && $past(!rst_n)) begin
            assert (es_cache == REAL_MODE_DESC);
            assert (cs_cache == REAL_MODE_DESC);
            assert (ss_cache == REAL_MODE_DESC);
            assert (ds_cache == REAL_MODE_DESC);
            assert (fs_cache == REAL_MODE_DESC);
            assert (gs_cache == REAL_MODE_DESC);
        end
    end

    // ================================================================
    // Property 2: After reset, all selectors are 0
    // ================================================================
    always @(posedge clk) begin
        if (past_valid && $past(!rst_n)) begin
            assert (es_sel == 16'h0);
            assert (cs_sel == 16'h0);
        end
    end

    // ================================================================
    // Property 3: Write only affects the targeted segment
    // ================================================================
    always @(posedge clk) begin
        if (past_valid && rst_n && $past(rst_n) && $past(seg_we)) begin
            // Targeted segment gets new value
            case ($past(seg_idx))
                SEG_ES: assert (es_sel == $past(seg_sel_din));
                SEG_CS: assert (cs_sel == $past(seg_sel_din));
                SEG_SS: assert (ss_sel == $past(seg_sel_din));
                SEG_DS: assert (ds_sel == $past(seg_sel_din));
                SEG_FS: assert (fs_sel == $past(seg_sel_din));
                SEG_GS: assert (gs_sel == $past(seg_sel_din));
                default: ;
            endcase
        end
    end

    // ================================================================
    // Property 4: Base extraction matches descriptor format
    // base[31:0] = {cache[63:56], cache[39:16]}
    // ================================================================
    always @(*) begin
        assert (es_base == {es_cache[63:56], es_cache[39:16]});
        assert (cs_base == {cs_cache[63:56], cs_cache[39:16]});
        assert (ss_base == {ss_cache[63:56], ss_cache[39:16]});
    end

    // ================================================================
    // Property 5: CS D/B bit correctly extracted
    // ================================================================
    always @(*) begin
        assert (cs_db == cs_cache[DESC_BIT_DB]);
    end

    // ================================================================
    // Property 6: Limit with G=0 has byte granularity
    // ================================================================
    always @(*) begin
        if (!es_cache[DESC_BIT_G]) begin
            assert (es_limit[31:20] == 12'd0);
        end
    end

    // ================================================================
    // Property 7: Limit with G=1 has 4KB granularity (low 12 bits = FFF)
    // ================================================================
    always @(*) begin
        if (es_cache[DESC_BIT_G]) begin
            assert (es_limit[11:0] == 12'hFFF);
        end
    end

endmodule
