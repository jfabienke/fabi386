/*
 * fabi386: DTLB Frontend Testbench Wrapper
 * Wraps f386_dtlb_frontend with page table memory model.
 * Clock/reset and scenario sequencing driven from C++.
 */

import f386_pkg::*;

module dtlb_frontend_tb (
    input  logic        clk,
    input  logic        rst_n,

    // Request controls
    input  logic        tb_req_valid,
    input  logic [31:0] tb_req_addr,
    input  logic        tb_req_write,
    input  logic        tb_req_user,

    // Response observability
    output logic        tb_resp_valid,
    output logic [31:0] tb_resp_paddr,
    output logic        tb_resp_fault,
    output logic [31:0] tb_resp_fault_addr,
    output logic [3:0]  tb_resp_fault_code,
    output logic        tb_busy,

    // Control
    input  logic        tb_paging_enabled,
    input  logic        tb_flush_all,
    input  logic        tb_flush,
    input  logic        tb_invlpg_valid,
    input  logic [31:0] tb_invlpg_vaddr,
    input  logic [31:0] tb_cr3,

    // Page table memory write port (from C++ testbench)
    input  logic        tb_pt_mem_write,
    input  logic [31:0] tb_pt_mem_write_addr,
    input  logic [31:0] tb_pt_mem_write_data
);

    // Page walker memory interface
    logic [31:0] pt_addr, pt_wdata, pt_rdata;
    logic        pt_req, pt_wr, pt_ack;

    f386_dtlb_frontend u_dtlb (
        .clk              (clk),
        .rst_n            (rst_n),
        .flush            (tb_flush),
        .req_valid        (tb_req_valid),
        .req_addr_linear  (tb_req_addr),
        .req_write        (tb_req_write),
        .req_user         (tb_req_user),
        .resp_valid       (tb_resp_valid),
        .resp_paddr       (tb_resp_paddr),
        .resp_fault       (tb_resp_fault),
        .resp_fault_addr  (tb_resp_fault_addr),
        .resp_fault_code  (tb_resp_fault_code),
        .busy             (tb_busy),
        .paging_enabled   (tb_paging_enabled),
        .flush_all        (tb_flush_all),
        .invlpg_valid     (tb_invlpg_valid),
        .invlpg_vaddr     (tb_invlpg_vaddr),
        .cr3              (tb_cr3),
        .pt_addr          (pt_addr),
        .pt_wdata         (pt_wdata),
        .pt_rdata         (pt_rdata),
        .pt_req           (pt_req),
        .pt_wr            (pt_wr),
        .pt_ack           (pt_ack)
    );

    // Simple page table memory (16KB, word-addressed)
    localparam int PT_MEM_DEPTH = 4096;
    logic [31:0] pt_mem [0:PT_MEM_DEPTH-1];

    // Memory response: 1-cycle latency
    logic pt_req_pending;
    logic [31:0] pt_req_addr_r;
    logic pt_req_wr_r;
    logic [31:0] pt_req_wdata_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pt_req_pending <= 1'b0;
            pt_ack         <= 1'b0;
            pt_rdata       <= 32'd0;
        end else begin
            pt_ack <= 1'b0;

            if (pt_req_pending) begin
                if (pt_req_wr_r) begin
                    pt_mem[pt_req_addr_r[13:2]] <= pt_req_wdata_r;
                end else begin
                    pt_rdata <= pt_mem[pt_req_addr_r[13:2]];
                end
                pt_ack         <= 1'b1;
                pt_req_pending <= 1'b0;
            end

            if (pt_req && !pt_req_pending) begin
                pt_req_pending  <= 1'b1;
                pt_req_addr_r   <= pt_addr;
                pt_req_wr_r     <= pt_wr;
                pt_req_wdata_r  <= pt_wdata;
            end
        end
    end

    // C++ testbench write port
    /* verilator lint_off MULTIDRIVEN */
    always_ff @(posedge clk) begin
        if (tb_pt_mem_write) begin
            pt_mem[tb_pt_mem_write_addr[13:2]] <= tb_pt_mem_write_data;
        end
    end
    /* verilator lint_on MULTIDRIVEN */

endmodule
