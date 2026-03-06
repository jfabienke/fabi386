/*
 * fabi386: MiSTer Top-Level EMU Module
 * ---------------------------------------
 * This is the top-level module instantiated by the MiSTer sys/emu.v
 * framework. It wires together the CPU core, peripherals, memory
 * controller, and video output for the DE10-Nano FPGA.
 *
 * Architecture:
 *   ┌────────────────────────────────────────────────┐
 *   │  f386_emu                                      │
 *   │                                                │
 *   │  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
 *   │  │ OoO Core │←→│ Mem Ctrl │←→│  DDRAM (HPS) │  │
 *   │  └────┬─────┘  └──────────┘  └──────────────┘  │
 *   │       │                                        │
 *   │  ┌────┴──────────────────────────────────┐     │
 *   │  │  I/O Bus                              │     │
 *   │  ├──────┬──────┬──────┬──────┬────┬──────┤     │
 *   │  │ PIC  │ PIT  │ PS/2 │ VGA  │RTC │ DMA  │     │
 *   │  └──────┴──────┴──────┴──────┴────┴──────┘     │
 *   │                         │                      │
 *   │               Video Out → VGA/HDMI             │
 *   └────────────────────────────────────────────────┘
 *
 * Reference: ao486_MiSTer ao486.sv
 */

import f386_pkg::*;
import f386_conf_str_pkg::*;

