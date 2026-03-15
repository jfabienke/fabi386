/*
 * fabi386: ETX Display Engine — Command Ring FIFO + Decoder
 * -----------------------------------------------------------
 * 256 x 64-bit command FIFO (2 M10K) with decode FSM.
 * Commands: NOP, FILL_RECT, BLIT_COPY, BLIT_COLORKEY, PATTERN_FILL, LINE, MONO_EXPAND.
 * When local FIFO is empty, polls SDRAM ring buffer via ring_rd port.
 * Resource stub for Quartus estimation.
 */

import f386_pkg::*;

module f386_etx_cmd_decoder (
    input  logic         clk,
    input  logic         rst_n,

    // CPU command write port
    input  logic [63:0]  cmd_wdata,
    input  logic         cmd_wr,
    output logic         cmd_full,

    // Blit engine interface
    output logic [3:0]   blit_opcode,
    output logic [24:0]  blit_src_addr,
    output logic [24:0]  blit_dst_addr,
    output logic [15:0]  blit_width,
    output logic [15:0]  blit_height,
    output logic [15:0]  blit_src_stride,
    output logic [15:0]  blit_dst_stride,
    output logic [31:0]  blit_fill_color,
    output logic [23:0]  blit_colorkey,
    output logic         blit_start,
    input  logic         blit_done,

    // Memory hub read port (for command ring in SDRAM)
    output logic         ring_rd_req,
    output logic [24:0]  ring_rd_addr,
    input  logic [31:0]  ring_rd_data,
    input  logic         ring_rd_ack,

    // Fence / completion
    output logic [31:0]  fence_seq,
    output logic         fence_valid
);

    // =========================================================================
    //  Command opcodes
    // =========================================================================
    localparam logic [3:0] CMD_NOP           = 4'd0;
    localparam logic [3:0] CMD_FILL_RECT     = 4'd1;
    localparam logic [3:0] CMD_BLIT_COPY     = 4'd2;
    localparam logic [3:0] CMD_BLIT_COLORKEY = 4'd3;
    localparam logic [3:0] CMD_PATTERN_FILL  = 4'd4;
    localparam logic [3:0] CMD_LINE          = 4'd5;
    localparam logic [3:0] CMD_MONO_EXPAND   = 4'd6;
    localparam logic [3:0] CMD_FENCE         = 4'd7;

    // =========================================================================
    //  Command FIFO — 256 x 64-bit → 2 M10K
    // =========================================================================
    localparam int FIFO_AW = 8;  // 256 entries
    localparam int FIFO_DW = 64;

    logic [FIFO_AW-1:0] wr_ptr, rd_ptr;
    logic [FIFO_AW:0]   count;
    logic [FIFO_DW-1:0] fifo_rd_data;
    logic                fifo_rd_en;

    f386_bram_sdp #(.ADDR_W(FIFO_AW), .DATA_W(FIFO_DW)) cmd_fifo (
        .clk     (clk),
        .wr_addr (wr_ptr),
        .wr_data (cmd_wdata),
        .wr_en   (cmd_wr && !cmd_full),
        .rd_addr (rd_ptr),
        .rd_data (fifo_rd_data)
    );

    assign cmd_full = (count >= 9'd255);

    // =========================================================================
    //  FIFO pointer management
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            if (cmd_wr && !cmd_full) begin
                wr_ptr <= wr_ptr + 1'b1;
                if (!fifo_rd_en)
                    count <= count + 1'b1;
            end
            if (fifo_rd_en && count > 0) begin
                rd_ptr <= rd_ptr + 1'b1;
                if (!(cmd_wr && !cmd_full))
                    count <= count - 1'b1;
            end
        end
    end

    // =========================================================================
    //  Ring buffer state (SDRAM-based command ring)
    // =========================================================================
    logic [24:0] ring_head_addr;   // next read address in SDRAM ring
    logic [31:0] ring_low_word;    // first dword of 64-bit ring entry

    // =========================================================================
    //  Decode FSM
    // =========================================================================
    typedef enum logic [3:0] {
        DEC_IDLE,
        DEC_FETCH,
        DEC_DECODE,
        DEC_DISPATCH,
        DEC_WAIT_DONE,
        DEC_FENCE,
        DEC_RING_REQ_LO,
        DEC_RING_WAIT_LO,
        DEC_RING_REQ_HI,
        DEC_RING_WAIT_HI
    } dec_state_t;

    dec_state_t state;
    logic [63:0] cmd_r;
    logic [31:0] fence_counter;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= DEC_IDLE;
            cmd_r         <= '0;
            blit_opcode   <= '0;
            blit_src_addr <= '0;
            blit_dst_addr <= '0;
            blit_width    <= '0;
            blit_height   <= '0;
            blit_src_stride <= '0;
            blit_dst_stride <= '0;
            blit_fill_color <= '0;
            blit_colorkey <= '0;
            blit_start    <= 1'b0;
            fence_seq     <= '0;
            fence_valid   <= 1'b0;
            fence_counter <= '0;
            ring_rd_req   <= 1'b0;
            ring_rd_addr  <= '0;
            ring_head_addr <= 25'h1E00000;  // non-zero so SDRAM stub returns varied data
            ring_low_word <= '0;
            fifo_rd_en    <= 1'b0;
        end else begin
            blit_start  <= 1'b0;
            fence_valid <= 1'b0;
            fifo_rd_en  <= 1'b0;
            ring_rd_req <= 1'b0;

            case (state)
                DEC_IDLE: begin
                    if (count > 0) begin
                        // Local FIFO has commands — dequeue
                        fifo_rd_en <= 1'b1;
                        state <= DEC_FETCH;
                    end else begin
                        // FIFO empty — poll SDRAM ring buffer
                        ring_rd_req  <= 1'b1;
                        ring_rd_addr <= ring_head_addr;
                        state <= DEC_RING_WAIT_LO;
                    end
                end

                DEC_FETCH: begin
                    state <= DEC_DECODE;  // 1-cycle BRAM latency
                end

                DEC_DECODE: begin
                    cmd_r <= fifo_rd_data;
                    state <= DEC_DISPATCH;
                end

                // --- Ring buffer read path (2 × 32-bit → 64-bit command) ---
                DEC_RING_WAIT_LO: begin
                    if (ring_rd_ack) begin
                        ring_low_word <= ring_rd_data;
                        // Issue second read for high dword
                        ring_rd_req  <= 1'b1;
                        ring_rd_addr <= ring_head_addr + 25'd4;
                        state <= DEC_RING_WAIT_HI;
                    end
                end

                DEC_RING_WAIT_HI: begin
                    if (ring_rd_ack) begin
                        cmd_r <= {ring_rd_data, ring_low_word};
                        ring_head_addr <= ring_head_addr + 25'd8;
                        state <= DEC_DISPATCH;
                    end
                end

                // --- Common dispatch ---
                DEC_DISPATCH: begin
                    blit_opcode <= cmd_r[63:60];
                    case (cmd_r[63:60])
                        CMD_NOP: begin
                            state <= DEC_IDLE;
                        end
                        CMD_FILL_RECT: begin
                            blit_dst_addr   <= cmd_r[56:32];
                            blit_width      <= cmd_r[15:0];
                            blit_height     <= cmd_r[31:16];
                            blit_fill_color <= cmd_r[31:0];
                            blit_start      <= 1'b1;
                            state           <= DEC_WAIT_DONE;
                        end
                        CMD_BLIT_COPY, CMD_BLIT_COLORKEY: begin
                            blit_src_addr   <= cmd_r[56:32];
                            blit_dst_addr   <= cmd_r[24:0];
                            blit_colorkey   <= cmd_r[23:0];
                            blit_start      <= 1'b1;
                            state           <= DEC_WAIT_DONE;
                        end
                        CMD_PATTERN_FILL, CMD_LINE, CMD_MONO_EXPAND: begin
                            blit_src_addr   <= cmd_r[56:32];
                            blit_dst_addr   <= cmd_r[24:0];
                            blit_start      <= 1'b1;
                            state           <= DEC_WAIT_DONE;
                        end
                        CMD_FENCE: begin
                            fence_counter <= fence_counter + 1'b1;
                            fence_seq     <= fence_counter + 1'b1;
                            fence_valid   <= 1'b1;
                            state         <= DEC_IDLE;
                        end
                        default: begin
                            blit_start <= 1'b1;
                            state      <= DEC_WAIT_DONE;
                        end
                    endcase
                end

                DEC_WAIT_DONE: begin
                    if (blit_done)
                        state <= DEC_IDLE;
                end

                default: state <= DEC_IDLE;
            endcase
        end
    end

endmodule
