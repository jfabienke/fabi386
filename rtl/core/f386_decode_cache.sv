/*
 * fabi386: Decoded-Instruction Cache (Phase 1)
 * ----------------------------------------------
 * Stores decoded U+V pipe outputs indexed by PC + CPU mode.
 * Direct-mapped, 256 entries in M10K BRAM with flip-flop valid bits.
 * Zero additional pipeline latency — cache read aligned with decode stage 2.
 *
 * Invalidated on mode changes only (CR0/CR3/CR4 writes), NOT mispredicts.
 * Feature-gated by CONF_ENABLE_DECODE_CACHE.
 */

import f386_pkg::*;

module f386_decode_cache (
    input  logic              clk,
    input  logic              rst_n,

    // Lookup (cycle N — fires on fetch_ack, same time as decode stage 1)
    input  logic [31:0]       lookup_pc,
    input  logic              lookup_valid,   // = fetch_ack
    input  logic              pe_mode,
    input  logic              v86_mode,
    input  logic              default_32,

    // Cache result (cycle N+1 — same time as decode stage 2)
    output logic              hit,
    output dc_pipe_entry_t    hit_u,
    output dc_pipe_entry_t    hit_v,

    // Fill (cycle N+1, on miss when decode output is accepted)
    input  logic              fill_valid,
    input  logic [31:0]       fill_pc,
    input  logic [2:0]        fill_mode,     // {pe, v86, d32}
    input  dc_pipe_entry_t    fill_u,
    input  dc_pipe_entry_t    fill_v,

    // Invalidation (mode changes only — NOT mispredicts)
    input  logic              inv_all,

    // Profiling
    output logic [31:0]       perf_hits,
    output logic [31:0]       perf_misses
);

    // =====================================================================
    // Parameters & Constants
    // =====================================================================
    localparam IDX_W  = CONF_DEC_CACHE_IDX_W;        // 8
    localparam TAG_W  = 27;                            // {PC[31:12], PC[3:0], pe, v86, d32}
    localparam PIPE_W = $bits(dc_pipe_entry_t);        // 167
    localparam DATA_W = TAG_W + 2 * PIPE_W;            // 361

    // =====================================================================
    // Lookup pipeline registers (cycle N -> N+1)
    // =====================================================================
    logic [TAG_W-1:0]  lookup_tag_r;
    logic              lookup_valid_r;
    logic [IDX_W-1:0]  lookup_idx_r;

    wire [IDX_W-1:0] lookup_idx = lookup_pc[IDX_W+3:4];  // PC[11:4]

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_valid_r <= 1'b0;
            lookup_tag_r   <= '0;
            lookup_idx_r   <= '0;
        end else begin
            lookup_valid_r <= lookup_valid;
            lookup_tag_r   <= {lookup_pc[31:12], lookup_pc[3:0], pe_mode, v86_mode, default_32};
            lookup_idx_r   <= lookup_idx;
        end
    end

    // =====================================================================
    // SRAM (M10K) — 256 x 361 bits
    // =====================================================================
    wire [IDX_W-1:0] fill_idx = fill_pc[IDX_W+3:4];
    wire [TAG_W-1:0] fill_tag = {fill_pc[31:12], fill_pc[3:0], fill_mode};

    logic [DATA_W-1:0] sram_rdata;

    f386_block_ram #(
        .ADDR_WIDTH (IDX_W),
        .DATA_WIDTH (DATA_W)
    ) sram (
        .clk     (clk),
        // Port A: fill write
        .a_wr_en (fill_valid),
        .a_addr  (fill_idx),
        .a_wdata ({fill_tag, fill_u, fill_v}),
        .a_rdata (),  // unused
        // Port B: lookup read
        .b_addr  (lookup_idx),
        .b_rdata (sram_rdata)
    );

    // =====================================================================
    // Valid bit array (flip-flops, single-cycle bulk invalidation)
    // =====================================================================
    logic [CONF_DEC_CACHE_ENTRIES-1:0] valid_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            valid_reg <= '0;
        else if (inv_all)
            valid_reg <= '0;
        else if (fill_valid)
            valid_reg[fill_idx] <= 1'b1;
    end

    // =====================================================================
    // Hit detection (cycle N+1, combinational)
    // =====================================================================
    wire [TAG_W-1:0] sram_tag = sram_rdata[DATA_W-1 -: TAG_W];

    // R/W collision: fill and lookup target same index in same cycle
    wire rd_wr_collision = fill_valid && (fill_idx == lookup_idx_r);

    assign hit = lookup_valid_r && valid_reg[lookup_idx_r] &&
                 (sram_tag == lookup_tag_r) && !rd_wr_collision;

    // =====================================================================
    // Unpack SRAM data -> pipe entries
    // =====================================================================
    assign hit_u = sram_rdata[2*PIPE_W-1 -: PIPE_W];  // [333:167]
    assign hit_v = sram_rdata[PIPE_W-1:0];              // [166:0]

    // =====================================================================
    // Performance counters (32-bit saturating)
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_hits   <= 32'd0;
            perf_misses <= 32'd0;
        end else if (lookup_valid_r) begin
            if (hit) begin
                if (perf_hits != 32'hFFFF_FFFF)
                    perf_hits <= perf_hits + 32'd1;
            end else begin
                if (perf_misses != 32'hFFFF_FFFF)
                    perf_misses <= perf_misses + 32'd1;
            end
        end
    end

endmodule
