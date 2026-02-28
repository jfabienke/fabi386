/*
 * fabi386: Address Generation Unit (AGU)
 * ----------------------------------------
 * Computes effective address for memory operations:
 *   EA = seg_base + base_reg + (index_reg * scale) + displacement
 *
 * Supports all x86 addressing modes:
 *   - Direct:    seg:[disp]
 *   - Register:  seg:[base]
 *   - Indexed:   seg:[base + index*scale + disp]
 *
 * Output is a 32-bit linear address (pre-paging).
 * Scale factor: 1, 2, 4, or 8 (encoded as 2-bit log2).
 */

import f386_pkg::*;

module f386_agu (
    // Segment base (from f386_seg_cache)
    input  logic [31:0]  seg_base,

    // Base register value (0 if no base)
    input  logic [31:0]  base_val,
    input  logic         base_valid,

    // Index register value (0 if no index)
    input  logic [31:0]  index_val,
    input  logic         index_valid,

    // Scale factor: 0=1, 1=2, 2=4, 3=8
    input  logic [1:0]   scale,

    // Displacement (sign-extended to 32 bits)
    input  logic [31:0]  displacement,

    // Output: 32-bit linear address
    output logic [31:0]  linear_addr,

    // A20 gate (masks bit 20 for 8086 wraparound compatibility)
    input  logic         a20_gate
);

    // Scale the index: index * (1 << scale)
    logic [31:0] scaled_index;
    always_comb begin
        if (index_valid) begin
            case (scale)
                2'd0: scaled_index = index_val;
                2'd1: scaled_index = {index_val[30:0], 1'b0};     // *2
                2'd2: scaled_index = {index_val[29:0], 2'b00};    // *4
                2'd3: scaled_index = {index_val[28:0], 3'b000};   // *8
            endcase
        end else begin
            scaled_index = 32'd0;
        end
    end

    // Effective address computation
    logic [31:0] effective_addr;
    assign effective_addr = (base_valid ? base_val : 32'd0)
                          + scaled_index
                          + displacement;

    // Linear address = segment base + effective address
    logic [31:0] raw_linear;
    assign raw_linear = seg_base + effective_addr;

    // A20 gate: when disabled (a20_gate=0), mask bit 20 to 0
    // This emulates the 8086 address wraparound at 1MB boundary
    assign linear_addr = a20_gate ? raw_linear
                                  : {raw_linear[31:21], 1'b0, raw_linear[19:0]};

endmodule
