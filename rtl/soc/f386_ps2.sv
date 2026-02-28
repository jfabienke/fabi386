/*
 * fabi386: 8042 PS/2 Keyboard/Mouse Controller
 * -----------------------------------------------
 * Implements the IBM PC/AT-compatible 8042 keyboard controller with dual-port
 * (keyboard + mouse) support, targeting the MiSTer FPGA platform.
 *
 * I/O ports:
 *   0x60  Data register     (read: output buffer, write: input buffer / command data)
 *   0x64  Status register   (read) / Command register (write)
 *
 * Key features:
 *   - Full 8042 command set (subset needed for DOS/Windows 3.x/9x boot)
 *   - Keyboard and mouse scancode injection from MiSTer HPS via ready/valid FIFOs
 *   - IRQ1 (keyboard) and IRQ12 (mouse) generation with per-channel enable
 *   - A20 gate output (directly wired to CPU A20 gate via output port bit 1)
 *   - System reset output (pulse on command 0xFE)
 *   - Scan-code translation flag stored in command byte[6]
 *   - Command byte fully read/writable via 0x20/0x60
 *
 * Status register (port 0x64 read):
 *   [7] Parity error (always 0 -- HPS injection has no parity)
 *   [6] Receive timeout (always 0)
 *   [5] Mouse output buffer full
 *   [4] Keyboard unlocked (always 1)
 *   [3] Command/data flag (1 = last write was to port 0x64)
 *   [2] System flag (set by self-test or command byte bit 2)
 *   [1] Input buffer full
 *   [0] Output buffer full
 *
 * External interface uses byte-level ready/valid handshake for data injection
 * from the MiSTer HPS, rather than raw PS/2 serial clock/data lines.  This
 * simplifies integration: the HPS framework handles PS/2 serial protocol and
 * scancode translation, presenting fully-formed bytes to this controller.
 *
 * Behavioural reference: ao486_MiSTer ps2.v (Aleksander Osman, 2014)
 */

import f386_pkg::*;

// =============================================================================
//  f386_ps2_fifo -- Parameterised synchronous FIFO for keyboard/mouse buffers
// =============================================================================
//  Simple circular-buffer FIFO with power-of-2 depth.  Single-clock domain,
//  single read / single write per cycle.  Provides empty/full/count outputs.
//  Uses an extra pointer bit for full/empty disambiguation.
// =============================================================================

module f386_ps2_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic              clk,
    input  logic              rst_n,

    // Write port
    input  logic [WIDTH-1:0]  wr_data,
    input  logic              wr_en,

    // Read port
    output logic [WIDTH-1:0]  rd_data,
    input  logic              rd_en,

    // Flush (synchronous reset of pointers)
    input  logic              flush,

    // Status
    output logic              empty,
    output logic              full,
    output logic [$clog2(DEPTH):0] count
);

    localparam int ADDR_W = $clog2(DEPTH);

    // Storage array
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    // Pointers (extra MSB for wrap-around disambiguation)
    logic [ADDR_W:0] wr_ptr;
    logic [ADDR_W:0] rd_ptr;

    // Status derivation
    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[ADDR_W] != rd_ptr[ADDR_W]) &&
                   (wr_ptr[ADDR_W-1:0] == rd_ptr[ADDR_W-1:0]);
    assign count = wr_ptr - rd_ptr;

    // Read data: always present the head of the FIFO
    assign rd_data = mem[rd_ptr[ADDR_W-1:0]];

    // Write logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
        end else if (flush) begin
            wr_ptr <= '0;
        end else if (wr_en && !full) begin
            mem[wr_ptr[ADDR_W-1:0]] <= wr_data;
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // Read logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= '0;
        end else if (flush) begin
            rd_ptr <= '0;
        end else if (rd_en && !empty) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

endmodule


// =============================================================================
//  f386_ps2 -- 8042 PS/2 Keyboard/Mouse Controller (HPS byte-level interface)
// =============================================================================

