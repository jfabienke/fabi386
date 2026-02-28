/*
 * fabi386: I/O Port Address Decoder and Bus Arbiter
 * --------------------------------------------------
 * Decodes the 16-bit I/O address space into per-peripheral chip selects and
 * multiplexes read data from the selected device back to the CPU.
 *
 * Peripheral map (IBM PC/AT compatible):
 *   0x0020-0x0021  PIC master (8259A #1)
 *   0x0040-0x0043  PIT (8254 timer)
 *   0x0060-0x0064  PS/2 keyboard/mouse controller (8042)
 *   0x0070-0x0071  RTC / CMOS (MC146818)
 *   0x00A0-0x00A1  PIC slave  (8259A #2) -- directly ORed into pic_cs
 *   0x00C0-0x00DF  DMA page registers / controller (8237)
 *   0x03B0-0x03DF  VGA I/O range
 *
 * All I/O is single-cycle for byte-sized accesses.  Word and dword accesses
 * are serialised into sequential byte beats by this module; the CPU sees a
 * single ack when the full transfer completes.
 *
 * Design notes:
 *   - The module drives periph_io_* once per byte beat.
 *   - cpu_io_ack is raised for exactly one clk cycle when the final byte of
 *     the requested transfer has been serviced.
 *   - Unrecognised addresses produce an ack with 0xFF read data (open-bus).
 */

import f386_pkg::*;

