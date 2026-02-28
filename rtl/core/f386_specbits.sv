/*
 * fabi386: Speculation Bits Manager (SpecBits)
 * ---------------------------------------------
 * Tracks which in-flight branches each instruction depends on.
 * Each instruction carries a CONF_MAX_BR_COUNT-bit mask (specbits_t)
 * indicating all branches it was dispatched under.
 *
 * Operations:
 *   alloc_tag    — Allocate a new branch tag (at branch dispatch)
 *   resolve_tag  — Branch resolved correctly → clear that bit everywhere
 *   squash_tag   — Branch mispredicted → all instructions with that bit
 *                  set must be killed
 *   free_tag     — Return tag to pool after resolution/squash completes
 *
 * The current speculation mask (cur_specbits) is carried by every
 * instruction dispatched.  When a branch resolves correctly, its bit
 * is cleared from the mask.  When a branch mispredicts, all downstream
 * instructions (those with the tag bit set) are squashed.
 *
 * Reference: Toooba HasSpecBits.bsv, BOOM specbits
 * Feature-gated by CONF_ENABLE_SPECBITS.
 */

import f386_pkg::*;

module f386_specbits (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,           // Full pipeline flush (reset all)

    // --- Branch tag allocation (at branch dispatch) ---
    input  logic        alloc_req,       // Dispatcher wants a new branch tag
    output br_tag_t     alloc_tag,       // Allocated tag index (0 to MAX_BR-1)
    output logic        alloc_valid,     // Tag was successfully allocated

    // --- Current speculation mask (carried by dispatched instructions) ---
    output specbits_t   cur_specbits,    // Active speculation bitmask

    // --- Branch resolution (correct prediction) ---
    input  logic        resolve_valid,   // Branch resolved correctly
    input  br_tag_t     resolve_tag,     // Which branch tag resolved

    // --- Branch squash (misprediction) ---
    input  logic        squash_valid,    // Branch mispredicted
    input  br_tag_t     squash_tag,      // Which branch tag mispredicted
    output specbits_t   squash_mask,     // Mask of instructions to kill
                                         // (all instructions with this bit set)

    // --- Tag pool status ---
    output logic        tags_available   // At least 1 free tag
);

    localparam int N = CONF_MAX_BR_COUNT;  // 4

    // =========================================================
    // Tag allocation pool (1 = free, 0 = in-use)
    // =========================================================
    logic [N-1:0] tag_free;

    // Active speculation mask: bit i is set if branch tag i is
    // in-flight (allocated but not yet resolved/squashed)
    specbits_t active_mask;

    // =========================================================
    // Priority encoder: find lowest free tag
    // =========================================================
    logic [BR_TAG_WIDTH-1:0] free_tag;
    logic                    free_found;

    always_comb begin
        free_tag   = '0;
        free_found = 1'b0;
        for (int i = 0; i < N; i++) begin
            if (tag_free[i] && !free_found) begin
                free_tag   = BR_TAG_WIDTH'(i);
                free_found = 1'b1;
            end
        end
    end

    assign alloc_tag     = free_tag;
    assign alloc_valid   = alloc_req && free_found;
    assign tags_available = free_found;

    // =========================================================
    // Current spec mask output
    // =========================================================
    // Instructions dispatched in this cycle inherit the active_mask
    // with the just-allocated tag bit already set (if allocating).
    always_comb begin
        cur_specbits = active_mask;
        if (alloc_valid)
            cur_specbits[alloc_tag] = 1'b1;
    end

    // =========================================================
    // Squash mask output
    // =========================================================
    // The squash mask is simply the bit for the mispredicted branch.
    // Any instruction whose spec_bits AND squash_mask != 0 must die.
    // The consumer (ROB, IQ) performs: kill = |(entry.specbits & squash_mask)
    always_comb begin
        squash_mask = '0;
        if (squash_valid)
            squash_mask[squash_tag] = 1'b1;
    end

    // =========================================================
    // State update
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tag_free    <= {N{1'b1}};     // All tags free
            active_mask <= '0;
        end else if (flush) begin
            tag_free    <= {N{1'b1}};
            active_mask <= '0;
        end else begin
            // Allocate: mark tag as in-use
            if (alloc_valid) begin
                tag_free[alloc_tag]    <= 1'b0;
                active_mask[alloc_tag] <= 1'b1;
            end

            // Resolve: branch was correct → free the tag, clear from mask
            if (resolve_valid) begin
                tag_free[resolve_tag]    <= 1'b1;
                active_mask[resolve_tag] <= 1'b0;
            end

            // Squash: branch mispredicted → free the tag, clear from mask
            // (ROB/IQ will independently kill tagged instructions)
            if (squash_valid) begin
                tag_free[squash_tag]    <= 1'b1;
                active_mask[squash_tag] <= 1'b0;
            end
        end
    end

endmodule
