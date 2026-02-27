/*
 * fabi386: Register Rename Table
 * ------------------------------
 * Eliminates WAW/WAR by mapping 8 Arch registers to 32 Physical.
 */

import f386_pkg::*;

module f386_register_rename (
    input  logic         clk,
    input  logic         reset_n,

    input  logic [2:0]   arch_dest_u,
    output phys_reg_t    phys_dest_u,
    output logic         can_rename,

    input  logic         retire_valid,
    input  phys_reg_t    retire_phys
);

    phys_reg_t map_table [8];
    logic [31:0] free_list;

    always_comb begin
        phys_dest_u = 5'd0;
        can_rename = 1'b0;
        for (int i = 8; i < 32; i++) begin
            if (free_list[i]) begin
                phys_dest_u = i[4:0];
                can_rename = 1'b1;
                break;
            end
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (int i = 0; i < 8; i++) map_table[i] <= i[4:0];
            free_list <= 32'hFFFFFFF0;
        end else begin
            if (can_rename) begin
                map_table[arch_dest_u] <= phys_dest_u;
                free_list[phys_dest_u] <= 1'b0;
            end
            if (retire_valid) free_list[retire_phys] <= 1'b1;
        end
    end

endmodule
