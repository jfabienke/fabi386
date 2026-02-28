/*
 * fabi386: Prefetch FIFO with Fault Codes (v1.0)
 * ------------------------------------------------
 * 16-entry FIFO buffering fetch data between memory and decoder.
 * Each entry: 32-bit data + 4-bit status (fault codes).
 *
 * Fault codes (ao486 convention):
 *   0000 = valid data
 *   0001 = GP fault (limit violation)
 *   0010 = PF (page fault during code fetch)
 *
 * The FIFO decouples fetch bandwidth from decode consumption,
 * absorbing I-cache miss bubbles and variable-length instruction
 * decode stalls.
 *
 * Reference: ao486 prefetch_fifo.v, BOOM fetch-buffer.scala
 */

import f386_pkg::*;

module f386_fetch_fifo (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,          // Branch mispredict / mode change

    // --- Write Port (from I-cache / memory) ---
    input  logic        wr_valid,
    input  logic [31:0] wr_data,        // 4 bytes of instruction stream
    input  logic [3:0]  wr_status,      // Fault code (0 = valid)
    output logic        wr_ready,       // FIFO not full

    // --- Read Port (to decoder) ---
    output logic        rd_valid,
    output logic [31:0] rd_data,
    output logic [3:0]  rd_status,
    input  logic        rd_ready,       // Decoder consumed this entry

    // --- Status ---
    output logic [4:0]  count           // Entries currently used
);

    localparam int DEPTH = 16;
    localparam int PTR_W = $clog2(DEPTH);

    // Storage: data + status packed together
    logic [35:0] fifo_mem [DEPTH];      // {status[3:0], data[31:0]}

    // Pointers
    logic [PTR_W:0] wr_ptr;            // Extra bit for full/empty
    logic [PTR_W:0] rd_ptr;

    wire [PTR_W-1:0] wr_addr = wr_ptr[PTR_W-1:0];
    wire [PTR_W-1:0] rd_addr = rd_ptr[PTR_W-1:0];

    // Full/empty logic
    wire ptr_match = (wr_ptr[PTR_W-1:0] == rd_ptr[PTR_W-1:0]);
    wire same_wrap = (wr_ptr[PTR_W]     == rd_ptr[PTR_W]);
    wire empty     = ptr_match &&  same_wrap;
    wire full      = ptr_match && !same_wrap;

    // Count
    assign count = wr_ptr - rd_ptr;

    // Output
    assign wr_ready = !full;
    assign rd_valid  = !empty;
    assign rd_data   = fifo_mem[rd_addr][31:0];
    assign rd_status = fifo_mem[rd_addr][35:32];

    // Bypass: if FIFO is empty and both sides are ready, pass through
    // without registering (reduces latency by 1 cycle on empty FIFO)
    wire bypass = empty && wr_valid && rd_ready;

    always_comb begin
        if (bypass) begin
            rd_data   = wr_data;
            rd_status = wr_status;
            rd_valid  = 1'b1;
        end
    end

    // Pointer and memory update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else if (flush) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            // Write
            if (wr_valid && wr_ready && !bypass) begin
                fifo_mem[wr_addr] <= {wr_status, wr_data};
                wr_ptr <= wr_ptr + 1'b1;
            end

            // Read
            if (rd_ready && rd_valid && !bypass) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
        end
    end

endmodule