module f386_ps2 (
    input  logic        clk,
    input  logic        rst_n,

    // =========================================================================
    // I/O bus (directly active-high qualified by io_cs)
    // =========================================================================
    input  logic [15:0] io_addr,
    input  logic [7:0]  io_wdata,
    output logic [7:0]  io_rdata,
    input  logic        io_wr,
    input  logic        io_rd,
    input  logic        io_cs,

    // =========================================================================
    // IRQs
    // =========================================================================
    output logic        irq1,      // Keyboard IRQ (active-high)
    output logic        irq12,     // Mouse IRQ (active-high)

    // =========================================================================
    // A20 gate (directly drives CPU A20 gate)
    // =========================================================================
    output logic        a20_gate,

    // =========================================================================
    // System reset (active-high pulse)
    // =========================================================================
    output logic        sys_reset,

    // =========================================================================
    // HPS keyboard data (from MiSTer framework)
    // Ready/valid handshake: HPS presents byte on kbd_data when kbd_valid is
    // asserted; controller accepts it by asserting kbd_ready for one cycle.
    // =========================================================================
    input  logic [7:0]  kbd_data,
    input  logic        kbd_valid,
    output logic        kbd_ready,

    // =========================================================================
    // HPS mouse data (same ready/valid protocol)
    // =========================================================================
    input  logic [7:0]  mouse_data,
    input  logic        mouse_valid,
    output logic        mouse_ready
);

    // =========================================================================
    //  Local address decode
    // =========================================================================
    // Only bits [2:0] matter once io_cs is asserted.
    // Port 0x60 -> addr[2:0] = 3'b000  (data port)
    // Port 0x64 -> addr[2:0] = 3'b100  (status/command port)

    wire [2:0] port_sel = io_addr[2:0];

    wire io_read  = io_rd & io_cs;
    wire io_write = io_wr & io_cs;

    wire addr_is_data = (port_sel == 3'd0);   // Port 0x60
    wire addr_is_cmd  = (port_sel == 3'd4);   // Port 0x64

    // =========================================================================
    //  Read edge detection (single-cycle read pulse)
    // =========================================================================
    // Prevents repeated reads on multi-cycle bus holds from consuming
    // multiple bytes out of the output buffer.

    logic io_read_last;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          io_read_last <= 1'b0;
        else if (io_read_last) io_read_last <= 1'b0;
        else                   io_read_last <= io_read;
    end
    wire io_read_valid = io_read & ~io_read_last;

    // =========================================================================
    //  Keyboard FIFO (16 entries x 8 bits)
    // =========================================================================

    logic [7:0]  kbd_fifo_rdata;
    logic        kbd_fifo_empty;
    logic        kbd_fifo_full;
    logic [4:0]  kbd_fifo_count;

    logic        kbd_fifo_wr_en;
    logic [7:0]  kbd_fifo_wr_data;
    logic        kbd_fifo_rd_en;
    logic        kbd_fifo_flush;

    f386_ps2_fifo #(
        .WIDTH (8),
        .DEPTH (16)
    ) u_kbd_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_data (kbd_fifo_wr_data),
        .wr_en   (kbd_fifo_wr_en),
        .rd_data (kbd_fifo_rdata),
        .rd_en   (kbd_fifo_rd_en),
        .flush   (kbd_fifo_flush),
        .empty   (kbd_fifo_empty),
        .full    (kbd_fifo_full),
        .count   (kbd_fifo_count)
    );

    // Hold last valid read data when FIFO empties (avoids returning garbage)
    logic [7:0] kbd_fifo_rdata_last;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            kbd_fifo_rdata_last <= 8'h00;
        else if (!kbd_fifo_empty)
            kbd_fifo_rdata_last <= kbd_fifo_rdata;
    end
    wire [7:0] kbd_fifo_rdata_final = kbd_fifo_empty ? kbd_fifo_rdata_last
                                                     : kbd_fifo_rdata;

    // =========================================================================
    //  Mouse FIFO (16 entries x 8 bits)
    // =========================================================================

    logic [7:0]  mouse_fifo_rdata;
    logic        mouse_fifo_empty;
    logic        mouse_fifo_full;
    logic [4:0]  mouse_fifo_count;

    logic        mouse_fifo_wr_en;
    logic [7:0]  mouse_fifo_wr_data;
    logic        mouse_fifo_rd_en;
    logic        mouse_fifo_flush;

    f386_ps2_fifo #(
        .WIDTH (8),
        .DEPTH (16)
    ) u_mouse_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_data (mouse_fifo_wr_data),
        .wr_en   (mouse_fifo_wr_en),
        .rd_data (mouse_fifo_rdata),
        .rd_en   (mouse_fifo_rd_en),
        .flush   (mouse_fifo_flush),
        .empty   (mouse_fifo_empty),
        .full    (mouse_fifo_full),
        .count   (mouse_fifo_count)
    );

    // =========================================================================
    //  Status register bits
    // =========================================================================
    //   [7] PERR    - Parity error (always 0 for HPS interface)
    //   [6] TIMEOUT - General timeout (always 0 for HPS interface)
    //   [5] MOBF    - Mouse output buffer full
    //   [4] INH     - Keyboard inhibit (always 1 = not inhibited)
    //   [3] A2      - Last write was command (1) or data (0)
    //   [2] SYS     - System flag (set after self-test passes)
    //   [1] IBF     - Input buffer full (host -> device pending)
    //   [0] OBF     - Output buffer full (device -> host ready)

    logic       status_mobf;
    logic       status_a2;
    logic       status_sys;
    logic       status_ibf;
    logic       status_obf;

    wire [7:0] status_reg = {
        1'b0,                           // [7] PERR  (always 0)
        1'b0,                           // [6] TIMEOUT (always 0)
        status_mobf,                    // [5] Mouse OBF
        1'b1,                           // [4] INH   (keyboard unlocked)
        status_a2,                      // [3] Command/data flag
        status_sys,                     // [2] System flag
        status_ibf,                     // [1] Input buffer full
        status_obf                      // [0] Output buffer full
    };

    // =========================================================================
    //  Configuration byte (command 0x20 read / 0x60 write)
    // =========================================================================
    //   [7]   Reserved (0)
    //   [6]   Translate: scancode set 2 -> set 1
    //   [5]   Disable mouse clock (disable channel 2)
    //   [4]   Disable keyboard clock (disable channel 1)
    //   [3]   Reserved (0)
    //   [2]   System flag
    //   [1]   Enable mouse IRQ (IRQ12)
    //   [0]   Enable keyboard IRQ (IRQ1)

    logic       cfg_translate;
    logic       cfg_disable_mouse;
    logic       cfg_disable_mouse_vis;
    logic       cfg_disable_kbd;
    logic       cfg_irq_mouse_en;
    logic       cfg_irq_kbd_en;

    wire [7:0] command_byte = {
        1'b0,
        cfg_translate,
        cfg_disable_mouse_vis,
        cfg_disable_kbd,
        1'b0,
        status_sys,
        cfg_irq_mouse_en,
        cfg_irq_kbd_en
    };

    // =========================================================================
    //  Controller command decoder
    // =========================================================================
    // The 8042 command protocol: CPU writes to port 0x64 to issue a command.
    // Some commands require a parameter byte written to port 0x60 afterwards.

    logic       expecting_port60;
    logic [7:0] last_command;

    // Commands that require a subsequent data byte on port 0x60
    wire cmd_needs_param = io_write & addr_is_cmd & (
        io_wdata == 8'h60 |            // Write command byte
        io_wdata == 8'hCB |            // Write controller mode
        io_wdata == 8'hD1 |            // Write output port
        io_wdata == 8'hD2 |            // Write keyboard output buffer
        io_wdata == 8'hD3 |            // Write mouse output buffer
        io_wdata == 8'hD4              // Write to mouse device
    );

    // Parameterized command: data byte arrived on port 0x60 while expecting
    wire cmd_with_param    = io_write & addr_is_data & expecting_port60 & ~status_ibf;
    // Standalone command: no parameter needed
    wire cmd_without_param = io_write & addr_is_cmd  & ~cmd_needs_param;

    // --- Commands with parameters ---
    wire cmd_write_config       = cmd_with_param & (last_command == 8'h60);
    wire cmd_write_output_port  = cmd_with_param & (last_command == 8'hD1);
    wire cmd_write_kbd_obuf     = cmd_with_param & (last_command == 8'hD2);
    wire cmd_write_mouse_obuf   = cmd_with_param & (last_command == 8'hD3);
    wire cmd_write_to_mouse     = cmd_with_param & (last_command == 8'hD4);

    // --- Standalone commands ---
    wire cmd_read_config        = cmd_without_param & (io_wdata == 8'h20);
    wire cmd_disable_mouse      = cmd_without_param & (io_wdata == 8'hA7);
    wire cmd_enable_mouse       = cmd_without_param & (io_wdata == 8'hA8);
    wire cmd_test_mouse_port    = cmd_without_param & (io_wdata == 8'hA9);
    wire cmd_self_test          = cmd_without_param & (io_wdata == 8'hAA);
    wire cmd_test_kbd_port      = cmd_without_param & (io_wdata == 8'hAB);
    wire cmd_disable_kbd        = cmd_without_param & (io_wdata == 8'hAD);
    wire cmd_enable_kbd         = cmd_without_param & (io_wdata == 8'hAE);
    wire cmd_read_input_port    = cmd_without_param & (io_wdata == 8'hC0);
    wire cmd_read_ctrl_mode     = cmd_without_param & (io_wdata == 8'hCA);
    wire cmd_read_output_port   = cmd_without_param & (io_wdata == 8'hD0);
    wire cmd_disable_a20        = cmd_without_param & (io_wdata == 8'hDD);
    wire cmd_enable_a20         = cmd_without_param & (io_wdata == 8'hDF);
    wire cmd_reset_cpu          = cmd_without_param & (io_wdata == 8'hFE);

    // Direct write to keyboard device: port 0x60 write when no command is
    // pending and the input buffer is not full.
    wire write_to_kbd   = io_write & addr_is_data & ~expecting_port60 & ~status_ibf;
    wire write_to_mouse = cmd_write_to_mouse;

    // =========================================================================
    //  Command/parameter state tracking
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            expecting_port60 <= 1'b0;
            last_command     <= 8'h00;
        end else begin
            if (io_write & addr_is_data)
                expecting_port60 <= 1'b0;
            else if (cmd_needs_param)
                expecting_port60 <= 1'b1;
            else if (io_write & addr_is_cmd)
                expecting_port60 <= 1'b0;

            if (io_write & addr_is_cmd)
                last_command <= io_wdata;
        end
    end

    // =========================================================================
    //  Status: A2 (last write type -- command vs data)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            status_a2 <= 1'b1;
        else if (io_write & addr_is_data)
            status_a2 <= 1'b0;
        else if (io_write & addr_is_cmd)
            status_a2 <= 1'b1;
    end

    // =========================================================================
    //  Configuration register updates
    // =========================================================================

    // Translate enable (default on for DOS compatibility)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  cfg_translate <= 1'b1;
        else if (cmd_write_config)   cfg_translate <= io_wdata[6];
    end

    // Mouse channel disable
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  cfg_disable_mouse <= 1'b0;
        else if (cmd_write_config)   cfg_disable_mouse <= io_wdata[5];
        else if (cmd_disable_mouse)  cfg_disable_mouse <= 1'b1;
        else if (cmd_enable_mouse)   cfg_disable_mouse <= 1'b0;
        else if (write_to_mouse)     cfg_disable_mouse <= 1'b0;  // auto-enable on D4
    end

    // Visible mouse disable (for command byte readback only)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                      cfg_disable_mouse_vis <= 1'b0;
        else if (cmd_write_config)       cfg_disable_mouse_vis <= io_wdata[5];
        else if (cmd_disable_mouse)      cfg_disable_mouse_vis <= 1'b1;
        else if (cmd_enable_mouse)       cfg_disable_mouse_vis <= 1'b0;
    end

    // Keyboard channel disable
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  cfg_disable_kbd <= 1'b0;
        else if (cmd_write_config)   cfg_disable_kbd <= io_wdata[4];
        else if (cmd_disable_kbd)    cfg_disable_kbd <= 1'b1;
        else if (cmd_enable_kbd)     cfg_disable_kbd <= 1'b0;
        else if (write_to_kbd)       cfg_disable_kbd <= 1'b0;  // auto-enable
    end

    // System flag
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  status_sys <= 1'b0;
        else if (cmd_write_config)   status_sys <= io_wdata[2];
        else if (cmd_self_test)      status_sys <= 1'b1;
    end

    // IRQ enables
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  cfg_irq_mouse_en <= 1'b1;
        else if (cmd_write_config)   cfg_irq_mouse_en <= io_wdata[1];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  cfg_irq_kbd_en <= 1'b1;
        else if (cmd_write_config)   cfg_irq_kbd_en <= io_wdata[0];
    end

    // =========================================================================
    //  A20 gate control
    // =========================================================================
    // Driven by output port bit 1 (command 0xD1) or explicit A20 commands.

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            a20_gate <= 1'b1;                   // Default: A20 enabled
        else if (cmd_write_output_port)
            a20_gate <= io_wdata[1];
        else if (cmd_disable_a20)
            a20_gate <= 1'b0;
        else if (cmd_enable_a20)
            a20_gate <= 1'b1;
    end

    // =========================================================================
    //  System reset control
    // =========================================================================
    // A write of 0xFE to port 0x64 pulses the system reset line.
    // Output port bit 0 (via 0xD1) can also trigger a reset when cleared.

    localparam int RST_PULSE_LEN = 8;
    logic [3:0] rst_pulse_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sys_reset     <= 1'b0;
            rst_pulse_cnt <= 4'd0;
        end else if (cmd_reset_cpu) begin
            sys_reset     <= 1'b1;
            rst_pulse_cnt <= RST_PULSE_LEN[3:0];
        end else if (cmd_write_output_port & ~io_wdata[0]) begin
            sys_reset     <= 1'b1;
            rst_pulse_cnt <= RST_PULSE_LEN[3:0];
        end else if (rst_pulse_cnt != 4'd0) begin
            rst_pulse_cnt <= rst_pulse_cnt - 4'd1;
            if (rst_pulse_cnt == 4'd1)
                sys_reset <= 1'b0;
        end
    end

    // =========================================================================
    //  Controller reply generation (commands that return data to output buffer)
    // =========================================================================
    // These are controller-level replies (not device replies).  They are placed
    // into the keyboard FIFO (or mouse FIFO for D3).

    logic [7:0] ctrl_reply;
    logic       ctrl_reply_valid;

    // Output port value for D0 readback
    wire [7:0] output_port_val = {
        1'b0,                           // [7] Keyboard data (unused)
        1'b0,                           // [6] Keyboard clock (unused)
        irq12,                          // [5] Mouse IRQ status
        irq1,                           // [4] Keyboard IRQ status
        1'b0,                           // [3] Reserved
        1'b0,                           // [2] Reserved
        a20_gate,                       // [1] A20 gate
        ~sys_reset                      // [0] System reset (active low)
    };

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ctrl_reply <= 8'h00;
        else if (cmd_write_kbd_obuf)     ctrl_reply <= io_wdata;
        else if (cmd_read_config)        ctrl_reply <= command_byte;
        else if (cmd_test_mouse_port)    ctrl_reply <= 8'h00;   // test passed
        else if (cmd_self_test)          ctrl_reply <= 8'h55;   // self-test passed
        else if (cmd_test_kbd_port)      ctrl_reply <= 8'h00;   // test passed
        else if (cmd_read_input_port)    ctrl_reply <= 8'h80;   // input port (bit7=1)
        else if (cmd_read_ctrl_mode)     ctrl_reply <= 8'h01;   // controller mode
        else if (cmd_read_output_port)   ctrl_reply <= output_port_val;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ctrl_reply_valid <= 1'b0;
        else if (cmd_write_kbd_obuf | cmd_read_config | cmd_test_mouse_port |
                 cmd_self_test | cmd_test_kbd_port | cmd_read_input_port |
                 cmd_read_ctrl_mode | cmd_read_output_port)
            ctrl_reply_valid <= 1'b1;
        else if (ctrl_reply_push)
            ctrl_reply_valid <= 1'b0;
    end

    // Mouse controller reply (command 0xD3 -- write to mouse output buffer)
    logic [7:0] mouse_ctrl_reply;
    logic       mouse_ctrl_reply_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                      mouse_ctrl_reply <= 8'h00;
        else if (cmd_write_mouse_obuf)   mouse_ctrl_reply <= io_wdata;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mouse_ctrl_reply_valid <= 1'b0;
        else if (cmd_write_mouse_obuf)
            mouse_ctrl_reply_valid <= 1'b1;
        else if (mouse_ctrl_reply_push)
            mouse_ctrl_reply_valid <= 1'b0;
    end

    // =========================================================================
    //  Input buffer (host -> device write path)
    // =========================================================================
    // When the CPU writes data to the keyboard (port 0x60, no command pending)
    // or to the mouse (via D4 command), we set IBF and track the destination.
    // In the HPS model there is no serial bus turnaround, so IBF clears quickly.

    logic       input_for_mouse;
    logic       input_write_done;

    // IBF flag
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            status_ibf <= 1'b0;
        else if (write_to_kbd | write_to_mouse)
            status_ibf <= 1'b1;
        else if (input_write_done & status_obf)
            status_ibf <= 1'b0;
    end

    // In the HPS model, host-to-device writes complete immediately (no serial
    // protocol delay).  We assert input_write_done one cycle after the write.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            input_write_done <= 1'b0;
        else if (write_to_kbd | write_to_mouse)
            input_write_done <= 1'b0;
        else if (status_ibf & ~input_write_done)
            input_write_done <= 1'b1;
    end

    // Track destination (keyboard vs mouse)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            input_for_mouse <= 1'b0;
        else if (write_to_kbd)
            input_for_mouse <= 1'b0;
        else if (write_to_mouse)
            input_for_mouse <= 1'b1;
    end

    // =========================================================================
    //  Keyboard device command handling
    // =========================================================================
    // When the CPU writes to the keyboard (port 0x60 with no pending command),
    // we handle the most common keyboard device commands internally and produce
    // the expected ACK/reply bytes.  In the MiSTer HPS model the real PS/2
    // protocol is handled upstream; we just need to produce correct responses.
    //
    // Supported keyboard device commands:
    //   0xED  Set LEDs (accept parameter, reply ACK)
    //   0xEE  Echo (reply 0xEE)
    //   0xF0  Set scan code set (accept parameter, reply ACK)
    //   0xF2  Identify keyboard (reply ACK + 0xAB, 0x83)
    //   0xF3  Set typematic rate (accept parameter, reply ACK)
    //   0xF4  Enable scanning (reply ACK)
    //   0xF5  Disable scanning / set defaults (reply ACK)
    //   0xF6  Set defaults (reply ACK)
    //   0xFF  Reset (reply ACK + 0xAA)
    //
    // Parameter values are ignored (LEDs, typematic, etc. are handled by HPS).

    typedef enum logic [2:0] {
        KDEV_IDLE       = 3'd0,
        KDEV_ACK        = 3'd1,
        KDEV_PARAM_WAIT = 3'd2,
        KDEV_PARAM_ACK  = 3'd3,
        KDEV_ID_1       = 3'd4,
        KDEV_ID_2       = 3'd5,
        KDEV_RESET_BAT  = 3'd6
    } kbd_dev_state_t;

    kbd_dev_state_t kbd_dev_state;
    logic [7:0]     kbd_dev_cmd_latch;      // Latched keyboard command

    // Device reply staging register
    logic           kbd_dev_reply_valid;
    logic [7:0]     kbd_dev_reply_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kbd_dev_state       <= KDEV_IDLE;
            kbd_dev_cmd_latch   <= 8'h00;
            kbd_dev_reply_valid <= 1'b0;
            kbd_dev_reply_data  <= 8'h00;
        end else begin
            kbd_dev_reply_valid <= 1'b0;

            case (kbd_dev_state)
                KDEV_IDLE: begin
                    if (write_to_kbd) begin
                        kbd_dev_cmd_latch <= io_wdata;
                        case (io_wdata)
                            8'hED, 8'hF0, 8'hF3: begin
                                // Commands expecting a parameter byte
                                kbd_dev_state <= KDEV_ACK;
                            end
                            8'hEE: begin
                                // Echo
                                kbd_dev_reply_valid <= 1'b1;
                                kbd_dev_reply_data  <= 8'hEE;
                            end
                            8'hF2: begin
                                // Identify -- ACK then AB 83
                                kbd_dev_state <= KDEV_ACK;
                            end
                            8'hFF: begin
                                // Reset -- ACK then BAT result (0xAA)
                                kbd_dev_state <= KDEV_ACK;
                            end
                            default: begin
                                // All other: reply ACK
                                kbd_dev_reply_valid <= 1'b1;
                                kbd_dev_reply_data  <= 8'hFA;
                            end
                        endcase
                    end
                end

                KDEV_ACK: begin
                    kbd_dev_reply_valid <= 1'b1;
                    kbd_dev_reply_data  <= 8'hFA;
                    case (kbd_dev_cmd_latch)
                        8'hED, 8'hF0, 8'hF3: kbd_dev_state <= KDEV_PARAM_WAIT;
                        8'hF2:               kbd_dev_state <= KDEV_ID_1;
                        8'hFF:               kbd_dev_state <= KDEV_RESET_BAT;
                        default:             kbd_dev_state <= KDEV_IDLE;
                    endcase
                end

                KDEV_PARAM_WAIT: begin
                    if (write_to_kbd) begin
                        kbd_dev_state <= KDEV_PARAM_ACK;
                    end
                end

                KDEV_PARAM_ACK: begin
                    kbd_dev_reply_valid <= 1'b1;
                    kbd_dev_reply_data  <= 8'hFA;
                    kbd_dev_state       <= KDEV_IDLE;
                end

                KDEV_ID_1: begin
                    kbd_dev_reply_valid <= 1'b1;
                    kbd_dev_reply_data  <= 8'hAB;
                    kbd_dev_state       <= KDEV_ID_2;
                end

                KDEV_ID_2: begin
                    kbd_dev_reply_valid <= 1'b1;
                    kbd_dev_reply_data  <= 8'h83;
                    kbd_dev_state       <= KDEV_IDLE;
                end

                KDEV_RESET_BAT: begin
                    kbd_dev_reply_valid <= 1'b1;
                    kbd_dev_reply_data  <= 8'hAA;   // BAT passed
                    kbd_dev_state       <= KDEV_IDLE;
                end

                default: kbd_dev_state <= KDEV_IDLE;
            endcase
        end
    end

    // =========================================================================
    //  Mouse device command handling
    // =========================================================================
    // When the CPU sends a byte to the mouse via D4, we produce the expected
    // ACK from the mouse.  For device ID query (0xF2) we return 0x00 (standard
    // PS/2 mouse).  For reset (0xFF) we return ACK + BAT passed (0xAA) + ID.

    typedef enum logic [2:0] {
        MDEV_IDLE      = 3'd0,
        MDEV_ACK       = 3'd1,
        MDEV_ID        = 3'd2,
        MDEV_RST_BAT   = 3'd3,
        MDEV_RST_ID    = 3'd4
    } mouse_dev_state_t;

    mouse_dev_state_t mouse_dev_state;
    logic [7:0]       mouse_dev_cmd_latch;

    logic             mouse_dev_reply_valid;
    logic [7:0]       mouse_dev_reply_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mouse_dev_state       <= MDEV_IDLE;
            mouse_dev_cmd_latch   <= 8'h00;
            mouse_dev_reply_valid <= 1'b0;
            mouse_dev_reply_data  <= 8'h00;
        end else begin
            mouse_dev_reply_valid <= 1'b0;

            case (mouse_dev_state)
                MDEV_IDLE: begin
                    if (write_to_mouse) begin
                        mouse_dev_cmd_latch <= io_wdata;
                        mouse_dev_state     <= MDEV_ACK;
                    end
                end

                MDEV_ACK: begin
                    mouse_dev_reply_valid <= 1'b1;
                    mouse_dev_reply_data  <= 8'hFA;    // ACK
                    case (mouse_dev_cmd_latch)
                        8'hF2:   mouse_dev_state <= MDEV_ID;       // Identify
                        8'hFF:   mouse_dev_state <= MDEV_RST_BAT;  // Reset
                        default: mouse_dev_state <= MDEV_IDLE;
                    endcase
                end

                MDEV_ID: begin
                    mouse_dev_reply_valid <= 1'b1;
                    mouse_dev_reply_data  <= 8'h00;    // Standard PS/2 mouse ID
                    mouse_dev_state       <= MDEV_IDLE;
                end

                MDEV_RST_BAT: begin
                    mouse_dev_reply_valid <= 1'b1;
                    mouse_dev_reply_data  <= 8'hAA;    // BAT passed
                    mouse_dev_state       <= MDEV_RST_ID;
                end

                MDEV_RST_ID: begin
                    mouse_dev_reply_valid <= 1'b1;
                    mouse_dev_reply_data  <= 8'h00;    // Device ID
                    mouse_dev_state       <= MDEV_IDLE;
                end

                default: mouse_dev_state <= MDEV_IDLE;
            endcase
        end
    end

    // =========================================================================
    //  HPS keyboard data ingestion
    // =========================================================================
    // The MiSTer HPS presents key scancodes via a ready/valid handshake.
    // We accept them into the keyboard FIFO when space is available and the
    // keyboard channel is not disabled.

    assign kbd_ready = ~kbd_fifo_full & ~cfg_disable_kbd;

    // =========================================================================
    //  HPS mouse data ingestion
    // =========================================================================

    assign mouse_ready = ~mouse_fifo_full & ~cfg_disable_mouse;

    // =========================================================================
    //  Keyboard FIFO write arbitration
    // =========================================================================
    // Three sources can push into the keyboard FIFO (priority order):
    //   1. Controller replies (self-test, read command byte, etc.)
    //   2. Keyboard device replies (ACK, identify, BAT)
    //   3. HPS scancode injection
    //
    // The push signal is combinational -- only one source wins per cycle.

    wire ctrl_reply_push = ctrl_reply_valid & ~kbd_fifo_full;

    always_comb begin
        kbd_fifo_wr_en   = 1'b0;
        kbd_fifo_wr_data = 8'h00;

        if (ctrl_reply_valid & ~kbd_fifo_full) begin
            kbd_fifo_wr_en   = 1'b1;
            kbd_fifo_wr_data = ctrl_reply;
        end else if (kbd_dev_reply_valid & ~kbd_fifo_full) begin
            kbd_fifo_wr_en   = 1'b1;
            kbd_fifo_wr_data = kbd_dev_reply_data;
        end else if (kbd_valid & kbd_ready) begin
            kbd_fifo_wr_en   = 1'b1;
            kbd_fifo_wr_data = kbd_data;
        end
    end

    // Keyboard FIFO read: CPU reads port 0x60 with keyboard data available
    assign kbd_fifo_rd_en = io_read_valid & addr_is_data & status_obf & ~status_mobf;

    // Self-test flushes both FIFOs
    assign kbd_fifo_flush = cmd_self_test;

    // =========================================================================
    //  Mouse FIFO write arbitration
    // =========================================================================
    // Three sources can push into the mouse FIFO (priority order):
    //   1. Controller replies (D3 -- write mouse output buffer)
    //   2. Mouse device replies (ACK, device ID, BAT)
    //   3. HPS mouse data injection

    wire mouse_ctrl_reply_push = mouse_ctrl_reply_valid & ~mouse_fifo_full;

    always_comb begin
        mouse_fifo_wr_en   = 1'b0;
        mouse_fifo_wr_data = 8'h00;

        if (mouse_ctrl_reply_valid & ~mouse_fifo_full) begin
            mouse_fifo_wr_en   = 1'b1;
            mouse_fifo_wr_data = mouse_ctrl_reply;
        end else if (mouse_dev_reply_valid & ~mouse_fifo_full) begin
            mouse_fifo_wr_en   = 1'b1;
            mouse_fifo_wr_data = mouse_dev_reply_data;
        end else if (mouse_valid & mouse_ready) begin
            mouse_fifo_wr_en   = 1'b1;
            mouse_fifo_wr_data = mouse_data;
        end
    end

    // Mouse FIFO read: CPU reads port 0x60 with mouse data available
    assign mouse_fifo_rd_en = io_read_valid & addr_is_data & status_mobf;

    assign mouse_fifo_flush = cmd_self_test;

    // =========================================================================
    //  Output buffer management
    // =========================================================================
    // The 8042 has a single output buffer visible at port 0x60.  Mouse data
    // takes priority over keyboard data (matching ao486 behaviour).

    wire obuf_idle = ~status_mobf & ~status_obf;

    // Mouse OBF: set when mouse FIFO has data and output buffer is idle
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            status_mobf <= 1'b0;
        else if (io_read_valid & addr_is_data)
            status_mobf <= 1'b0;
        else if (obuf_idle & ~mouse_fifo_empty)
            status_mobf <= 1'b1;
    end

    // Combined OBF: set when either FIFO has data
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            status_obf <= 1'b0;
        else if (io_read_valid & addr_is_data)
            status_obf <= 1'b0;
        else if (obuf_idle & (~mouse_fifo_empty | ~kbd_fifo_empty))
            status_obf <= 1'b1;
    end

    // =========================================================================
    //  IRQ generation
    // =========================================================================

    // IRQ1: keyboard data available, mouse not claiming the buffer
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            irq1 <= 1'b0;
        else if (io_read_valid & addr_is_data & status_obf & ~status_mobf)
            irq1 <= 1'b0;
        else if (cfg_irq_kbd_en & status_obf & ~status_mobf)
            irq1 <= 1'b1;
    end

    // IRQ12: mouse data available
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            irq12 <= 1'b0;
        else if (io_read_valid & addr_is_data & status_mobf)
            irq12 <= 1'b0;
        else if (cfg_irq_mouse_en & status_mobf)
            irq12 <= 1'b1;
    end

    // =========================================================================
    //  I/O read data multiplexer
    // =========================================================================
    // Port 0x64: status register
    // Port 0x60: data from output buffer (mouse takes priority)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            io_rdata <= 8'h00;
        else if (io_read_valid & addr_is_cmd)
            io_rdata <= status_reg;
        else if (io_read_valid & addr_is_data) begin
            if (status_mobf)
                io_rdata <= mouse_fifo_rdata;
            else
                io_rdata <= kbd_fifo_rdata_final;
        end
    end

    // =========================================================================
    //  Scancode translation note
    // =========================================================================
    // The cfg_translate flag (command byte bit 6) is maintained for register
    // compatibility, but in the MiSTer HPS model the translation from scan
    // code set 2 to set 1 is performed by the HPS framework before data
    // reaches this controller.  The translate flag value is visible in the
    // command byte readback (0x20) and can be programmed by guest software
    // via 0x60.  No on-chip translation table is instantiated.

endmodule
