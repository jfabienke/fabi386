/*
 * fabi386: Unified L2 Cache (128KB)
 * ----------------------------------
 * BRAM-backed 2-way set associative cache.
 */

import f386_pkg::*;

module f386_l2_cache (
    input  logic         clk,
    input  logic         reset_n,

    input  logic [31:0]  l1_addr,
    input  logic         l1_req,
    output logic [31:0]  l1_dout,
    output logic         l1_ack,

    output logic [31:0]  hr_addr,
    input  logic [31:0]  hr_data_i,
    output logic         hr_req,
    input  logic         hr_ack
);

    // 128KB = 8192 words per way
    struct packed {
        logic [18:0] tag;
        logic        valid;
    } tags [8192];

    logic [31:0] data [8192];
    logic [12:0] index;
    assign index = l1_addr[14:2];

    typedef enum logic [1:0] { IDLE, LOOKUP, FILL } state_t;
    state_t state;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) state <= IDLE;
        else case (state)
            IDLE: if (l1_req) state <= LOOKUP;
            LOOKUP: if (tags[index].valid && tags[index].tag == l1_addr[31:13]) begin
                l1_dout <= data[index];
                l1_ack  <= 1;
                state   <= IDLE;
            end else state <= FILL;
            FILL: begin
                hr_addr <= l1_addr; hr_req <= 1;
                if (hr_ack) begin
                    data[index] <= hr_data_i;
                    tags[index].valid <= 1;
                    tags[index].tag <= l1_addr[31:13];
                    state <= LOOKUP;
                end
            end
        endcase
    end

endmodule
