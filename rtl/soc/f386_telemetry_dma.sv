/*
 * fabi386: Telemetry DMA Controller (v18.0)
 * -------------------------------------------
 * Asynchronous transfer of telemetry_pkt_t records into a HyperRAM
 * circular trace buffer. Ensures the 150 MHz core never stalls for
 * slow telemetry I/O — packets are buffered and DMA'd in background.
 *
 * Each packet writes 4 words (16 bytes) to the trace buffer:
 *   Word 0: PC
 *   Word 1: {semantic_tag, op_cat, opcode, flags}
 *   Word 2: data.addr
 *   Word 3: data.value
 *
 * Buffer wraps using buf_mask for power-of-2 circular addressing.
 *
 * Adapted from Neo-386 Pro n386_telemetry_dma.
 */

import f386_pkg::*;

module f386_telemetry_dma (
    input  logic           clk,
    input  logic           reset_n,

    // Packet input from AAR engine
    input  telemetry_pkt_t pkt_in,
    input  logic           pkt_valid,
    output logic           pkt_accept,  // Back-pressure: high when DMA can accept

    // Master interface to HyperRAM
    output logic [31:0]    hr_addr,
    output logic [31:0]    hr_data,
    output logic           hr_req,
    output logic           hr_we,
    input  logic           hr_ack,

    // Configuration (via MSR)
    input  logic [31:0]    buf_base,    // Trace buffer base address in HyperRAM
    input  logic [31:0]    buf_mask     // Wrap mask (e.g., 0x0003FFFF for 256KB)
);

    logic [31:0] write_ptr;

    // Latch the packet at start of transfer
    telemetry_pkt_t pkt_latched;

    typedef enum logic [2:0] {
        S_IDLE,
        S_WORD0,     // Write PC
        S_WORD0_ACK,
        S_WORD1,     // Write metadata
        S_WORD1_ACK,
        S_WORD2,     // Write data.addr
        S_WORD2_ACK,
        S_WORD3      // Write data.value (ack returns to IDLE)
    } state_t;
    state_t state;

    assign pkt_accept = (state == S_IDLE);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            write_ptr   <= 32'd0;
            hr_req      <= 1'b0;
            hr_we       <= 1'b0;
            hr_addr     <= 32'd0;
            hr_data     <= 32'd0;
            state       <= S_IDLE;
            pkt_latched <= '0;
        end else begin
            case (state)

                S_IDLE: begin
                    hr_req <= 1'b0;
                    if (pkt_valid) begin
                        pkt_latched <= pkt_in;
                        // Word 0: PC
                        hr_addr <= buf_base + (write_ptr & buf_mask);
                        hr_data <= pkt_in.instr.pc;
                        hr_req  <= 1'b1;
                        hr_we   <= 1'b1;
                        state   <= S_WORD0_ACK;
                    end
                end

                S_WORD0_ACK: begin
                    if (hr_ack) begin
                        hr_req    <= 1'b0;
                        write_ptr <= write_ptr + 32'd4;
                        state     <= S_WORD1;
                    end
                end

                S_WORD1: begin
                    // Word 1: {8'b0, semantic_tag(4), op_cat(4), opcode(8), flags(8)}
                    hr_addr <= buf_base + (write_ptr & buf_mask);
                    hr_data <= {8'd0,
                                4'd0,  // reserved for semantic tag (filled by engine)
                                pkt_latched.instr.op_cat,
                                pkt_latched.instr.opcode,
                                pkt_latched.instr.val_a[7:0]};
                    hr_req  <= 1'b1;
                    hr_we   <= 1'b1;
                    state   <= S_WORD1_ACK;
                end

                S_WORD1_ACK: begin
                    if (hr_ack) begin
                        hr_req    <= 1'b0;
                        write_ptr <= write_ptr + 32'd4;
                        state     <= S_WORD2;
                    end
                end

                S_WORD2: begin
                    // Word 2: data.addr
                    hr_addr <= buf_base + (write_ptr & buf_mask);
                    hr_data <= pkt_latched.data.addr;
                    hr_req  <= 1'b1;
                    hr_we   <= 1'b1;
                    state   <= S_WORD2_ACK;
                end

                S_WORD2_ACK: begin
                    if (hr_ack) begin
                        hr_req    <= 1'b0;
                        write_ptr <= write_ptr + 32'd4;
                        state     <= S_WORD3;
                    end
                end

                S_WORD3: begin
                    // Word 3: data.value
                    hr_addr <= buf_base + (write_ptr & buf_mask);
                    hr_data <= pkt_latched.data.value;
                    hr_req  <= 1'b1;
                    hr_we   <= 1'b1;
                    // Wait for ack inline
                    if (hr_ack) begin
                        hr_req    <= 1'b0;
                        write_ptr <= write_ptr + 32'd4;
                        state     <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
