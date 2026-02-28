/*
 * fabi386: Multi-Width Free List
 * --------------------------------
 * Allocates and frees up to N entries per cycle for rename free list,
 * LSQ index allocation, etc.
 *
 * Uses a bitmap + priority picker for allocation and simple bit-set
 * for deallocation. Supports simultaneous alloc + free.
 *
 * Parameters:
 *   DEPTH       — total number of entries in the pool
 *   ALLOC_WIDTH — max entries allocated per cycle
 *   FREE_WIDTH  — max entries freed per cycle
 *   RESERVED    — entries 0..RESERVED-1 are never freed (e.g., arch regs)
 */

import f386_pkg::*;

module f386_freelist_multiwidth #(
    parameter int DEPTH       = 32,
    parameter int ALLOC_WIDTH = 2,
    parameter int FREE_WIDTH  = 2,
    parameter int RESERVED    = 8     // Entries 0..RESERVED-1 are pre-allocated
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          flush,

    // Allocation request
    input  logic [ALLOC_WIDTH-1:0]        alloc_req,    // Per-slot: request an entry
    output logic [$clog2(DEPTH)-1:0]      alloc_id  [ALLOC_WIDTH],
    output logic [ALLOC_WIDTH-1:0]        alloc_valid,  // Per-slot: allocation succeeded

    // Free (return) interface
    input  logic [FREE_WIDTH-1:0]         free_req,
    input  logic [$clog2(DEPTH)-1:0]      free_id   [FREE_WIDTH]
);

    localparam int IDX_W = $clog2(DEPTH);

    // Bitmap: 1 = free, 0 = allocated
    logic [DEPTH-1:0] free_map;

    // Initial free map: entries >= RESERVED are free
    localparam logic [DEPTH-1:0] INIT_MAP = ~((1 << RESERVED) - 1);

    // Picker finds ALLOC_WIDTH free entries from bitmap
    logic [DEPTH-1:0]  pick_grant   [ALLOC_WIDTH];
    logic [IDX_W-1:0]  pick_idx     [ALLOC_WIDTH];
    logic               pick_valid   [ALLOC_WIDTH];

    f386_picker #(
        .WIDTH    (DEPTH),
        .NUM_PICK (ALLOC_WIDTH)
    ) u_picker (
        .request   (free_map),
        .grant     (pick_grant),
        .grant_idx (pick_idx),
        .valid     (pick_valid)
    );

    // Drive allocation outputs combinationally
    always_comb begin
        for (int i = 0; i < ALLOC_WIDTH; i++) begin
            alloc_id[i]    = pick_idx[i];
            alloc_valid[i] = alloc_req[i] & pick_valid[i];
        end
    end

    // Update bitmap
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            free_map <= INIT_MAP;
        end else if (flush) begin
            free_map <= INIT_MAP;
        end else begin
            // Apply allocations (clear bits)
            for (int i = 0; i < ALLOC_WIDTH; i++) begin
                if (alloc_valid[i])
                    free_map[alloc_id[i]] <= 1'b0;
            end
            // Apply frees (set bits) — frees take priority on conflict
            for (int i = 0; i < FREE_WIDTH; i++) begin
                if (free_req[i])
                    free_map[free_id[i]] <= 1'b1;
            end
        end
    end

endmodule
