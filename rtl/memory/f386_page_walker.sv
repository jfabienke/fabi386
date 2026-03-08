/*
 * fabi386: Hardware Page Table Walker
 * -------------------------------------
 * 2-level page walk FSM for i386 paging (PDE → PTE).
 * Handles:
 *   - PDE fetch (CR3 + vaddr[31:22]*4)
 *   - PTE fetch (PDE.base + vaddr[21:12]*4)
 *   - A/D bit read-modify-write
 *   - #PF generation for not-present / permission violations
 *
 * Reference: ao486_MiSTer/rtl/ao486/memory/tlb.v
 */

import f386_pkg::*;

module f386_page_walker (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         flush,        // Cancel in-flight walk, quiesce pt_mem_*

    // --- Walk Request (from TLB miss) ---
    input  logic         walk_req,
    input  logic [31:0]  walk_vaddr,        // Virtual address causing TLB miss
    input  logic         walk_write,        // Access type: write
    input  logic         walk_user,         // Access type: user mode

    // --- Walk Result (to TLB fill) ---
    output logic         walk_done,
    output logic         walk_fault,        // Page fault occurred
    output logic [31:0]  walk_fault_addr,   // CR2 value
    output logic [3:0]   walk_fault_code,   // {RSVD, U/S, W/R, P}
    output logic [19:0]  walk_ppn,          // Physical page number
    output logic         walk_dirty,
    output logic         walk_accessed,
    output logic         walk_user_out,
    output logic         walk_writable,

    // --- Memory Interface (to BIU for page table reads/writes) ---
    output logic         pt_mem_req,
    output logic [31:0]  pt_mem_addr,
    output logic [31:0]  pt_mem_wdata,
    output logic         pt_mem_wr,
    input  logic [31:0]  pt_mem_rdata,
    input  logic         pt_mem_ack,

    // --- CR3 (Page Directory Base Register) ---
    input  logic [31:0]  cr3,

    // --- Status ---
    output logic         busy
);

    // Page table entry bit definitions
    localparam int PTE_P   = 0;  // Present
    localparam int PTE_RW  = 1;  // Read/Write
    localparam int PTE_US  = 2;  // User/Supervisor
    localparam int PTE_A   = 5;  // Accessed
    localparam int PTE_D   = 6;  // Dirty

    // Walk state machine
    typedef enum logic [2:0] {
        IDLE       = 3'd0,
        PDE_FETCH  = 3'd1,  // Reading page directory entry
        PDE_WAIT   = 3'd2,  // Waiting for PDE memory response
        PTE_FETCH  = 3'd3,  // Reading page table entry
        PTE_WAIT   = 3'd4,  // Waiting for PTE memory response
        AD_UPDATE  = 3'd5,  // Writing back A/D bits
        AD_WAIT    = 3'd6,  // Waiting for A/D writeback ack
        COMPLETE   = 3'd7   // Walk complete
    } walk_state_t;

    walk_state_t state;

    // Registered walk parameters
    logic [31:0] r_vaddr;
    logic        r_write;
    logic        r_user;

    // Page directory/table entry storage
    logic [31:0] pde;              // Page directory entry
    logic [31:0] pte;              // Page table entry
    logic [31:0] pte_addr;         // Address of PTE (for A/D writeback)

    // Virtual address field extraction
    wire [9:0] vaddr_pdi = r_vaddr[31:22];  // Page directory index
    wire [9:0] vaddr_pti = r_vaddr[21:12];  // Page table index

    assign busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            walk_done   <= 1'b0;
            walk_fault  <= 1'b0;
            pt_mem_req  <= 1'b0;
            pt_mem_wr   <= 1'b0;
        end else if (flush) begin
            state       <= IDLE;
            walk_done   <= 1'b0;
            walk_fault  <= 1'b0;
            pt_mem_req  <= 1'b0;
            pt_mem_wr   <= 1'b0;
        end else begin
            walk_done  <= 1'b0;
            walk_fault <= 1'b0;
            pt_mem_req <= 1'b0;
            pt_mem_wr  <= 1'b0;

            case (state)
                IDLE: begin
                    if (walk_req) begin
                        r_vaddr  <= walk_vaddr;
                        r_write  <= walk_write;
                        r_user   <= walk_user;
                        state    <= PDE_FETCH;
                    end
                end

                // --- Phase 1: Fetch PDE ---
                PDE_FETCH: begin
                    pt_mem_req  <= 1'b1;
                    pt_mem_addr <= {cr3[31:12], 12'd0} + {20'd0, vaddr_pdi, 2'b00};
                    pt_mem_wr   <= 1'b0;
                    state       <= PDE_WAIT;
                end

                PDE_WAIT: begin
                    if (pt_mem_ack) begin
                        pde <= pt_mem_rdata;

                        // Check PDE present
                        if (!pt_mem_rdata[PTE_P]) begin
                            // #PF: PDE not present
                            walk_fault      <= 1'b1;
                            walk_fault_addr <= r_vaddr;
                            walk_fault_code <= {1'b0, r_user, r_write, 1'b0}; // P=0
                            walk_done       <= 1'b1;
                            state           <= IDLE;
                        end else begin
                            // PDE permission check
                            if (r_user && !pt_mem_rdata[PTE_US]) begin
                                // #PF: user access to supervisor page
                                walk_fault      <= 1'b1;
                                walk_fault_addr <= r_vaddr;
                                walk_fault_code <= {1'b0, r_user, r_write, 1'b1};
                                walk_done       <= 1'b1;
                                state           <= IDLE;
                            end else begin
                                state <= PTE_FETCH;
                            end
                        end
                    end
                end

                // --- Phase 2: Fetch PTE ---
                PTE_FETCH: begin
                    pte_addr    <= {pde[31:12], 12'd0} + {20'd0, vaddr_pti, 2'b00};
                    pt_mem_req  <= 1'b1;
                    pt_mem_addr <= {pde[31:12], 12'd0} + {20'd0, vaddr_pti, 2'b00};
                    pt_mem_wr   <= 1'b0;
                    state       <= PTE_WAIT;
                end

                PTE_WAIT: begin
                    if (pt_mem_ack) begin
                        pte <= pt_mem_rdata;

                        // Check PTE present
                        if (!pt_mem_rdata[PTE_P]) begin
                            walk_fault      <= 1'b1;
                            walk_fault_addr <= r_vaddr;
                            walk_fault_code <= {1'b0, r_user, r_write, 1'b0};
                            walk_done       <= 1'b1;
                            state           <= IDLE;
                        end else if (r_user && !pt_mem_rdata[PTE_US]) begin
                            // User access to supervisor page
                            walk_fault      <= 1'b1;
                            walk_fault_addr <= r_vaddr;
                            walk_fault_code <= {1'b0, r_user, r_write, 1'b1};
                            walk_done       <= 1'b1;
                            state           <= IDLE;
                        end else if (r_write && !pt_mem_rdata[PTE_RW]) begin
                            // Write to read-only page
                            walk_fault      <= 1'b1;
                            walk_fault_addr <= r_vaddr;
                            walk_fault_code <= {1'b0, r_user, 1'b1, 1'b1};
                            walk_done       <= 1'b1;
                            state           <= IDLE;
                        end else begin
                            // Success — update A/D bits if needed
                            if (!pt_mem_rdata[PTE_A] || (r_write && !pt_mem_rdata[PTE_D])) begin
                                state <= AD_UPDATE;
                            end else begin
                                // A/D bits already set, complete immediately
                                walk_ppn      <= pt_mem_rdata[31:12];
                                walk_dirty    <= pt_mem_rdata[PTE_D];
                                walk_accessed <= 1'b1;
                                walk_user_out <= pt_mem_rdata[PTE_US];
                                walk_writable <= pt_mem_rdata[PTE_RW];
                                walk_done     <= 1'b1;
                                state         <= IDLE;
                            end
                        end
                    end
                end

                // --- Phase 3: A/D Bit Update (RMW) ---
                AD_UPDATE: begin
                    pt_mem_req  <= 1'b1;
                    pt_mem_addr <= pte_addr;
                    pt_mem_wdata <= pte | (1 << PTE_A) | (r_write ? (1 << PTE_D) : 0);
                    pt_mem_wr   <= 1'b1;
                    state       <= AD_WAIT;
                end

                AD_WAIT: begin
                    if (pt_mem_ack) begin
                        walk_ppn      <= pte[31:12];
                        walk_dirty    <= pte[PTE_D] | r_write;
                        walk_accessed <= 1'b1;
                        walk_user_out <= pte[PTE_US];
                        walk_writable <= pte[PTE_RW];
                        walk_done     <= 1'b1;
                        state         <= IDLE;
                    end
                end

                COMPLETE: begin
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
