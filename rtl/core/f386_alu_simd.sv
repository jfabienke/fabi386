/*
 * fabi386: SIMD Execution Unit
 * Version 2.0: Added Saturating Arithmetic and Alpha Blending.
 */

import f386_pkg::*;

module f386_alu_simd (
    input  logic [31:0] op_a,
    input  logic [31:0] op_b,
    input  logic [3:0]  simd_ctrl,
    output logic [31:0] result
);

    // Internal wires for split byte lanes
    logic [7:0] a_bytes [4];
    logic [7:0] b_bytes [4];
    logic [7:0] res_bytes [4];

    assign {a_bytes[3], a_bytes[2], a_bytes[1], a_bytes[0]} = op_a;
    assign {b_bytes[3], b_bytes[2], b_bytes[1], b_bytes[0]} = op_b;

    genvar i;
    generate
        for (i = 0; i < 4; i++) begin : byte_lanes
            logic [8:0] sum_ext;
            logic [8:0] sub_ext;

            assign sum_ext = {1'b0, a_bytes[i]} + {1'b0, b_bytes[i]};
            assign sub_ext = {1'b0, a_bytes[i]} - {1'b0, b_bytes[i]};

            always_comb begin
                case (simd_ctrl)
                    4'd0: res_bytes[i] = a_bytes[i] + b_bytes[i]; // Wrapped ADD
                    4'd1: res_bytes[i] = a_bytes[i] - b_bytes[i]; // Wrapped SUB
                    4'd2: res_bytes[i] = (sum_ext > 9'hFF) ? 8'hFF : sum_ext[7:0]; // SATURATING ADD
                    4'd3: res_bytes[i] = (sub_ext[8]) ? 8'h00 : sub_ext[7:0];       // SATURATING SUB
                    4'd4: res_bytes[i] = (a_bytes[i] > b_bytes[i]) ? a_bytes[i] : b_bytes[i]; // MAX
                    4'd5: res_bytes[i] = (a_bytes[i] < b_bytes[i]) ? a_bytes[i] : b_bytes[i]; // MIN
                    4'd6: res_bytes[i] = (a_bytes[i] >> 1) + (b_bytes[i] >> 1); // Alpha Blend (50/50)
                    default: res_bytes[i] = a_bytes[i];
                endcase
            end
        end
    endgenerate

    assign result = {res_bytes[3], res_bytes[2], res_bytes[1], res_bytes[0]};

endmodule
