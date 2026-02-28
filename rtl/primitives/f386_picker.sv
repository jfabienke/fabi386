/*
 * fabi386: Priority Picker (Encoder + Selector)
 * -----------------------------------------------
 * Configurable-width priority encoder that selects the first N
 * asserted bits from a request vector. Used by issue queue, free
 * list, and LSQ for oldest-first / priority-based selection.
 *
 * Reference: rsd Processor/Src/Primitives/Picker.sv
 *
 * Parameters:
 *   WIDTH      — number of request lines
 *   NUM_PICK   — how many winners to pick (1 = simple priority encoder)
 *
 * Outputs:
 *   grant      — one-hot grant vector per pick slot
 *   grant_idx  — binary index of each picked entry
 *   valid      — whether each pick slot found a winner
 */

module f386_picker #(
    parameter int WIDTH    = 8,
    parameter int NUM_PICK = 1
)(
    input  logic [WIDTH-1:0]                   request,

    output logic [WIDTH-1:0]                   grant     [NUM_PICK],
    output logic [$clog2(WIDTH)-1:0]           grant_idx [NUM_PICK],
    output logic                               valid     [NUM_PICK]
);

    localparam int IDX_W = $clog2(WIDTH);

    // Cascading priority: each pick slot masks out previous winners
    logic [WIDTH-1:0] remaining [NUM_PICK+1];

    assign remaining[0] = request;

    generate
        for (genvar p = 0; p < NUM_PICK; p++) begin : gen_pick

            // Find lowest set bit in remaining requests
            logic [WIDTH-1:0] lowest_bit;
            assign lowest_bit = remaining[p] & (~remaining[p] + WIDTH'(1));

            // One-hot grant
            assign grant[p] = lowest_bit;

            // Binary index via priority encoder
            always_comb begin
                grant_idx[p] = '0;
                valid[p]     = 1'b0;
                for (int i = 0; i < WIDTH; i++) begin
                    if (lowest_bit[i]) begin
                        grant_idx[p] = IDX_W'(i);
                        valid[p]     = 1'b1;
                        break;
                    end
                end
            end

            // Mask out this winner for next pick slot
            assign remaining[p+1] = remaining[p] & ~lowest_bit;

        end
    endgenerate

endmodule