module f386_emu (
    // --- MiSTer Framework Signals ---
    input  logic        CLK_50M,

    // --- LED ---
    output logic        LED_USER,
    output logic        LED_HDD,
    output logic        LED_POWER,
    output logic [1:0]  BUTTONS,

    // --- VGA ---
    output logic [7:0]  VGA_R,
    output logic [7:0]  VGA_G,
    output logic [7:0]  VGA_B,
    output logic        VGA_HS,
    output logic        VGA_VS,
    output logic        VGA_DE,
    output logic        VGA_F1,
    output logic [1:0]  VGA_SL,

    // --- Pixel Clock Output ---
    output logic        CE_PIXEL,

    // --- DDRAM Interface ---
    output logic [28:0] DDRAM_ADDR,   // 64-bit word address (512M × 8B = 4GB)
    output logic [7:0]  DDRAM_BURSTCNT,
    output logic [63:0] DDRAM_DIN,
    output logic [7:0]  DDRAM_BE,
    output logic        DDRAM_WE,
    output logic        DDRAM_RD,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY,
    input  logic        DDRAM_BUSY,

    // --- SD Card ---
    output logic        SD_SCK,
    output logic        SD_MOSI,
    input  logic        SD_MISO,
    output logic        SD_CS,
    input  logic        SD_CD,

    // --- I/O Board ---
    input  logic [6:0]  USER_IN,
    output logic [6:0]  USER_OUT,

    // --- Audio ---
    output logic [15:0] AUDIO_L,
    output logic [15:0] AUDIO_R,
    output logic        AUDIO_S,    // 1 = signed audio
    output logic [1:0]  AUDIO_MIX   // 0 = no mix, 1 = 25%, 2 = 50%, 3 = 100% monaural
);

    // =====================================================================
    //  Clocks and Reset
    // =====================================================================
    logic cpu_clk, pixel_clk, mem_clk, pll_locked;

    f386_pll pll_inst (
        .inclk0    (CLK_50M),
        .cpu_clk   (cpu_clk),
        .pixel_clk (pixel_clk),
        .mem_clk   (mem_clk),
        .locked    (pll_locked)
    );

    // Synchronized reset (active-low, asserted until PLL locks)
    logic [3:0] rst_cnt;
    logic       rst_n;

    always_ff @(posedge cpu_clk or negedge pll_locked) begin
        if (!pll_locked) begin
            rst_cnt <= 4'd0;
            rst_n   <= 1'b0;
        end else begin
            if (rst_cnt != 4'hF) begin
                rst_cnt <= rst_cnt + 4'd1;
                rst_n   <= 1'b0;
            end else begin
                rst_n <= 1'b1;
            end
        end
    end

    // Combined reset: PLL lock + user reset button + PS/2 0xFE command
    logic sys_reset_req;
    wire  combined_rst_n = rst_n && !sys_reset_req;

    // =====================================================================
    //  HPS I/O (MiSTer Framework Interface)
    // =====================================================================
    // OSD signals
    logic [31:0] status;
    logic [1:0]  buttons;
    logic        forced_scandoubler;
    logic        direct_video;
    // PS/2 from HPS
    logic [10:0] ps2_kbd_hps;
    logic        ps2_kbd_hps_stb;
    logic [24:0] ps2_mouse_hps;
    logic        ps2_mouse_hps_stb;
    // Image mounting
    logic        img_mounted;
    logic [63:0] img_size;
    logic [31:0] img_readonly;
    // SD block
    logic [31:0] sd_lba;
    logic        sd_rd, sd_wr;
    logic        sd_ack;
    logic [8:0]  sd_buff_addr;
    logic [7:0]  sd_buff_dout;
    logic [7:0]  sd_buff_din;
    logic        sd_buff_wr;

    // Accent for gamma bus
    logic [21:0] gamma_bus;

    // NOTE: hps_io is a MiSTer framework module — it must be copied from
    // the sys/ directory of the MiSTer template. It is NOT part of fabi386.
    // Uncomment and configure once integrating with the real framework.
    /*
    hps_io #(
        .CONF_STR(CONF_STR),
        .PS2DIV(2000),
        .WIDE(0)
    ) hps_io_inst (
        .clk_sys       (cpu_clk),
        .HPS_BUS       (),         // wired by MiSTer framework
        .conf_str      (),
        .status        (status),
        .buttons       (buttons),
        .forced_scandoubler(forced_scandoubler),
        .direct_video  (direct_video),
        .gamma_bus     (gamma_bus),
        .ps2_kbd_led_use(3'd0),
        .ps2_kbd_led_status(3'd0),
        .ps2_key       (ps2_kbd_hps),
        .ps2_mouse     (ps2_mouse_hps),
        .img_mounted   (img_mounted),
        .img_size      (img_size),
        .img_readonly  (img_readonly),
        .sd_lba        ({sd_lba}),
        .sd_rd         (sd_rd),
        .sd_wr         (sd_wr),
        .sd_ack        (sd_ack),
        .sd_buff_addr  (sd_buff_addr),
        .sd_buff_dout  (sd_buff_dout),
        .sd_buff_din   ({sd_buff_din}),
        .sd_buff_wr    (sd_buff_wr)
    );
    */

    // Placeholder signals until hps_io is instantiated
    assign status = 32'd0;
    assign buttons = 2'd0;
    assign ps2_kbd_hps = 11'd0;
    assign ps2_kbd_hps_stb = 1'b0;
    assign ps2_mouse_hps = 25'd0;
    assign ps2_mouse_hps_stb = 1'b0;

    // =====================================================================
    //  A20 Gate
    // =====================================================================
    // A20 is controlled by:
    //   1. OSD status bit (manual override)
    //   2. PS/2 controller output port bit 1 (command 0xD1)
    //   3. Port 0x92 fast A20 gate (System Control Port A)
    logic a20_osd, a20_fast, a20_ps2;
    logic a20_gate;

    assign a20_osd = status[1];

    // Fast A20 gate (port 0x92, bit 1)
    // Written by BIOS for fast A20 control without going through 8042
    logic [7:0] port_92;
    assign a20_fast = port_92[1];
    assign a20_ps2  = ps2_a20_gate;
    assign a20_gate = a20_osd | a20_fast | a20_ps2;

    always_ff @(posedge cpu_clk or negedge combined_rst_n) begin
        if (!combined_rst_n)
            port_92 <= 8'h02;  // A20 enabled by default
        else if (port_92_we)
            port_92 <= port_92_wdata;
    end

    logic port_92_we;
    logic [7:0] port_92_wdata;
    assign port_92_we = 1'b0;     // TODO: wire from iobus
    assign port_92_wdata = 8'h00;

    // =====================================================================
    //  PIT Clock Generation (1.193182 MHz from system clock)
    // =====================================================================
    // Generates a toggle enable at the PIT frequency.
    // cpu_clk is ~33 MHz, so divide by ~28 to get ~1.19 MHz.
    localparam int PIT_CLK_DIV = 28;  // 33.333/28 ≈ 1.190 MHz (close enough)
    logic [$clog2(PIT_CLK_DIV)-1:0] pit_div_cnt;
    logic pit_clk_en;

    always_ff @(posedge cpu_clk or negedge combined_rst_n) begin
        if (!combined_rst_n) begin
            pit_div_cnt <= '0;
            pit_clk_en  <= 1'b0;
        end else begin
            if (pit_div_cnt == PIT_CLK_DIV - 1) begin
                pit_div_cnt <= '0;
                pit_clk_en  <= 1'b1;
            end else begin
                pit_div_cnt <= pit_div_cnt + 1;
                pit_clk_en  <= 1'b0;
            end
        end
    end

    // =====================================================================
    //  CPU Core
    // =====================================================================
    logic [31:0]  fetch_addr;
    logic [127:0] fetch_data;
    logic         fetch_data_valid;
    logic         fetch_req;

    logic [31:0]  mem_addr;
    logic [63:0]  mem_wdata, mem_rdata;
    logic [7:0]   mem_byte_en;
    logic         mem_req, mem_wr, mem_ack, mem_gnt;
    logic         mem_cacheable, mem_strong_order;

    telemetry_pkt_t trace_out;
    logic           trace_valid;

    logic         cpu_irq;
    logic [7:0]   cpu_irq_vector;

    // Split-phase data port (between core and L2_SP when MEM_FABRIC=1)
    logic         sp_data_req_valid, sp_data_req_ready;
    mem_req_t     sp_data_req;
    logic         sp_data_rsp_valid, sp_data_rsp_ready;
    mem_rsp_t     sp_data_rsp;

    f386_ooo_core_top cpu (
        .clk             (cpu_clk),
        .rst_n           (combined_rst_n),

        .fetch_addr      (fetch_addr),
        .fetch_data      (fetch_data),
        .fetch_data_valid(fetch_data_valid),
        .fetch_req       (fetch_req),

        .mem_addr        (mem_addr),
        .mem_wdata       (mem_wdata),
        .mem_rdata       (mem_rdata),
        .mem_req          (mem_req),
        .mem_wr           (mem_wr),
        .mem_byte_en      (mem_byte_en),
        .mem_cacheable    (mem_cacheable),
        .mem_strong_order (mem_strong_order),
        .mem_ack          (mem_ack),
        .mem_gnt          (mem_gnt),

        .sp_data_req_valid (sp_data_req_valid),
        .sp_data_req_ready (sp_data_req_ready),
        .sp_data_req       (sp_data_req),
        .sp_data_rsp_valid (sp_data_rsp_valid),
        .sp_data_rsp_ready (sp_data_rsp_ready),
        .sp_data_rsp       (sp_data_rsp),

        .a20_gate        (a20_gate),

        .pt_addr         (pt_addr),
        .pt_wdata        (pt_wdata),
        .pt_rdata        (pt_rdata),
        .pt_req          (pt_req),
        .pt_wr           (pt_wr),
        .pt_ack          (pt_ack),

        .trace_out       (trace_out),
        .trace_valid     (trace_valid),

        .irq             (cpu_irq),
        .irq_vector      (cpu_irq_vector)
    );

    // =====================================================================
    //  Memory Controller (DDRAM Bridge)
    // =====================================================================
    // Page walker memory port (driven by core_top — tied off when TLB gate OFF)
    logic [31:0] pt_addr, pt_wdata, pt_rdata;
    logic        pt_req, pt_wr, pt_ack;

    generate
    if (CONF_ENABLE_MEM_FABRIC) begin : gen_l2_sp

`ifndef SYNTHESIS
        // Gate dependency: MEM_FABRIC requires LSQ_MEMIF (split-phase wiring)
        // and L2_CACHE (reuses L2 geometry params).
        initial begin
            if (!CONF_ENABLE_LSQ_MEMIF)
                $fatal(1, "CONF_ENABLE_MEM_FABRIC requires CONF_ENABLE_LSQ_MEMIF");
            if (!CONF_ENABLE_L2_CACHE)
                $fatal(1, "CONF_ENABLE_MEM_FABRIC requires CONF_ENABLE_L2_CACHE");
        end
`endif

        // L2_SP: split-phase data port + blocking ifetch/PT + DDRAM
        f386_l2_cache_sp l2_sp (
            .clk             (cpu_clk),
            .rst_n           (combined_rst_n),

            .ifetch_addr     (fetch_addr),
            .ifetch_data     (fetch_data),
            .ifetch_valid    (fetch_data_valid),
            .ifetch_req      (fetch_req),

            .data_req_valid  (sp_data_req_valid),
            .data_req_ready  (sp_data_req_ready),
            .data_req        (sp_data_req),
            .data_rsp_valid  (sp_data_rsp_valid),
            .data_rsp_ready  (sp_data_rsp_ready),
            .data_rsp        (sp_data_rsp),

            .pt_addr         (pt_addr),
            .pt_wdata        (pt_wdata),
            .pt_rdata        (pt_rdata),
            .pt_req          (pt_req),
            .pt_wr           (pt_wr),
            .pt_ack          (pt_ack),

            .a20_gate        (a20_gate),

            .ddram_addr      (DDRAM_ADDR),
            .ddram_burstcnt  (DDRAM_BURSTCNT),
            .ddram_din       (DDRAM_DIN),
            .ddram_be        (DDRAM_BE),
            .ddram_we        (DDRAM_WE),
            .ddram_rd        (DDRAM_RD),
            .ddram_dout      (DDRAM_DOUT),
            .ddram_dout_ready(DDRAM_DOUT_READY),
            .ddram_busy      (DDRAM_BUSY)
        );

    end else if (CONF_ENABLE_L2_CACHE) begin : gen_l2_cache

        f386_l2_cache l2 (
            .clk             (cpu_clk),
            .rst_n           (combined_rst_n),

            .ifetch_addr     (fetch_addr),
            .ifetch_data     (fetch_data),
            .ifetch_valid    (fetch_data_valid),
            .ifetch_req      (fetch_req),

            .data_addr         (mem_addr),
            .data_wdata        (mem_wdata),
            .data_rdata        (mem_rdata),
            .data_req          (mem_req),
            .data_wr           (mem_wr),
            .data_byte_en      (mem_byte_en),
            .data_cacheable    (mem_cacheable),
            .data_strong_order (mem_strong_order),
            .data_ack          (mem_ack),
            .data_gnt          (mem_gnt),

            .pt_addr         (pt_addr),
            .pt_wdata        (pt_wdata),
            .pt_rdata        (pt_rdata),
            .pt_req          (pt_req),
            .pt_wr           (pt_wr),
            .pt_ack          (pt_ack),

            .a20_gate        (a20_gate),

            .ddram_addr      (DDRAM_ADDR),
            .ddram_burstcnt  (DDRAM_BURSTCNT),
            .ddram_din       (DDRAM_DIN),
            .ddram_be        (DDRAM_BE),
            .ddram_we        (DDRAM_WE),
            .ddram_rd        (DDRAM_RD),
            .ddram_dout      (DDRAM_DOUT),
            .ddram_dout_ready(DDRAM_DOUT_READY),
            .ddram_busy      (DDRAM_BUSY)
        );

    end else begin : gen_mem_ctrl

        f386_mem_ctrl mem_ctrl (
            .clk             (cpu_clk),
            .rst_n           (combined_rst_n),

            .ifetch_addr     (fetch_addr),
            .ifetch_data     (fetch_data),
            .ifetch_valid    (fetch_data_valid),
            .ifetch_req      (fetch_req),

            .data_addr         (mem_addr),
            .data_wdata        (mem_wdata),
            .data_rdata        (mem_rdata),
            .data_req          (mem_req),
            .data_wr           (mem_wr),
            .data_byte_en      (mem_byte_en),
            .data_cacheable    (mem_cacheable),
            .data_strong_order (mem_strong_order),
            .data_ack          (mem_ack),
            .data_gnt          (mem_gnt),

            .pt_addr         (pt_addr),
            .pt_wdata        (pt_wdata),
            .pt_rdata        (pt_rdata),
            .pt_req          (pt_req),
            .pt_wr           (pt_wr),
            .pt_ack          (pt_ack),

            .a20_gate        (a20_gate),

            .ddram_addr      (DDRAM_ADDR),
            .ddram_burstcnt  (DDRAM_BURSTCNT),
            .ddram_din       (DDRAM_DIN),
            .ddram_be        (DDRAM_BE),
            .ddram_we        (DDRAM_WE),
            .ddram_rd        (DDRAM_RD),
            .ddram_dout      (DDRAM_DOUT),
            .ddram_dout_ready(DDRAM_DOUT_READY),
            .ddram_busy      (DDRAM_BUSY)
        );

    end
    endgenerate

    // =====================================================================
    //  I/O Bus
    // =====================================================================
    // Peripheral bus signals (from iobus to peripherals)
    logic [15:0] periph_io_addr;
    logic [7:0]  periph_io_wdata;
    logic        periph_io_wr, periph_io_rd;
    logic        pic_cs, pit_cs, ps2_cs, vga_cs, rtc_cs, dma_cs;
    logic [7:0]  pic_rdata, pit_rdata, ps2_rdata, vga_rdata, rtc_rdata, dma_rdata;

    // CPU I/O bus (stub — will be driven by execute stage I/O micro-ops)
    logic [15:0] cpu_io_addr;
    logic [31:0] cpu_io_wdata, cpu_io_rdata;
    logic        cpu_io_wr, cpu_io_rd;
    logic [1:0]  cpu_io_size;
    logic        cpu_io_ack;

    // Stub: no I/O operations until microcode drives IN/OUT
    assign cpu_io_addr  = 16'd0;
    assign cpu_io_wdata = 32'd0;
    assign cpu_io_wr    = 1'b0;
    assign cpu_io_rd    = 1'b0;
    assign cpu_io_size  = 2'd0;

    f386_iobus iobus (
        .clk             (cpu_clk),
        .rst_n           (combined_rst_n),

        .cpu_io_addr     (cpu_io_addr),
        .cpu_io_wdata    (cpu_io_wdata),
        .cpu_io_rdata    (cpu_io_rdata),
        .cpu_io_wr       (cpu_io_wr),
        .cpu_io_rd       (cpu_io_rd),
        .cpu_io_size     (cpu_io_size),
        .cpu_io_ack      (cpu_io_ack),

        .pic_cs          (pic_cs),
        .pit_cs          (pit_cs),
        .ps2_cs          (ps2_cs),
        .vga_cs          (vga_cs),
        .rtc_cs          (rtc_cs),
        .dma_cs          (dma_cs),

        .pic_rdata       (pic_rdata),
        .pit_rdata       (pit_rdata),
        .ps2_rdata       (ps2_rdata),
        .vga_rdata       (vga_rdata),
        .rtc_rdata       (rtc_rdata),
        .dma_rdata       (dma_rdata),

        .periph_io_addr  (periph_io_addr),
        .periph_io_wdata (periph_io_wdata),
        .periph_io_wr    (periph_io_wr),
        .periph_io_rd    (periph_io_rd)
    );

    // =====================================================================
    //  PIC (Dual 8259A)
    // =====================================================================
    logic [15:0] irq_lines;

    // Standard PC/AT IRQ assignment
    assign irq_lines[0]  = pit_irq0;          // Timer (PIT counter 0)
    assign irq_lines[1]  = ps2_irq_kbd;       // Keyboard
    assign irq_lines[2]  = 1'b0;              // Cascade (slave PIC)
    assign irq_lines[3]  = 1'b0;              // COM2 (not implemented)
    assign irq_lines[4]  = 1'b0;              // COM1 (not implemented)
    assign irq_lines[5]  = 1'b0;              // LPT2 / Sound (not implemented)
    assign irq_lines[6]  = 1'b0;              // Floppy (not implemented)
    assign irq_lines[7]  = 1'b0;              // LPT1 (not implemented)
    assign irq_lines[8]  = 1'b0;              // RTC (stub doesn't generate IRQ)
    assign irq_lines[9]  = 1'b0;              // ACPI / redirected IRQ2
    assign irq_lines[10] = 1'b0;              // Available
    assign irq_lines[11] = 1'b0;              // Available
    assign irq_lines[12] = ps2_irq_mouse;     // PS/2 Mouse
    assign irq_lines[13] = 1'b0;              // FPU error
    assign irq_lines[14] = 1'b0;              // Primary IDE
    assign irq_lines[15] = 1'b0;              // Secondary IDE

    logic pic_int_ack;
    assign pic_int_ack = 1'b0;  // TODO: wire from microcode INT acknowledge

    f386_pic pic (
        .clk       (cpu_clk),
        .rst_n     (combined_rst_n),
        .io_addr   (periph_io_addr),
        .io_wdata  (periph_io_wdata),
        .io_rdata  (pic_rdata),
        .io_wr     (periph_io_wr),
        .io_rd     (periph_io_rd),
        .io_cs     (pic_cs),
        .irq_lines (irq_lines),
        .int_req   (cpu_irq),
        .int_vector(cpu_irq_vector),
        .int_ack   (pic_int_ack)
    );

    // =====================================================================
    //  PIT (8254 Timer)
    // =====================================================================
    logic pit_irq0;
    logic pit_speaker_out;

    f386_pit pit (
        .clk        (cpu_clk),
        .rst_n      (combined_rst_n),
        .pit_clk_in (pit_clk_en),
        .io_addr    (periph_io_addr),
        .io_wdata   (periph_io_wdata),
        .io_rdata   (pit_rdata),
        .io_wr      (periph_io_wr),
        .io_rd      (periph_io_rd),
        .io_cs      (pit_cs),
        .irq0       (pit_irq0),
        .speaker_out(pit_speaker_out)
    );

    // =====================================================================
    //  PS/2 Controller (8042)
    // =====================================================================
    logic ps2_irq_kbd, ps2_irq_mouse;
    logic ps2_a20_gate;
    logic ps2_sys_reset;

    // HPS keyboard/mouse byte injection (ready/valid handshake)
    // Stub: no data until hps_io is wired
    logic [7:0] hps_kbd_data, hps_mouse_data;
    logic       hps_kbd_valid, hps_mouse_valid;
    logic       hps_kbd_ready, hps_mouse_ready;

    assign hps_kbd_data    = 8'd0;
    assign hps_kbd_valid   = 1'b0;
    assign hps_mouse_data  = 8'd0;
    assign hps_mouse_valid = 1'b0;

    f386_ps2 ps2 (
        .clk         (cpu_clk),
        .rst_n       (combined_rst_n),
        .io_addr     (periph_io_addr),
        .io_wdata    (periph_io_wdata),
        .io_rdata    (ps2_rdata),
        .io_wr       (periph_io_wr),
        .io_rd       (periph_io_rd),
        .io_cs       (ps2_cs),
        .irq1        (ps2_irq_kbd),
        .irq12       (ps2_irq_mouse),
        .a20_gate    (ps2_a20_gate),
        .sys_reset   (ps2_sys_reset),
        .kbd_data    (hps_kbd_data),
        .kbd_valid   (hps_kbd_valid),
        .kbd_ready   (hps_kbd_ready),
        .mouse_data  (hps_mouse_data),
        .mouse_valid (hps_mouse_valid),
        .mouse_ready (hps_mouse_ready)
    );

    // =====================================================================
    //  VGA (Text Mode Only)
    // =====================================================================
    // VGA framebuffer memory-mapped access (0xB8000-0xBFFFF)
    // Currently stubbed — will be driven by memory controller for CPU VRAM access
    logic [15:0] fb_addr;
    logic [7:0]  fb_wdata, fb_rdata;
    logic        fb_wr, fb_rd, fb_cs;

    assign fb_addr  = 16'd0;
    assign fb_wdata = 8'd0;
    assign fb_wr    = 1'b0;
    assign fb_rd    = 1'b0;
    assign fb_cs    = 1'b0;

    f386_vga vga (
        .clk        (cpu_clk),
        .rst_n      (combined_rst_n),
        .pixel_clk  (pixel_clk),
        .io_addr    (periph_io_addr),
        .io_wdata   (periph_io_wdata),
        .io_rdata   (vga_rdata),
        .io_wr      (periph_io_wr),
        .io_rd      (periph_io_rd),
        .io_cs      (vga_cs),
        .fb_addr    (fb_addr),
        .fb_wdata   (fb_wdata),
        .fb_rdata   (fb_rdata),
        .fb_wr      (fb_wr),
        .fb_rd      (fb_rd),
        .fb_cs      (fb_cs),
        .vga_hsync  (VGA_HS),
        .vga_vsync  (VGA_VS),
        .vga_r      (VGA_R),
        .vga_g      (VGA_G),
        .vga_b      (VGA_B),
        .vga_de     (VGA_DE),
        .vga_vblank ()
    );

    // =====================================================================
    //  RTC Stub
    // =====================================================================
    logic rtc_nmi_mask;

    f386_rtc_stub rtc (
        .clk      (cpu_clk),
        .rst_n    (combined_rst_n),
        .io_addr  (periph_io_addr),
        .io_wdata (periph_io_wdata),
        .io_rdata (rtc_rdata),
        .io_wr    (periph_io_wr),
        .io_rd    (periph_io_rd),
        .io_cs    (rtc_cs),
        .nmi_mask (rtc_nmi_mask)
    );

    // =====================================================================
    //  DMA Stub
    // =====================================================================
    f386_dma_stub dma (
        .clk      (cpu_clk),
        .rst_n    (combined_rst_n),
        .io_addr  (periph_io_addr),
        .io_wdata (periph_io_wdata),
        .io_rdata (dma_rdata),
        .io_wr    (periph_io_wr),
        .io_rd    (periph_io_rd),
        .io_cs    (dma_cs)
    );

    // =====================================================================
    //  Audio (PC Speaker — square wave from PIT counter 2)
    // =====================================================================
    // Simple 1-bit audio from speaker output, scaled to 16-bit
    assign AUDIO_L   = pit_speaker_out ? 16'h3FFF : 16'hC001;
    assign AUDIO_R   = AUDIO_L;
    assign AUDIO_S   = 1'b1;   // Signed audio
    assign AUDIO_MIX = 2'd0;   // No mix

    // =====================================================================
    //  Miscellaneous Outputs
    // =====================================================================
    assign LED_USER  = 1'b0;
    assign LED_HDD   = 1'b0;
    assign LED_POWER = 1'b1;
    assign BUTTONS   = 2'd0;
    assign VGA_F1    = 1'b0;
    assign VGA_SL    = 2'd0;
    assign CE_PIXEL  = 1'b1;

    // SD card unused for now (disk I/O will go through HPS DDRAM)
    assign SD_SCK  = 1'b0;
    assign SD_MOSI = 1'b0;
    assign SD_CS   = 1'b1;

    assign USER_OUT = 7'd0;

    // System reset request (from PS/2 controller command 0xFE)
    assign sys_reset_req = ps2_sys_reset;

endmodule
