/*
 * fabi386: Reorder Buffer (ROB)
 * -----------------------------
 * Tracks instructions in-flight to maintain in-order retirement.
 */

import f386_pkg::*;

module f386_rob (
    input  logic         clk,
    input  logic         rst_n,

    input  ooo_instr_t   dispatch_u,
    input  ooo_instr_t   dispatch_v,

    output rob_entry_t   retire_u,
    output rob_entry_t   retire_v
);

    rob_entry_t rob_mem [15:0];
    logic [3:0] head, tail;

    always_ff @(posedge clk) begin
        if (!rst_n) tail <= '0;
        else if (dispatch_u.valid) begin
            rob_mem[tail].instr <= dispatch_u;
            rob_mem[tail].ready <= 1'b0;
            tail <= tail + 1;
        end
    end

    always_comb begin
        retire_u = '0;
        if (rob_mem[head].ready) retire_u = rob_mem[head];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) head <= '0;
        else if (retire_u.valid) head <= head + 1;
    end

endmodule
