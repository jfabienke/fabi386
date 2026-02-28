/*
 * fabi386: Memory Controller / DDRAM Bridge
 * --------------------------------------------
 * Bridges between the CPU's memory interface and the MiSTer DDRAM
 * (DDR3 via HPS). Handles:
 *   - Cache line fill requests (32-byte lines)
 *   - Single-word reads/writes for uncacheable I/O
 *   - A20 gate (8086 address wraparound compatibility)
 *   - Memory map: 0-640KB conventional, 640K-1MB UMB/ROM, 1MB+ extended
 *
 * MiSTer DDRAM interface:
 *   The HPS I/O bridge provides a simple request/acknowledge interface
 *   to DDR3 memory via the ARM HPS. This module adapts between the
 *   CPU's synchronous memory port and the DDRAM bridge protocol.
 *
 * Reference: ao486_MiSTer ao486.sv memory section
 */

import f386_pkg::*;

module f386_mem_ctrl (
    input  logic         clk,
    input  logic         rst_n,

    // --- CPU Memory Interface (from LSQ / instruction fetch) ---
    // Instruction fetch port
    input  logic [31:0]  ifetch_addr,
    output logic [127:0] ifetch_data,     // 16-byte fetch block
    output logic         ifetch_valid,
    input  logic         ifetch_req,

    // Data port (from LSQ)
    input  logic [31:0]  data_addr,
    input  logic [31:0]  data_wdata,
    output logic [31:0]  data_rdata,
    input  logic         data_req,
    input  logic         data_wr,
    input  logic [1:0]   data_size,       // 0=byte, 1=word, 2=dword
    output logic         data_ack,

    // Page walker port
    input  logic [31:0]  pt_addr,
    input  logic [31:0]  pt_wdata,
    output logic [31:0]  pt_rdata,
    input  logic         pt_req,
    input  logic         pt_wr,
    output logic         pt_ack,

    // --- A20 Gate ---
    input  logic         a20_gate,        // 1=enabled (normal), 0=wrap at 1MB

    // --- DDRAM Interface (MiSTer framework) ---
    output logic [27:0]  ddram_addr,      // Byte address (256MB range)
    output logic [7:0]   ddram_burstcnt,  // Burst count (1 for single, 8 for cache line)
    output logic [63:0]  ddram_din,       // Write data (64-bit wide)
    output logic [7:0]   ddram_be,        // Byte enables
    output logic         ddram_we,        // Write enable
    output logic         ddram_rd,        // Read request
    input  logic [63:0]  ddram_dout,      // Read data
    input  logic         ddram_dout_ready, // Read data valid
    input  logic         ddram_busy       // DDRAM is busy
);

    // =========================================================
    // Address Mapping + A20 Gate
    // =========================================================
    function automatic logic [31:0] apply_a20(input logic [31:0] addr, input logic gate);
        if (gate)
            return addr;
        else
            return {addr[31:21], 1'b0, addr[19:0]};  // Mask bit 20
    endfunction

    // =========================================================
    // Arbiter State Machine
    // =========================================================
    // Priority: page walker > data > instruction fetch
    // (Page walker is blocking and rare; data has higher latency sensitivity)

    typedef enum logic [2:0] {
        ARB_IDLE    = 3'd0,
        ARB_IFETCH  = 3'd1,
        ARB_DATA    = 3'd2,
        ARB_PT      = 3'd3,
        ARB_WAIT    = 3'd4
    } arb_state_t;

    arb_state_t state;

    logic [31:0] arb_addr;
    logic [31:0] arb_wdata;
    logic        arb_wr;
    logic [2:0]  arb_source;  // Which port initiated the request
    logic [1:0]  arb_size;

    // Instruction fetch accumulator (128-bit from 2x 64-bit reads)
    logic [127:0] ifetch_buf;
    logic          ifetch_phase;  // 0=first 64-bit, 1=second 64-bit

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ARB_IDLE;
            ifetch_valid <= 1'b0;
            data_ack     <= 1'b0;
            pt_ack       <= 1'b0;
            ddram_rd     <= 1'b0;
            ddram_we     <= 1'b0;
        end else begin
            ifetch_valid <= 1'b0;
            data_ack     <= 1'b0;
            pt_ack       <= 1'b0;
            ddram_rd     <= 1'b0;
            ddram_we     <= 1'b0;

            case (state)
                ARB_IDLE: begin
                    if (pt_req && !ddram_busy) begin
                        // Page walker has highest priority
                        arb_addr   <= apply_a20(pt_addr, a20_gate);
                        arb_wdata  <= pt_wdata;
                        arb_wr     <= pt_wr;
                        arb_source <= 3'd3;
                        state      <= ARB_PT;
                    end else if (data_req && !ddram_busy) begin
                        arb_addr   <= apply_a20(data_addr, a20_gate);
                        arb_wdata  <= data_wdata;
                        arb_wr     <= data_wr;
                        arb_source <= 3'd2;
                        arb_size   <= data_size;
                        state      <= ARB_DATA;
                    end else if (ifetch_req && !ddram_busy) begin
                        arb_addr   <= apply_a20(ifetch_addr, a20_gate);
                        arb_wr     <= 1'b0;
                        arb_source <= 3'd1;
                        ifetch_phase <= 1'b0;
                        state      <= ARB_IFETCH;
                    end
                end

                ARB_IFETCH: begin
                    if (!ddram_busy) begin
                        ddram_addr     <= arb_addr[27:0] + (ifetch_phase ? 28'd8 : 28'd0);
                        ddram_burstcnt <= 8'd1;
                        ddram_rd       <= 1'b1;
                        state          <= ARB_WAIT;
                    end
                end

                ARB_DATA: begin
                    if (!ddram_busy) begin
                        ddram_addr     <= arb_addr[27:0];
                        ddram_burstcnt <= 8'd1;
                        if (arb_wr) begin
                            ddram_din <= {32'd0, arb_wdata};
                            // Byte enable based on size and address alignment
                            case (arb_size)
                                2'd0: ddram_be <= 8'h01 << arb_addr[2:0]; // Byte
                                2'd1: ddram_be <= 8'h03 << arb_addr[2:0]; // Word
                                2'd2: ddram_be <= 8'h0F << arb_addr[2:0]; // Dword
                                default: ddram_be <= 8'hFF;
                            endcase
                            ddram_we <= 1'b1;
                            data_ack <= 1'b1;
                            state    <= ARB_IDLE;
                        end else begin
                            ddram_rd <= 1'b1;
                            state    <= ARB_WAIT;
                        end
                    end
                end

                ARB_PT: begin
                    if (!ddram_busy) begin
                        ddram_addr     <= arb_addr[27:0];
                        ddram_burstcnt <= 8'd1;
                        if (arb_wr) begin
                            ddram_din <= {32'd0, arb_wdata};
                            ddram_be  <= 8'h0F;
                            ddram_we  <= 1'b1;
                            pt_ack    <= 1'b1;
                            state     <= ARB_IDLE;
                        end else begin
                            ddram_rd <= 1'b1;
                            state    <= ARB_WAIT;
                        end
                    end
                end

                ARB_WAIT: begin
                    if (ddram_dout_ready) begin
                        case (arb_source)
                            3'd1: begin // Instruction fetch
                                if (!ifetch_phase) begin
                                    ifetch_buf[63:0] <= ddram_dout;
                                    ifetch_phase     <= 1'b1;
                                    state            <= ARB_IFETCH;
                                end else begin
                                    ifetch_buf[127:64] <= ddram_dout;
                                    ifetch_data  <= {ddram_dout, ifetch_buf[63:0]};
                                    ifetch_valid <= 1'b1;
                                    state        <= ARB_IDLE;
                                end
                            end
                            3'd2: begin // Data read
                                data_rdata <= ddram_dout[31:0];
                                data_ack   <= 1'b1;
                                state      <= ARB_IDLE;
                            end
                            3'd3: begin // Page walker read
                                pt_rdata <= ddram_dout[31:0];
                                pt_ack   <= 1'b1;
                                state    <= ARB_IDLE;
                            end
                            default: state <= ARB_IDLE;
                        endcase
                    end
                end

                default: state <= ARB_IDLE;
            endcase
        end
    end

endmodule
