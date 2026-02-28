/*
 * fabi386: Segment Shadow Register File (v1.0)
 * -----------------------------------------------
 * 6 segment registers (ES, CS, SS, DS, FS, GS), each with:
 *   - 16-bit selector
 *   - 64-bit descriptor cache (raw x86 format, matching ao486)
 *
 * Extracted 32-bit bases provided for AGU fast-path.
 * All read ports are combinational (zero latency).
 *
 * Reset values: Real-mode descriptors — base=0, limit=0xFFFF,
 * P=1, S=1, type=data-RW, D/B=0, G=0.
 * Cache value: 64'h0000_9200_0000_FFFF
 *
 * Descriptor cache format (ao486-compatible):
 *   [63:56] = base[31:24]
 *   [55]    = G
 *   [54]    = D/B
 *   [47]    = P
 *   [46:45] = DPL
 *   [44]    = S
 *   [43:40] = type
 *   [39:16] = base[23:0]
 *   [15:0]  = limit[15:0]
 */

import f386_pkg::*;

module f386_seg_cache (
    input  logic         clk,
    input  logic         rst_n,

    // --- Write Port ---
    input  seg_idx_t     seg_idx,
    input  logic [15:0]  seg_sel_din,
    input  logic [63:0]  seg_cache_din,
    input  logic         seg_cache_valid_din,  // Validity (0 for null selector)
    input  logic         seg_we,

    // --- Selector Read Ports ---
    output logic [15:0]  es_sel,
    output logic [15:0]  cs_sel,
    output logic [15:0]  ss_sel,
    output logic [15:0]  ds_sel,
    output logic [15:0]  fs_sel,
    output logic [15:0]  gs_sel,

    // --- Descriptor Cache Read Ports ---
    output logic [63:0]  es_cache,
    output logic [63:0]  cs_cache,
    output logic [63:0]  ss_cache,
    output logic [63:0]  ds_cache,
    output logic [63:0]  fs_cache,
    output logic [63:0]  gs_cache,

    // --- Extracted 32-bit Bases (AGU fast-path) ---
    output logic [31:0]  es_base,
    output logic [31:0]  cs_base,
    output logic [31:0]  ss_base,
    output logic [31:0]  ds_base,
    output logic [31:0]  fs_base,
    output logic [31:0]  gs_base,

    // --- Extracted 32-bit Limits (granularity-adjusted, ao486 read_segment.v:122-129) ---
    output logic [31:0]  es_limit,
    output logic [31:0]  cs_limit,
    output logic [31:0]  ss_limit,
    output logic [31:0]  ds_limit,
    output logic [31:0]  fs_limit,
    output logic [31:0]  gs_limit,

    // --- Cache Validity (ao486 read_segment.v uses per-segment valid bits) ---
    output logic         es_cache_valid,
    output logic         cs_cache_valid,
    output logic         ss_cache_valid,
    output logic         ds_cache_valid,
    output logic         fs_cache_valid,
    output logic         gs_cache_valid,

    // --- CS D/B Bit (for default_32) ---
    output logic         cs_db
);

    // =================================================================
    // Real-mode reset descriptor cache value
    // P=1, S=1, type=0010 (data R/W), base=0, limit=0xFFFF
    // =================================================================
    localparam logic [63:0] REAL_MODE_DESC = 64'h0000_9200_0000_FFFF;

    // =================================================================
    // Register Storage (parameterized from CONF_NUM_SEGMENTS)
    // =================================================================
    localparam int N_SEG = CONF_NUM_SEGMENTS;

    logic [15:0] reg_sel   [N_SEG];
    logic [63:0] reg_cache [N_SEG];
    logic        reg_valid [N_SEG];

    // =================================================================
    // Write Logic
    // =================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < N_SEG; i++) begin
                reg_sel[i]   <= 16'h0;
                reg_cache[i] <= REAL_MODE_DESC;
                reg_valid[i] <= 1'b1;  // Valid in real mode
            end
        end else if (seg_we) begin
            reg_sel[seg_idx]   <= seg_sel_din;
            reg_cache[seg_idx] <= seg_cache_din;
            reg_valid[seg_idx] <= seg_cache_valid_din;
        end
    end

    // =================================================================
    // Write-Read Bypass (Reference: 80x86 SegmentRegisterFile.sv)
    // =================================================================
    // If the AGU reads a segment register in the same cycle it is being
    // written, forward the new value instead of the stale register output.
    // This avoids a 1-cycle stale-data hazard on segment loads followed
    // immediately by memory accesses using the same segment.
    wire bypass_active = seg_we;
    wire [15:0] bypass_sel   = seg_sel_din;
    wire [63:0] bypass_cache = seg_cache_din;
    wire        bypass_valid = seg_cache_valid_din;

    function automatic logic [15:0] sel_with_bypass(
        input seg_idx_t idx, input logic [15:0] reg_val
    );
        return (bypass_active && seg_idx == idx) ? bypass_sel : reg_val;
    endfunction

    function automatic logic [63:0] cache_with_bypass(
        input seg_idx_t idx, input logic [63:0] reg_val
    );
        return (bypass_active && seg_idx == idx) ? bypass_cache : reg_val;
    endfunction

    function automatic logic valid_with_bypass(
        input seg_idx_t idx, input logic reg_val
    );
        return (bypass_active && seg_idx == idx) ? bypass_valid : reg_val;
    endfunction

    // =================================================================
    // Selector Read Ports (with write-read bypass)
    // =================================================================
    assign es_sel = sel_with_bypass(SEG_ES, reg_sel[SEG_ES]);
    assign cs_sel = sel_with_bypass(SEG_CS, reg_sel[SEG_CS]);
    assign ss_sel = sel_with_bypass(SEG_SS, reg_sel[SEG_SS]);
    assign ds_sel = sel_with_bypass(SEG_DS, reg_sel[SEG_DS]);
    assign fs_sel = sel_with_bypass(SEG_FS, reg_sel[SEG_FS]);
    assign gs_sel = sel_with_bypass(SEG_GS, reg_sel[SEG_GS]);

    // =================================================================
    // Descriptor Cache Read Ports (with write-read bypass)
    // =================================================================
    wire [63:0] es_cache_bp = cache_with_bypass(SEG_ES, reg_cache[SEG_ES]);
    wire [63:0] cs_cache_bp = cache_with_bypass(SEG_CS, reg_cache[SEG_CS]);
    wire [63:0] ss_cache_bp = cache_with_bypass(SEG_SS, reg_cache[SEG_SS]);
    wire [63:0] ds_cache_bp = cache_with_bypass(SEG_DS, reg_cache[SEG_DS]);
    wire [63:0] fs_cache_bp = cache_with_bypass(SEG_FS, reg_cache[SEG_FS]);
    wire [63:0] gs_cache_bp = cache_with_bypass(SEG_GS, reg_cache[SEG_GS]);

    assign es_cache = es_cache_bp;
    assign cs_cache = cs_cache_bp;
    assign ss_cache = ss_cache_bp;
    assign ds_cache = ds_cache_bp;
    assign fs_cache = fs_cache_bp;
    assign gs_cache = gs_cache_bp;

    // =================================================================
    // Extracted 32-bit Bases (base = {cache[63:56], cache[39:16]})
    // Uses bypassed cache values so AGU sees same-cycle segment loads.
    // =================================================================
    assign es_base = {es_cache_bp[63:56], es_cache_bp[39:16]};
    assign cs_base = {cs_cache_bp[63:56], cs_cache_bp[39:16]};
    assign ss_base = {ss_cache_bp[63:56], ss_cache_bp[39:16]};
    assign ds_base = {ds_cache_bp[63:56], ds_cache_bp[39:16]};
    assign fs_base = {fs_cache_bp[63:56], fs_cache_bp[39:16]};
    assign gs_base = {gs_cache_bp[63:56], gs_cache_bp[39:16]};

    // =================================================================
    // Extracted 32-bit Limits (ao486 read_segment.v:122-129)
    // G=1: {limit[19:0], 12'hFFF} (4KB granularity)
    // G=0: {12'd0, limit[19:0]}   (byte granularity)
    // Limit field = {cache[51:48], cache[15:0]}
    // Uses bypassed cache values.
    // =================================================================
    function automatic logic [31:0] extract_limit(input logic [63:0] c);
        logic [19:0] raw_limit;
        raw_limit = {c[51:48], c[15:0]};
        return c[DESC_BIT_G] ? {raw_limit, 12'hFFF} : {12'd0, raw_limit};
    endfunction

    assign es_limit = extract_limit(es_cache_bp);
    assign cs_limit = extract_limit(cs_cache_bp);
    assign ss_limit = extract_limit(ss_cache_bp);
    assign ds_limit = extract_limit(ds_cache_bp);
    assign fs_limit = extract_limit(fs_cache_bp);
    assign gs_limit = extract_limit(gs_cache_bp);

    // =================================================================
    // Cache Validity Outputs (with write-read bypass)
    // =================================================================
    assign es_cache_valid = valid_with_bypass(SEG_ES, reg_valid[SEG_ES]);
    assign cs_cache_valid = valid_with_bypass(SEG_CS, reg_valid[SEG_CS]);
    assign ss_cache_valid = valid_with_bypass(SEG_SS, reg_valid[SEG_SS]);
    assign ds_cache_valid = valid_with_bypass(SEG_DS, reg_valid[SEG_DS]);
    assign fs_cache_valid = valid_with_bypass(SEG_FS, reg_valid[SEG_FS]);
    assign gs_cache_valid = valid_with_bypass(SEG_GS, reg_valid[SEG_GS]);

    // =================================================================
    // CS D/B Bit (bypassed — critical for mode switch latency)
    // =================================================================
    assign cs_db = cs_cache_bp[DESC_BIT_DB];

endmodule