module f386_iobus (
    input  logic         clk,
    input  logic         rst_n,

    // =====================================================================
    //  CPU interface (from execute stage I/O micro-ops)
    // =====================================================================
    input  logic [15:0]  cpu_io_addr,
    input  logic [31:0]  cpu_io_wdata,
    output logic [31:0]  cpu_io_rdata,
    input  logic         cpu_io_wr,
    input  logic         cpu_io_rd,
    input  logic [1:0]   cpu_io_size,   // 0 = byte, 1 = word, 2 = dword
    output logic         cpu_io_ack,

    // =====================================================================
    //  Peripheral chip selects (directly active during the byte beat)
    // =====================================================================
    output logic         pic_cs,
    output logic         pit_cs,
    output logic         ps2_cs,
    output logic         vga_cs,
    output logic         rtc_cs,
    output logic         dma_cs,

    // =====================================================================
    //  Peripheral read-data inputs (active during the same cycle as cs)
    // =====================================================================
    input  logic [7:0]   pic_rdata,
    input  logic [7:0]   pit_rdata,
    input  logic [7:0]   ps2_rdata,
    input  logic [7:0]   vga_rdata,
    input  logic [7:0]   rtc_rdata,
    input  logic [7:0]   dma_rdata,

    // =====================================================================
    //  Common peripheral bus (active during each byte beat)
    // =====================================================================
    output logic [15:0]  periph_io_addr,
    output logic [7:0]   periph_io_wdata,
    output logic         periph_io_wr,
    output logic         periph_io_rd
);

    // =========================================================================
    //  Byte-beat sequencer
    // =========================================================================
    // Multi-byte I/O (word, dword) is broken into sequential byte accesses at
    // incrementing addresses.  Most x86 I/O is byte-sized, so the common case
    // completes in a single cycle.

    typedef enum logic [1:0] {
        S_IDLE  = 2'd0,
        S_BEAT  = 2'd1,
        S_DONE  = 2'd2
    } state_t;

    state_t          state, state_nxt;
    logic [1:0]      beat_idx;           // Current byte index (0-3)
    logic [1:0]      beat_max;           // Last byte index for this transfer
    logic [15:0]     beat_addr;          // Address of current byte beat
    logic            beat_is_wr;         // Direction latch
    logic [31:0]     rd_accum;           // Accumulated read data
    logic [31:0]     wr_latch;           // Latched write data

    // Number of bytes implied by cpu_io_size
    always_comb begin
        case (cpu_io_size)
            2'd0:    beat_max = 2'd0;    // byte
            2'd1:    beat_max = 2'd1;    // word
            default: beat_max = 2'd3;    // dword
        endcase
    end

    // -------------------------------------------------------------------------
    //  FSM
    // -------------------------------------------------------------------------
    always_comb begin
        state_nxt = state;
        case (state)
            S_IDLE: if (cpu_io_wr | cpu_io_rd) state_nxt = S_BEAT;
            S_BEAT: if (beat_idx == beat_max)   state_nxt = S_DONE;
                    else                        state_nxt = S_BEAT;
            S_DONE:                             state_nxt = S_IDLE;
            default:                            state_nxt = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            beat_idx   <= 2'd0;
            beat_addr  <= 16'd0;
            beat_is_wr <= 1'b0;
            wr_latch   <= 32'd0;
            rd_accum   <= 32'd0;
        end else begin
            state <= state_nxt;

            case (state)
                S_IDLE: begin
                    if (cpu_io_wr | cpu_io_rd) begin
                        beat_idx   <= 2'd0;
                        beat_addr  <= cpu_io_addr;
                        beat_is_wr <= cpu_io_wr;
                        wr_latch   <= cpu_io_wdata;
                        rd_accum   <= 32'd0;
                    end
                end

                S_BEAT: begin
                    // Capture read data into the correct byte lane
                    if (~beat_is_wr) begin
                        case (beat_idx)
                            2'd0: rd_accum[ 7: 0] <= periph_rdata_mux;
                            2'd1: rd_accum[15: 8] <= periph_rdata_mux;
                            2'd2: rd_accum[23:16] <= periph_rdata_mux;
                            2'd3: rd_accum[31:24] <= periph_rdata_mux;
                        endcase
                    end
                    beat_idx  <= beat_idx + 2'd1;
                    beat_addr <= beat_addr + 16'd1;
                end

                S_DONE: begin
                    // Nothing -- outputs are registered below
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    //  CPU acknowledge and read data
    // -------------------------------------------------------------------------
    assign cpu_io_ack  = (state == S_DONE);
    assign cpu_io_rdata = rd_accum;

    // -------------------------------------------------------------------------
    //  Peripheral bus outputs (active during S_BEAT only)
    // -------------------------------------------------------------------------
    wire beat_active = (state == S_BEAT);

    assign periph_io_addr  = beat_addr;
    assign periph_io_wr    = beat_active &  beat_is_wr;
    assign periph_io_rd    = beat_active & ~beat_is_wr;

    // Select the correct write-data byte from the latched dword
    always_comb begin
        case (beat_idx)
            2'd0:    periph_io_wdata = wr_latch[ 7: 0];
            2'd1:    periph_io_wdata = wr_latch[15: 8];
            2'd2:    periph_io_wdata = wr_latch[23:16];
            2'd3:    periph_io_wdata = wr_latch[31:24];
        endcase
    end

    // =========================================================================
    //  Address decode -- active combinationally during each byte beat
    // =========================================================================
    always_comb begin
        pic_cs = 1'b0;
        pit_cs = 1'b0;
        ps2_cs = 1'b0;
        vga_cs = 1'b0;
        rtc_cs = 1'b0;
        dma_cs = 1'b0;

        if (beat_active) begin
            casez (beat_addr)
                // PIC master 0x0020-0x0021, PIC slave 0x00A0-0x00A1
                16'h0020, 16'h0021,
                16'h00A0, 16'h00A1:       pic_cs = 1'b1;

                // PIT 0x0040-0x0043
                16'h004?: begin
                    if (beat_addr[3:0] <= 4'h3)
                                          pit_cs = 1'b1;
                end

                // PS/2 controller 0x0060-0x0064
                16'h006?: begin
                    if (beat_addr[3:0] <= 4'h4)
                                          ps2_cs = 1'b1;
                end

                // RTC / CMOS 0x0070-0x0071
                16'h0070, 16'h0071:       rtc_cs = 1'b1;

                // DMA controller 0x0000-0x001F (channels 0-3)
                // DMA page regs  0x0080-0x008F
                // DMA controller 0x00C0-0x00DF (channels 4-7)
                16'h00??: begin
                    if ((beat_addr[7:5] == 3'b000 && beat_addr[15:8] == 8'h00) ||   // 0x0000-0x001F
                        (beat_addr[7:4] == 4'h8   && beat_addr[15:8] == 8'h00) ||   // 0x0080-0x008F
                        (beat_addr[7:5] == 3'b110 && beat_addr[15:8] == 8'h00) ||   // 0x00C0-0x00DF
                        (beat_addr[7:5] == 3'b111 && beat_addr[15:8] == 8'h00))     // 0x00E0-0x00FF (extra DMA)
                                          dma_cs = 1'b1;
                end

                // VGA I/O 0x03B0-0x03DF
                16'h03B?, 16'h03C?, 16'h03D?:
                                          vga_cs = 1'b1;

                default: ;                // Unmapped -- open-bus
            endcase
        end
    end

    // =========================================================================
    //  Read data mux (active combinationally; selected by chip-select)
    // =========================================================================
    logic [7:0] periph_rdata_mux;

    always_comb begin
        // Default: open-bus reads 0xFF (IBM PC behaviour)
        periph_rdata_mux = 8'hFF;

        // Priority is irrelevant in practice because only one cs is ever
        // asserted, but an if-else chain avoids synthesis complaints about
        // multiply-driven nets.
        if      (pic_cs) periph_rdata_mux = pic_rdata;
        else if (pit_cs) periph_rdata_mux = pit_rdata;
        else if (ps2_cs) periph_rdata_mux = ps2_rdata;
        else if (vga_cs) periph_rdata_mux = vga_rdata;
        else if (rtc_cs) periph_rdata_mux = rtc_rdata;
        else if (dma_cs) periph_rdata_mux = dma_rdata;
    end

endmodule
