/*
 * fabi386: Translation Lookaside Buffer (TLB)
 * ---------------------------------------------
 * 32-entry fully-associative unified I/D TLB for 4KB pages.
 * Pseudo-LRU (tree-PLRU) replacement policy.
 *
 * 2-cycle lookup for Fmax (Tier 1 optimization):
 *   Cycle 1: CAM tag match (all entries in parallel)
 *   Cycle 2: Hit/miss determination + physical address output
 *
 * Supports:
 *   - 4KB pages (standard 386 paging)
 *   - Supervisor/user permission checking
 *   - Read/write/execute access control
 *   - INVLPG (single entry invalidation)
 *   - Full flush on CR3 write
 *
 * PSE (4MB pages) gated by CONF_ENABLE_PSE = 0 for boot.
 *
 * Reference: ao486_MiSTer/rtl/ao486/memory/tlb.v
 */

import f386_pkg::*;

module f386_tlb (
    input  logic         clk,
    input  logic         rst_n,

    // --- Lookup Interface (2-cycle pipelined) ---
    input  logic         lookup_valid,
    input  logic [31:0]  lookup_vaddr,      // Virtual address
    input  logic         lookup_write,       // 1=write access, 0=read
    input  logic         lookup_user,        // 1=user mode (CPL=3)

    output logic         lookup_hit,         // Valid on cycle 2
    output logic [31:0]  lookup_paddr,       // Physical address on hit
    output logic         lookup_fault,       // Page fault on cycle 2
    output logic [3:0]   lookup_fault_code,  // {RSVD, U/S, W/R, P}

    // --- Fill Interface (from page walker) ---
    input  logic         fill_valid,
    input  logic [19:0]  fill_vpn,           // Virtual page number
    input  logic [19:0]  fill_ppn,           // Physical page number
    input  logic         fill_dirty,         // D bit
    input  logic         fill_accessed,      // A bit
    input  logic         fill_user,          // U/S bit (1=user accessible)
    input  logic         fill_writable,      // R/W bit (1=writable)
    input  logic         fill_global,        // G bit (not flushed on CR3 write)

    // --- Invalidation ---
    input  logic         invlpg_valid,       // INVLPG instruction
    input  logic [31:0]  invlpg_vaddr,
    input  logic         flush_all,          // CR3 write: flush everything (except global)

    // --- Control ---
    input  logic         paging_enabled      // CR0.PG
);

    localparam int N = CONF_TLB_ENTRIES;  // 32

    // =========================================================
    // TLB Entry Storage
    // =========================================================
    logic [N-1:0]  entry_valid;
    logic [19:0]   entry_vpn     [N];   // Virtual page number (vaddr[31:12])
    logic [19:0]   entry_ppn     [N];   // Physical page number
    logic [N-1:0]  entry_dirty;
    logic [N-1:0]  entry_accessed;
    logic [N-1:0]  entry_user;          // U/S: 1=user-accessible
    logic [N-1:0]  entry_writable;      // R/W: 1=writable
    logic [N-1:0]  entry_global;        // G: not flushed on CR3 write

    // =========================================================
    // PLRU Replacement (tree-based pseudo-LRU for 32 entries)
    // =========================================================
    // For N=32 entries, tree has 31 bits (N-1 internal nodes).
    logic [N-2:0] plru_tree;

    // =========================================================
    // Cycle 1: CAM Tag Match (combinational)
    // =========================================================
    logic [19:0] lookup_vpn;
    assign lookup_vpn = lookup_vaddr[31:12];

    logic [N-1:0] cam_match;

    genvar i;
    generate
        for (i = 0; i < N; i++) begin : gen_cam
            assign cam_match[i] = entry_valid[i] && (entry_vpn[i] == lookup_vpn);
        end
    endgenerate

    // One-hot to binary encoder for hit index
    logic [$clog2(N)-1:0] hit_idx;
    logic                  any_hit;

    always_comb begin
        hit_idx = '0;
        any_hit = 1'b0;
        for (int i = 0; i < N; i++) begin
            if (cam_match[i]) begin
                hit_idx = $clog2(N)'(i);
                any_hit = 1'b1;
                break;
            end
        end
    end

    // =========================================================
    // Cycle 2: Hit/Miss + Permission Check (registered)
    // =========================================================
    logic        r_valid;
    logic        r_any_hit;
    logic [$clog2(N)-1:0] r_hit_idx;
    logic [11:0] r_page_offset;
    logic        r_write;
    logic        r_user;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_valid <= 1'b0;
        end else begin
            r_valid       <= lookup_valid && paging_enabled;
            r_any_hit     <= any_hit;
            r_hit_idx     <= hit_idx;
            r_page_offset <= lookup_vaddr[11:0];
            r_write       <= lookup_write;
            r_user        <= lookup_user;
        end
    end

    // Permission check
    logic perm_ok;
    logic page_fault;

    always_comb begin
        perm_ok     = 1'b1;
        page_fault  = 1'b0;
        lookup_hit  = 1'b0;
        lookup_paddr = 32'd0;
        lookup_fault = 1'b0;
        lookup_fault_code = 4'd0;

        if (r_valid) begin
            if (!r_any_hit) begin
                // TLB miss → trigger page walk (not a fault here)
                lookup_hit   = 1'b0;
                lookup_fault = 1'b0;
            end else begin
                // Permission checking
                // User mode cannot access supervisor pages
                if (r_user && !entry_user[r_hit_idx])
                    perm_ok = 1'b0;
                // Write to non-writable page
                if (r_write && !entry_writable[r_hit_idx])
                    perm_ok = 1'b0;

                if (!perm_ok) begin
                    lookup_fault = 1'b1;
                    lookup_fault_code = {1'b0,             // RSVD=0
                                         r_user,           // U/S
                                         r_write,          // W/R
                                         1'b1};            // P=1 (page present)
                end else begin
                    lookup_hit   = 1'b1;
                    lookup_paddr = {entry_ppn[r_hit_idx], r_page_offset};
                end
            end
        end
    end

    // =========================================================
    // PLRU Replacement Selection
    // =========================================================
    // Binary tree traversal to find victim
    logic [$clog2(N)-1:0] plru_victim;

    always_comb begin
        // Walk tree from root to leaf (5 levels for 32 entries)
        int node;
        node = 0;
        for (int level = 0; level < $clog2(N); level++) begin
            if (plru_tree[node]) begin
                // Go right (0-subtree was recently used)
                node = 2 * node + 2;
            end else begin
                // Go left
                node = 2 * node + 1;
            end
        end
        // Leaf node maps to entry index
        plru_victim = $clog2(N)'(node - (N - 1));
    end

    // Update PLRU tree on access
    task automatic update_plru(input int idx);
        // Walk from leaf to root, setting bits to point away
        // Unrolled to fixed $clog2(N) iterations for Quartus 17 compatibility
        int node;
        node = idx + (N - 1);
        for (int level = 0; level < $clog2(N); level++) begin
            if (node <= 0) break;
            if (node[0]) begin // Left child
                plru_tree[(node - 1) / 2] <= 1'b1; // Point right (away)
            end else begin     // Right child
                plru_tree[(node - 2) / 2] <= 1'b0; // Point left (away)
            end
            node = (node - 1) / 2;
        end
    endtask

    // =========================================================
    // Fill + Invalidation Logic
    // =========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            entry_valid    <= '0;
            plru_tree      <= '0;
        end else begin
            // PLRU update on hit (cycle 1, pipelined)
            if (lookup_valid && paging_enabled && any_hit) begin
                update_plru(int'(hit_idx));
            end

            // Fill from page walker
            if (fill_valid) begin
                logic [$clog2(N)-1:0] slot;
                // Check if VPN already exists (update in place)
                logic found;
                found = 1'b0;
                for (int i = 0; i < N; i++) begin
                    if (entry_valid[i] && entry_vpn[i] == fill_vpn) begin
                        slot = $clog2(N)'(i);
                        found = 1'b1;
                        break;
                    end
                end
                if (!found)
                    slot = plru_victim;

                entry_valid[slot]    <= 1'b1;
                entry_vpn[slot]      <= fill_vpn;
                entry_ppn[slot]      <= fill_ppn;
                entry_dirty[slot]    <= fill_dirty;
                entry_accessed[slot] <= fill_accessed;
                entry_user[slot]     <= fill_user;
                entry_writable[slot] <= fill_writable;
                entry_global[slot]   <= fill_global;
                update_plru(int'(slot));
            end

            // INVLPG: invalidate single entry matching VPN
            if (invlpg_valid) begin
                for (int i = 0; i < N; i++) begin
                    if (entry_valid[i] && entry_vpn[i] == invlpg_vaddr[31:12])
                        entry_valid[i] <= 1'b0;
                end
            end

            // Full flush (CR3 write): invalidate all except global entries
            if (flush_all) begin
                for (int i = 0; i < N; i++) begin
                    if (!entry_global[i])
                        entry_valid[i] <= 1'b0;
                end
            end
        end
    end

endmodule
