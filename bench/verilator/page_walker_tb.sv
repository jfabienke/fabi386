/*
 * fabi386: Page Walker Testbench Wrapper
 * Standalone wrapper around f386_page_walker for Verilator.
 * Includes a simple synchronous page table memory model.
 */

import f386_pkg::*;

module page_walker_tb (
    input  logic         clk,
    input  logic         rst_n,

    // Walk request
    input  logic         tb_walk_req,
    input  logic [31:0]  tb_walk_vaddr,
    input  logic         tb_walk_write,
    input  logic         tb_walk_user,

    // Walk result
    output logic         tb_walk_done,
    output logic         tb_walk_fault,
    output logic [31:0]  tb_walk_fault_addr,
    output logic [3:0]   tb_walk_fault_code,
    output logic [19:0]  tb_walk_ppn,
    output logic         tb_walk_dirty,
    output logic         tb_walk_accessed,
    output logic         tb_walk_user_out,
    output logic         tb_walk_writable,
    output logic         tb_busy,

    // CR3
    input  logic [31:0]  tb_cr3,

    // Page table memory write port (from C++ testbench)
    input  logic         tb_pt_mem_write,
    input  logic [31:0]  tb_pt_mem_write_addr,
    input  logic [31:0]  tb_pt_mem_write_data
);

    // Page walker memory interface
    logic         pt_mem_req;
    logic [31:0]  pt_mem_addr;
    logic [31:0]  pt_mem_wdata;
    logic         pt_mem_wr;
    logic [31:0]  pt_mem_rdata;
    logic         pt_mem_ack;

    // Instantiate page walker
    f386_page_walker u_walker (
        .clk             (clk),
        .rst_n           (rst_n),
        .flush           (1'b0),           // No flush in standalone walker tests
        .walk_req        (tb_walk_req),
        .walk_vaddr      (tb_walk_vaddr),
        .walk_write      (tb_walk_write),
        .walk_user       (tb_walk_user),
        .walk_done       (tb_walk_done),
        .walk_fault      (tb_walk_fault),
        .walk_fault_addr (tb_walk_fault_addr),
        .walk_fault_code (tb_walk_fault_code),
        .walk_ppn        (tb_walk_ppn),
        .walk_dirty      (tb_walk_dirty),
        .walk_accessed   (tb_walk_accessed),
        .walk_user_out   (tb_walk_user_out),
        .walk_writable   (tb_walk_writable),
        .pt_mem_req      (pt_mem_req),
        .pt_mem_addr     (pt_mem_addr),
        .pt_mem_wdata    (pt_mem_wdata),
        .pt_mem_wr       (pt_mem_wr),
        .pt_mem_rdata    (pt_mem_rdata),
        .pt_mem_ack      (pt_mem_ack),
        .cr3             (tb_cr3),
        .busy            (tb_busy)
    );

    // Simple page table memory (4KB, word-addressed)
    // Addresses are byte addresses — we use [11:2] to index 1024 dwords
    localparam int PT_MEM_DEPTH = 4096;  // 4K dwords = 16KB
    logic [31:0] pt_mem [0:PT_MEM_DEPTH-1];

    // Memory response: 1-cycle latency
    logic pt_req_pending;
    logic [31:0] pt_req_addr_r;
    logic pt_req_wr_r;
    logic [31:0] pt_req_wdata_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pt_req_pending <= 1'b0;
            pt_mem_ack     <= 1'b0;
            pt_mem_rdata   <= 32'd0;
        end else begin
            pt_mem_ack <= 1'b0;

            if (pt_req_pending) begin
                if (pt_req_wr_r) begin
                    pt_mem[pt_req_addr_r[13:2]] <= pt_req_wdata_r;
                end else begin
                    pt_mem_rdata <= pt_mem[pt_req_addr_r[13:2]];
                end
                pt_mem_ack     <= 1'b1;
                pt_req_pending <= 1'b0;
            end

            if (pt_mem_req && !pt_req_pending) begin
                pt_req_pending  <= 1'b1;
                pt_req_addr_r   <= pt_mem_addr;
                pt_req_wr_r     <= pt_mem_wr;
                pt_req_wdata_r  <= pt_mem_wdata;
            end
        end
    end

    // C++ testbench write port (writes directly into pt_mem)
    /* verilator lint_off MULTIDRIVEN */
    always_ff @(posedge clk) begin
        if (tb_pt_mem_write) begin
            pt_mem[tb_pt_mem_write_addr[13:2]] <= tb_pt_mem_write_data;
        end
    end
    /* verilator lint_on MULTIDRIVEN */

endmodule
