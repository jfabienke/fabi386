/*
 * fabi386: Physical Register File (4R2W)
 * ----------------------------------------
 * 32×32-bit register file with 4 combinational read ports (U src_a/b,
 * V src_a/b) and 2 registered write ports from the CDB.  Read ports
 * include same-cycle CDB bypass so that an instruction issuing in the
 * same cycle as a CDB writeback sees the new value.
 */

import f386_pkg::*;

module f386_phys_regfile (
    input  logic         clk,
    input  logic         rst_n,

    // Read ports (combinational with CDB bypass)
    input  phys_reg_t    rd_addr_a,      // U-pipe source A
    input  phys_reg_t    rd_addr_b,      // U-pipe source B
    input  phys_reg_t    rd_addr_c,      // V-pipe source A
    input  phys_reg_t    rd_addr_d,      // V-pipe source B
    output logic [31:0]  rd_data_a,
    output logic [31:0]  rd_data_b,
    output logic [31:0]  rd_data_c,
    output logic [31:0]  rd_data_d,

    // Write ports (from CDB, registered)
    input  logic         wr_en_0,
    input  phys_reg_t    wr_addr_0,
    input  logic [31:0]  wr_data_0,
    input  logic         wr_en_1,
    input  phys_reg_t    wr_addr_1,
    input  logic [31:0]  wr_data_1
);

    // =========================================================
    // Storage
    // =========================================================
    logic [31:0] regfile [CONF_PHYS_REG_NUM];

    // =========================================================
    // Read ports with CDB bypass (port 1 has priority over port 0)
    // =========================================================
    always_comb begin
        rd_data_a = regfile[rd_addr_a];
        if (wr_en_0 && wr_addr_0 == rd_addr_a) rd_data_a = wr_data_0;
        if (wr_en_1 && wr_addr_1 == rd_addr_a) rd_data_a = wr_data_1;
    end

    always_comb begin
        rd_data_b = regfile[rd_addr_b];
        if (wr_en_0 && wr_addr_0 == rd_addr_b) rd_data_b = wr_data_0;
        if (wr_en_1 && wr_addr_1 == rd_addr_b) rd_data_b = wr_data_1;
    end

    always_comb begin
        rd_data_c = regfile[rd_addr_c];
        if (wr_en_0 && wr_addr_0 == rd_addr_c) rd_data_c = wr_data_0;
        if (wr_en_1 && wr_addr_1 == rd_addr_c) rd_data_c = wr_data_1;
    end

    always_comb begin
        rd_data_d = regfile[rd_addr_d];
        if (wr_en_0 && wr_addr_0 == rd_addr_d) rd_data_d = wr_data_0;
        if (wr_en_1 && wr_addr_1 == rd_addr_d) rd_data_d = wr_data_1;
    end

    // =========================================================
    // Write ports (registered)
    // =========================================================
    always_ff @(posedge clk) begin
        if (wr_en_0) regfile[wr_addr_0] <= wr_data_0;
        if (wr_en_1) regfile[wr_addr_1] <= wr_data_1;
    end

endmodule
