/*
 * fabi386: Data-Side TLB Translation Frontend (P3.TLB.a)
 * --------------------------------------------------------
 * Wrapper that orchestrates TLB lookup, page walker miss handling,
 * and flush coordination for data-side paging translation.
 *
 * Latency:
 *   Paging OFF: 1 cycle passthrough
 *   TLB hit:    2 cycles (TLB 2-cycle pipeline)
 *   TLB miss:   ~10-20 cycles (PDE + PTE fetch + optional A/D RMW + fill)
 *
 * Instantiates:
 *   f386_tlb          — 32-entry fully-associative, 2-cycle lookup
 *   f386_page_walker  — 8-state FSM, PDE→PTE walk + A/D RMW
 *   f386_tlb_flush    — Combinational INVLPG/CR3 passthrough
 */

import f386_pkg::*;

module f386_dtlb_frontend (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,

    // Upstream request (from AGU / core pipeline)
    input  logic        req_valid,
    input  logic [31:0] req_addr_linear,
    input  logic        req_write,
    input  logic        req_user,
    output logic        resp_valid,
    output logic [31:0] resp_paddr,
    output logic        resp_fault,
    output logic [31:0] resp_fault_addr,   // → CR2
    output logic [3:0]  resp_fault_code,   // {RSVD, U/S, W/R, P}
    output logic        busy,

    // Control
    input  logic        paging_enabled,    // CR0.PG
    input  logic        flush_all,         // CR3 write
    input  logic        invlpg_valid,      // INVLPG retired (future)
    input  logic [31:0] invlpg_vaddr,
    input  logic [31:0] cr3,

    // Page walker memory port (→ f386_emu → L2)
    output logic [31:0] pt_addr,
    output logic [31:0] pt_wdata,
    input  logic [31:0] pt_rdata,
    output logic        pt_req,
    output logic        pt_wr,
    input  logic        pt_ack
);

    // =================================================================
    // FSM States
    // =================================================================
    typedef enum logic [2:0] {
        XL_IDLE        = 3'd0,
        XL_LOOKUP      = 3'd1,   // TLB lookup initiated (cycle 1 of 2)
        XL_WAIT_LOOKUP = 3'd2,   // TLB pipeline cycle 2 — result available
        XL_WALK        = 3'd3,   // Page walk in progress
        XL_FILL        = 3'd4,   // Fill TLB with walk result
        XL_RESP        = 3'd5    // Drive response
    } xlat_state_t;

    xlat_state_t state;

    // Latched request
    logic [31:0] r_linear_addr;
    logic        r_write;
    logic        r_user;

    // =================================================================
    // TLB Flush Controller
    // =================================================================
    logic        fc_invlpg_valid;
    logic [31:0] fc_invlpg_vaddr;
    logic        fc_flush_all;

    f386_tlb_flush u_flush_ctrl (
        .clk              (clk),
        .rst_n            (rst_n),
        .retire_invlpg    (invlpg_valid),
        .retire_invlpg_addr(invlpg_vaddr),
        .cr3_write        (flush_all),
        .invlpg_valid     (fc_invlpg_valid),
        .invlpg_vaddr     (fc_invlpg_vaddr),
        .flush_all        (fc_flush_all)
    );

    // =================================================================
    // TLB Instance
    // =================================================================
    logic        tlb_lookup_valid;
    logic [31:0] tlb_lookup_vaddr;
    logic        tlb_lookup_write;
    logic        tlb_lookup_user;
    logic        tlb_hit;
    logic [31:0] tlb_paddr;
    logic        tlb_fault;
    logic [3:0]  tlb_fault_code;

    // Fill interface
    logic        tlb_fill_valid;
    logic [19:0] tlb_fill_vpn;
    logic [19:0] tlb_fill_ppn;
    logic        tlb_fill_dirty;
    logic        tlb_fill_accessed;
    logic        tlb_fill_user;
    logic        tlb_fill_writable;

    f386_tlb u_tlb (
        .clk              (clk),
        .rst_n            (rst_n),
        .lookup_valid     (tlb_lookup_valid),
        .lookup_vaddr     (tlb_lookup_vaddr),
        .lookup_write     (tlb_lookup_write),
        .lookup_user      (tlb_lookup_user),
        .lookup_hit       (tlb_hit),
        .lookup_paddr     (tlb_paddr),
        .lookup_fault     (tlb_fault),
        .lookup_fault_code(tlb_fault_code),
        .fill_valid       (tlb_fill_valid),
        .fill_vpn         (tlb_fill_vpn),
        .fill_ppn         (tlb_fill_ppn),
        .fill_dirty       (tlb_fill_dirty),
        .fill_accessed    (tlb_fill_accessed),
        .fill_user        (tlb_fill_user),
        .fill_writable    (tlb_fill_writable),
        .fill_global      (1'b0),           // No global page support yet
        .invlpg_valid     (fc_invlpg_valid),
        .invlpg_vaddr     ({fc_invlpg_vaddr[31:12], 12'd0}),
        .flush_all        (fc_flush_all),
        .paging_enabled   (paging_enabled)
    );

    // =================================================================
    // Page Walker Instance
    // =================================================================
    logic        walker_walk_req;
    logic        walker_done;
    logic        walker_fault;
    logic [31:0] walker_fault_addr;
    logic [3:0]  walker_fault_code;
    logic [19:0] walker_ppn;
    logic        walker_dirty;
    logic        walker_accessed;
    logic        walker_user_out;
    logic        walker_writable;
    logic        walker_busy;

    f386_page_walker u_walker (
        .clk             (clk),
        .rst_n           (rst_n),
        .walk_req        (walker_walk_req),
        .walk_vaddr      (r_linear_addr),
        .walk_write      (r_write),
        .walk_user       (r_user),
        .walk_done       (walker_done),
        .walk_fault      (walker_fault),
        .walk_fault_addr (walker_fault_addr),
        .walk_fault_code (walker_fault_code),
        .walk_ppn        (walker_ppn),
        .walk_dirty      (walker_dirty),
        .walk_accessed   (walker_accessed),
        .walk_user_out   (walker_user_out),
        .walk_writable   (walker_writable),
        .pt_mem_req      (pt_req),
        .pt_mem_addr     (pt_addr),
        .pt_mem_wdata    (pt_wdata),
        .pt_mem_wr       (pt_wr),
        .pt_mem_rdata    (pt_rdata),
        .pt_mem_ack      (pt_ack),
        .cr3             (cr3),
        .busy            (walker_busy)
    );

    // =================================================================
    // Registered response
    // =================================================================
    logic [31:0] r_resp_paddr;
    logic        r_resp_fault;
    logic [31:0] r_resp_fault_addr;
    logic [3:0]  r_resp_fault_code;

    // =================================================================
    // FSM + Datapath
    // =================================================================
    assign busy = (state != XL_IDLE);

    always_comb begin
        // Defaults
        tlb_lookup_valid  = 1'b0;
        tlb_lookup_vaddr  = r_linear_addr;
        tlb_lookup_write  = r_write;
        tlb_lookup_user   = r_user;
        tlb_fill_valid    = 1'b0;
        tlb_fill_vpn      = '0;
        tlb_fill_ppn      = '0;
        tlb_fill_dirty    = 1'b0;
        tlb_fill_accessed = 1'b0;
        tlb_fill_user     = 1'b0;
        tlb_fill_writable = 1'b0;
        resp_valid        = 1'b0;
        resp_paddr        = 32'd0;
        resp_fault        = 1'b0;
        resp_fault_addr   = 32'd0;
        resp_fault_code   = 4'd0;

        case (state)
            XL_IDLE: begin
                // Paging OFF passthrough handled in FSM below
            end

            XL_LOOKUP: begin
                // TLB lookup is in pipeline (registered in cycle 1)
                tlb_lookup_valid = 1'b1;
                tlb_lookup_vaddr = r_linear_addr;
                tlb_lookup_write = r_write;
                tlb_lookup_user  = r_user;
            end

            XL_WAIT_LOOKUP: begin
                // TLB result available this cycle
            end

            XL_WALK: begin
                // Walker running — nothing to drive combinationally
            end

            XL_FILL: begin
                // Fill TLB with walk result
                tlb_fill_valid    = 1'b1;
                tlb_fill_vpn      = r_linear_addr[31:12];
                tlb_fill_ppn      = r_resp_paddr[31:12];
                tlb_fill_dirty    = r_resp_fault ? 1'b0 : 1'b1;  // Use walker result
                tlb_fill_accessed = 1'b1;
                tlb_fill_user     = walker_user_out;
                tlb_fill_writable = walker_writable;
            end

            XL_RESP: begin
                resp_valid      = 1'b1;
                resp_paddr      = r_resp_paddr;
                resp_fault      = r_resp_fault;
                resp_fault_addr = r_resp_fault_addr;
                resp_fault_code = r_resp_fault_code;
            end

            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= XL_IDLE;
            r_linear_addr     <= 32'd0;
            r_write           <= 1'b0;
            r_user            <= 1'b0;
            r_resp_paddr      <= 32'd0;
            r_resp_fault      <= 1'b0;
            r_resp_fault_addr <= 32'd0;
            r_resp_fault_code <= 4'd0;
        end else if (flush) begin
            state             <= XL_IDLE;
        end else begin
            case (state)
                XL_IDLE: begin
                    if (req_valid) begin
                        r_linear_addr <= req_addr_linear;
                        r_write       <= req_write;
                        r_user        <= req_user;

                        if (!paging_enabled) begin
                            // Paging OFF: passthrough
                            r_resp_paddr      <= req_addr_linear;
                            r_resp_fault      <= 1'b0;
                            r_resp_fault_addr <= 32'd0;
                            r_resp_fault_code <= 4'd0;
                            state             <= XL_RESP;
                        end else begin
                            // Start TLB lookup
                            state <= XL_LOOKUP;
                        end
                    end
                end

                XL_LOOKUP: begin
                    // TLB lookup was initiated in combinational block;
                    // result available next cycle
                    state <= XL_WAIT_LOOKUP;
                end

                XL_WAIT_LOOKUP: begin
                    if (tlb_fault) begin
                        // TLB hit but permission fault
                        r_resp_paddr      <= 32'd0;
                        r_resp_fault      <= 1'b1;
                        r_resp_fault_addr <= r_linear_addr;
                        r_resp_fault_code <= tlb_fault_code;
                        state             <= XL_RESP;
                    end else if (tlb_hit) begin
                        // TLB hit — translated address
                        r_resp_paddr      <= tlb_paddr;
                        r_resp_fault      <= 1'b0;
                        r_resp_fault_addr <= 32'd0;
                        r_resp_fault_code <= 4'd0;
                        state             <= XL_RESP;
                    end else begin
                        // TLB miss — launch page walk
                        state <= XL_WALK;
                    end
                end

                XL_WALK: begin
                    if (!walker_busy) begin
                        // Launch walk on first cycle in XL_WALK
                        // walker_walk_req is set combinationally below
                    end

                    if (walker_done) begin
                        if (walker_fault) begin
                            r_resp_paddr      <= 32'd0;
                            r_resp_fault      <= 1'b1;
                            r_resp_fault_addr <= walker_fault_addr;
                            r_resp_fault_code <= walker_fault_code;
                            state             <= XL_RESP;  // Skip fill on fault
                        end else begin
                            r_resp_paddr      <= {walker_ppn, r_linear_addr[11:0]};
                            r_resp_fault      <= 1'b0;
                            r_resp_fault_addr <= 32'd0;
                            r_resp_fault_code <= 4'd0;
                            state             <= XL_FILL;
                        end
                    end
                end

                XL_FILL: begin
                    // TLB fill happens combinationally; move to response
                    state <= XL_RESP;
                end

                XL_RESP: begin
                    // Response driven combinationally; return to idle
                    state <= XL_IDLE;
                end

                default: state <= XL_IDLE;
            endcase
        end
    end

    // Walker walk_req: pulse on first cycle in XL_WALK when walker is idle
    // This needs to be outside the case statement since it's read in comb block
    logic walk_req_sent;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            walk_req_sent <= 1'b0;
        else if (flush)
            walk_req_sent <= 1'b0;
        else if (state == XL_WAIT_LOOKUP && !tlb_hit && !tlb_fault)
            walk_req_sent <= 1'b0;  // Entering XL_WALK next cycle
        else if (state == XL_WALK && !walker_busy && !walk_req_sent)
            walk_req_sent <= 1'b1;
        else if (state == XL_IDLE)
            walk_req_sent <= 1'b0;
    end

    // Drive walker request in comb always block
    always_comb begin
        walker_walk_req = (state == XL_WALK) && !walker_busy && !walk_req_sent;
    end

endmodule
