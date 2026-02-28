/*
 * fabi386: Miss Status Holding Registers (MSHR) for L1 Data Cache
 * -----------------------------------------------------------------
 * 2-entry MSHR file enabling non-blocking cache operation.
 *
 * Each entry records a pending cache miss so the pipeline can continue
 * issuing requests while a line fill is in progress.  When the memory
 * subsystem returns a fill, fill_addr is compared against all valid
 * entries; the matching entry is cleared and its merge data (for write-
 * allocate) is forwarded back to the cache controller.
 *
 * Entry format: {valid, addr[31:5], is_write, wdata[31:0], byte_en[3:0]}
 *
 * Allocation: first-free (lowest index).
 * Pending outputs: oldest valid entry (lowest index).
 * Fill match: combinational compare of fill_addr[31:5] against all entries.
 */

import f386_pkg::*;

module f386_dcache_mshr (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,

    // Allocate on cache miss
    input  logic        alloc_valid,
    input  logic [31:0] alloc_addr,     // Miss address (line-aligned)
    input  logic        alloc_is_write, // Was this a write miss?
    input  logic [31:0] alloc_wdata,    // Write data (for write-allocate merge)
    input  logic [3:0]  alloc_byte_en,
    output logic        alloc_ready,    // Can accept a miss

    // Fill completion
    input  logic        fill_valid,     // Memory returned the line
    input  logic [31:0] fill_addr,      // Which line was filled
    output logic        fill_match,     // This MSHR was waiting for this line

    // Status
    output logic        has_pending,    // Any MSHRs allocated
    output logic [31:0] pending_addr,   // Address of oldest pending miss
    output logic        pending_is_write,
    output logic [31:0] pending_wdata,
    output logic [3:0]  pending_byte_en
);

    localparam int NUM_ENTRIES = 2;
    localparam int LINE_TAG_W = 27;  // addr[31:5] — line-aligned tag

    // =========================================================
    // MSHR Entry Storage
    // =========================================================
    logic [NUM_ENTRIES-1:0] entry_valid;
    logic [LINE_TAG_W-1:0] entry_addr     [NUM_ENTRIES]; // addr[31:5]
    logic [NUM_ENTRIES-1:0] entry_is_write;
    logic [31:0]           entry_wdata    [NUM_ENTRIES];
    logic [3:0]            entry_byte_en  [NUM_ENTRIES];

    // =========================================================
    // Allocation: find first free entry (lowest index)
    // =========================================================
    logic [NUM_ENTRIES-1:0] entry_free;
    logic                   any_free;
    logic                   alloc_idx;  // 1-bit index for 2 entries

    always_comb begin
        entry_free = ~entry_valid;
        any_free   = |entry_free;
        alloc_idx  = 1'b0;
        // First-free: prefer entry 0
        if (entry_free[0])
            alloc_idx = 1'b0;
        else if (entry_free[1])
            alloc_idx = 1'b1;
    end

    assign alloc_ready = any_free;

    // =========================================================
    // Fill match: compare fill_addr[31:5] against valid entries
    // =========================================================
    logic [NUM_ENTRIES-1:0] match_vec;

    always_comb begin
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            match_vec[i] = entry_valid[i] &&
                           (entry_addr[i] == fill_addr[31:5]);
        end
    end

    assign fill_match = fill_valid && (|match_vec);

    // =========================================================
    // Pending outputs: oldest valid entry (lowest index)
    // =========================================================
    always_comb begin
        has_pending     = |entry_valid;
        pending_addr    = 32'd0;
        pending_is_write = 1'b0;
        pending_wdata   = 32'd0;
        pending_byte_en = 4'd0;
        for (int i = NUM_ENTRIES - 1; i >= 0; i--) begin
            if (entry_valid[i]) begin
                pending_addr    = {entry_addr[i], 5'd0};
                pending_is_write = entry_is_write[i];
                pending_wdata   = entry_wdata[i];
                pending_byte_en = entry_byte_en[i];
            end
        end
    end

    // =========================================================
    // Entry update logic
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            entry_valid <= '0;
        end else if (flush) begin
            entry_valid <= '0;
        end else begin
            // Allocate new entry on miss
            if (alloc_valid && any_free) begin
                entry_valid[alloc_idx]    <= 1'b1;
                entry_addr[alloc_idx]     <= alloc_addr[31:5];
                entry_is_write[alloc_idx] <= alloc_is_write;
                entry_wdata[alloc_idx]    <= alloc_wdata;
                entry_byte_en[alloc_idx]  <= alloc_byte_en;
            end

            // Clear matched entry on fill completion
            if (fill_valid) begin
                for (int i = 0; i < NUM_ENTRIES; i++) begin
                    if (match_vec[i])
                        entry_valid[i] <= 1'b0;
                end
            end
        end
    end

endmodule
