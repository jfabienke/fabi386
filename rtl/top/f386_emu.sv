/*
 * fabi386: MiSTer emu Top-Level Module
 * -------------------------------------
 * Module name `emu` is mandated by the MiSTer sys_top framework
 * (rtl/sys/sys_top.v instantiates `emu` by name). Kept in file
 * `f386_emu.sv` for repo history continuity.
 *
 * Wires together the CPU core, peripherals, memory controller,
 * and video output for the DE10-Nano FPGA. Unused MiSTer framework
 * signals (SDRAM, UART, ADC, HDMI hints) are tied off at the
 * bottom of this module; enable them as features are added.
 *
 * Reference: reference/ao486_MiSTer/ao486.sv
 */

import f386_pkg::*;
import f386_conf_str_pkg::*;

module emu (
    // --- Master clock ---
    input  logic        CLK_50M,

    // --- Async reset from sys_top ---
    input  logic        RESET,

    // --- HPS bus (OSD, file loading, joystick/keyboard/mouse, RTC, status) ---
    inout  logic [48:0] HPS_BUS,

    // --- Video clocks ---
    output logic        CLK_VIDEO,   // base video clock, usually == CLK_SYS
    output logic        CE_PIXEL,    // pixel clock enable relative to CLK_VIDEO

    // --- Video aspect ratio for HDMI scaler ---
    output logic [12:0] VIDEO_ARX,
    output logic [12:0] VIDEO_ARY,

    // --- VGA output (to scaler / analog out) ---
    output logic [7:0]  VGA_R,
    output logic [7:0]  VGA_G,
    output logic [7:0]  VGA_B,
    output logic        VGA_HS,
    output logic        VGA_VS,
    output logic        VGA_DE,
    output logic        VGA_F1,
    output logic [1:0]  VGA_SL,
    output logic        VGA_SCALER,
    output logic        VGA_DISABLE,

    // --- HDMI scaler feedback ---
    input  logic [11:0] HDMI_WIDTH,
    input  logic [11:0] HDMI_HEIGHT,
    output logic        HDMI_FREEZE,
    output logic        HDMI_BLACKOUT,
    output logic        HDMI_BOB_DEINT,

    // --- LEDs and buttons ---
    output logic        LED_USER,
    output logic [1:0]  LED_POWER,
    output logic [1:0]  LED_DISK,
    output logic [1:0]  BUTTONS,

    // --- Full-array LED debug bus (fabi386 diagnostic extension) ---
    // OR'd by sys_top into the DE10-Nano onboard LED[7:0] array. Lets the
    // core drive all 8 LEDs independently for layered status display.
    output logic [7:0]  LED_DEBUG,

    // --- Audio ---
    input  logic        CLK_AUDIO,   // 24.576 MHz
    output logic [15:0] AUDIO_L,
    output logic [15:0] AUDIO_R,
    output logic        AUDIO_S,     // 1 = signed samples
    output logic [1:0]  AUDIO_MIX,   // 0=none 1=25% 2=50% 3=100% monaural

    // --- ADC bus ---
    inout  logic [3:0]  ADC_BUS,

    // --- SD card (SPI) ---
    output logic        SD_SCK,
    output logic        SD_MOSI,
    input  logic        SD_MISO,
    output logic        SD_CS,
    input  logic        SD_CD,

    // --- DDR3 (via HPS) ---
    output logic        DDRAM_CLK,
    input  logic        DDRAM_BUSY,
    output logic [7:0]  DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY,
    output logic        DDRAM_RD,
    output logic [63:0] DDRAM_DIN,
    output logic [7:0]  DDRAM_BE,
    output logic        DDRAM_WE,

    // --- SDRAM (daughter board) ---
    output logic        SDRAM_CLK,
    output logic        SDRAM_CKE,
    output logic [12:0] SDRAM_A,
    output logic [1:0]  SDRAM_BA,
    inout  logic [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nWE,

    // --- UART ---
    input  logic        UART_CTS,
    output logic        UART_RTS,
    input  logic        UART_RXD,
    output logic        UART_TXD,
    output logic        UART_DTR,
    input  logic        UART_DSR,

    // --- User I/O port (open-drain) ---
    input  logic [6:0]  USER_IN,
    output logic [6:0]  USER_OUT,

    // --- OSD status ---
    input  logic        OSD_STATUS
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
    // + async RESET from sys_top + OSD "Reset" menu entry (status[0]).
    logic sys_reset_req;
    logic osd_reset_req;  // driven later from status[0]
    wire  combined_rst_n = rst_n && !sys_reset_req && !RESET && !osd_reset_req;

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

    // =====================================================================
    //  hps_io instantiation (MiSTer framework link)
    // =====================================================================
    // Gated by MISTER_FULL. When unset (sv2v resource-check flow, no
    // rtl/sys/ files in the source list), HPS_BUS stays high-Z and the
    // framework outputs are held at safe defaults.
    //
    // CONF_STR comes from rtl/top/f386_conf_str.sv:
    //   status[0] = "R[0],Reset;"
    //   status[1] = A20 override
    //   status[2] = CPU speed
    //
    // Only the subset of hps_io signals actually used by fabi386 is
    // connected. Joysticks, paddles, spinners, ADC, SD image loading,
    // UART, gamma, and scaler overrides are left defaulted — add them
    // as features are brought up.
`ifdef MISTER_FULL
    wire [31:0] gamma_bus_unused;

    hps_io #(
        .CONF_STR(CONF_STR),
        .CONF_STR_BRAM(0),
        .PS2DIV(2000),
        .PS2WE(1),
        .WIDE(0)
    ) hps_io_inst (
        .clk_sys            (cpu_clk),
        .HPS_BUS            (HPS_BUS),

        .buttons            (buttons),
        .status             (status),
        .forced_scandoubler (forced_scandoubler),
        .direct_video       (direct_video),

        // ps2_key: [10]=toggle/stb, [9]=pressed, [8]=extended, [7:0]=scan
        .ps2_key            (ps2_kbd_hps),
        .ps2_mouse          (ps2_mouse_hps),

        .gamma_bus          (gamma_bus)
    );
    assign ps2_kbd_hps_stb   = 1'b0;
    assign ps2_mouse_hps_stb = 1'b0;
    assign img_mounted       = 1'b0;
    assign img_size          = 64'd0;
    assign img_readonly      = 32'd0;
`else
    // Non-MiSTer resource-check flow: tie everything off.
    assign HPS_BUS           = 49'bz;
    assign status            = 32'd0;
    assign buttons           = 2'd0;
    assign forced_scandoubler = 1'b0;
    assign direct_video      = 1'b0;
    assign gamma_bus         = 22'd0;
    assign ps2_kbd_hps       = 11'd0;
    assign ps2_kbd_hps_stb   = 1'b0;
    assign ps2_mouse_hps     = 25'd0;
    assign ps2_mouse_hps_stb = 1'b0;
    assign img_mounted       = 1'b0;
    assign img_size          = 64'd0;
    assign img_readonly      = 32'd0;
`endif

    // OSD reset request (status[0], toggled by "R[0],Reset;" menu entry)
    assign osd_reset_req = status[0];

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

        .io_port_addr    (cpu_io_addr),
        .io_port_wdata   (cpu_io_wdata),
        .io_port_wr      (cpu_io_wr),
        .io_port_rd      (cpu_io_rd),
        .io_port_size    (cpu_io_size),
        .io_port_rdata   (cpu_io_rdata),
        .io_port_ack     (cpu_io_ack),

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
    //  Memory Controller (DDRAM Bridge) + BIOS ROM intercept
    // =====================================================================
    // Page walker memory port (driven by core_top — tied off when TLB gate OFF)
    logic [31:0] pt_addr, pt_wdata, pt_rdata;
    logic        pt_req, pt_wr, pt_ack;

    // Intermediate DDRAM bus between L2/mem_ctrl and the f386_ddram_bios_mux.
    // The mux forwards most traffic to the real MiSTer DDRAM_* pins but
    // short-circuits reads in 0xFC000..0xFFFFF to the BIOS ROM.
    logic [28:0] l2_ddram_addr;
    logic [7:0]  l2_ddram_burstcnt;
    logic [63:0] l2_ddram_din;
    logic [7:0]  l2_ddram_be;
    logic        l2_ddram_we;
    logic        l2_ddram_rd;
    logic [63:0] l2_ddram_dout;
    logic        l2_ddram_dout_ready;
    logic        l2_ddram_busy;

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

            .ddram_addr      (l2_ddram_addr),
            .ddram_burstcnt  (l2_ddram_burstcnt),
            .ddram_din       (l2_ddram_din),
            .ddram_be        (l2_ddram_be),
            .ddram_we        (l2_ddram_we),
            .ddram_rd        (l2_ddram_rd),
            .ddram_dout      (l2_ddram_dout),
            .ddram_dout_ready(l2_ddram_dout_ready),
            .ddram_busy      (l2_ddram_busy)
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

            .ddram_addr      (l2_ddram_addr),
            .ddram_burstcnt  (l2_ddram_burstcnt),
            .ddram_din       (l2_ddram_din),
            .ddram_be        (l2_ddram_be),
            .ddram_we        (l2_ddram_we),
            .ddram_rd        (l2_ddram_rd),
            .ddram_dout      (l2_ddram_dout),
            .ddram_dout_ready(l2_ddram_dout_ready),
            .ddram_busy      (l2_ddram_busy)
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

            .ddram_addr      (l2_ddram_addr),
            .ddram_burstcnt  (l2_ddram_burstcnt),
            .ddram_din       (l2_ddram_din),
            .ddram_be        (l2_ddram_be),
            .ddram_we        (l2_ddram_we),
            .ddram_rd        (l2_ddram_rd),
            .ddram_dout      (l2_ddram_dout),
            .ddram_dout_ready(l2_ddram_dout_ready),
            .ddram_busy      (l2_ddram_busy)
        );

    end
    endgenerate

    // =====================================================================
    //  Diagnostics BIOS ROM (16 KB at 0xFC000..0xFFFFF) + DDRAM/ROM mux
    // =====================================================================
    // The ROM is populated at elaboration time from asm/diagnostic.hex
    // (see asm/diagnostic.asm). The mux intercepts L2 reads in the BIOS
    // region and forwards everything else to the real DDRAM pins.
    logic [10:0] bios_rom_rd_addr;
    logic [63:0] bios_rom_rd_data;

    f386_bios_rom bios_rom (
        .clk     (cpu_clk),
        .rd_addr (bios_rom_rd_addr),
        .rd_data (bios_rom_rd_data)
    );

    f386_ddram_bios_mux ddram_mux (
        .clk                 (cpu_clk),
        .rst_n               (combined_rst_n),

        // L2-facing (intermediate wires driven by the L2/mem_ctrl instances)
        .l2_ddram_addr       (l2_ddram_addr),
        .l2_ddram_burstcnt   (l2_ddram_burstcnt),
        .l2_ddram_din        (l2_ddram_din),
        .l2_ddram_be         (l2_ddram_be),
        .l2_ddram_we         (l2_ddram_we),
        .l2_ddram_rd         (l2_ddram_rd),
        .l2_ddram_dout       (l2_ddram_dout),
        .l2_ddram_dout_ready (l2_ddram_dout_ready),
        .l2_ddram_busy       (l2_ddram_busy),

        // Top-level MiSTer DDRAM pins
        .ddram_addr          (DDRAM_ADDR),
        .ddram_burstcnt      (DDRAM_BURSTCNT),
        .ddram_din           (DDRAM_DIN),
        .ddram_be            (DDRAM_BE),
        .ddram_we            (DDRAM_WE),
        .ddram_rd            (DDRAM_RD),
        .ddram_dout          (DDRAM_DOUT),
        .ddram_dout_ready    (DDRAM_DOUT_READY),
        .ddram_busy          (DDRAM_BUSY),

        // BIOS ROM port
        .bios_rd_addr        (bios_rom_rd_addr),
        .bios_rd_data        (bios_rom_rd_data)
    );

    // =====================================================================
    //  I/O Bus
    // =====================================================================
    // Peripheral bus signals (from iobus to peripherals)
    logic [15:0] periph_io_addr;
    logic [7:0]  periph_io_wdata;
    logic        periph_io_wr, periph_io_rd;
    logic        pic_cs, pit_cs, ps2_cs, vga_cs, rtc_cs, dma_cs;
    logic [7:0]  pic_rdata, pit_rdata, ps2_rdata, vga_rdata, rtc_rdata, dma_rdata;

    // CPU I/O bus (driven by core_top microcode IN/OUT micro-ops)
    logic [15:0] cpu_io_addr;
    logic [31:0] cpu_io_wdata, cpu_io_rdata;
    logic        cpu_io_wr, cpu_io_rd;
    logic [1:0]  cpu_io_size;
    logic        cpu_io_ack;

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
    logic [7:0] hps_kbd_data, hps_mouse_data;
    logic       hps_kbd_valid, hps_mouse_valid;
    logic       hps_kbd_ready, hps_mouse_ready;

    // ---------------------------------------------------------------------
    //  ps2_key → byte adapter
    // ---------------------------------------------------------------------
    // hps_io delivers decoded key events on ps2_kbd_hps[10:0]:
    //   [10] toggle (changes once per event), [9] pressed, [8] extended,
    //   [7:0] scancode.
    // f386_ps2 wants raw PS/2 bytes via ready/valid. First-pass adapter
    // emits the scancode byte on every event and relies on downstream
    // handling — extended-prefix (0xE0) and break-prefix (0xF0) are
    // NOT emitted yet; that will come in a follow-up when we verify
    // what DOS actually needs.
    logic ps2_key_toggle_r;
    always_ff @(posedge cpu_clk or negedge combined_rst_n) begin
        if (!combined_rst_n) begin
            ps2_key_toggle_r <= 1'b0;
            hps_kbd_data     <= 8'd0;
            hps_kbd_valid    <= 1'b0;
        end else begin
            if (hps_kbd_valid && hps_kbd_ready)
                hps_kbd_valid <= 1'b0;           // byte consumed
            if ((ps2_kbd_hps[10] != ps2_key_toggle_r) && !hps_kbd_valid) begin
                ps2_key_toggle_r <= ps2_kbd_hps[10];
                hps_kbd_data     <= ps2_kbd_hps[7:0];
                hps_kbd_valid    <= 1'b1;
            end
        end
    end

    // Mouse pass-through not implemented yet
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
    //  VGA / ETX Display Engine (feature-gated replacement)
    // =====================================================================
    generate if (CONF_ENABLE_ETX) begin : gen_etx
        f386_etx_engine etx_inst (
            .clk        (cpu_clk),
            .rst_n      (combined_rst_n),
            .pixel_clk  (pixel_clk),
            .io_addr    (periph_io_addr),
            .io_wdata   (periph_io_wdata),
            .io_rdata   (vga_rdata),
            .io_wr      (periph_io_wr),
            .io_rd      (periph_io_rd),
            .io_cs      (vga_cs),
            .vga_r      (VGA_R),
            .vga_g      (VGA_G),
            .vga_b      (VGA_B),
            .vga_hs     (VGA_HS),
            .vga_vs     (VGA_VS),
            .vga_de     (VGA_DE)
        );
    end else begin : gen_legacy_vga
        // VGA framebuffer access is driven by f386_console_port, which
        // snoops the peripheral I/O bus for writes to 0xC000..0xC002 and
        // translates them into character/attribute writes into the VGA
        // module's internal 4 KB text framebuffer.
        //
        // This exists because writing to the standard VGA framebuffer at
        // 0xB8000 requires MOV Sreg (microcoded, off in this build) to
        // set ES, so the CPU can't use the usual `mov es, 0xB800; mov
        // [es:di], al` pattern. OUT to an I/O port avoids the microcode
        // requirement entirely.
        logic [15:0] fb_addr;
        logic [7:0]  fb_wdata, fb_rdata;
        logic        fb_wr, fb_rd, fb_cs;

        f386_console_port console_port (
            .clk      (cpu_clk),
            .rst_n    (combined_rst_n),
            .io_addr  (periph_io_addr),
            .io_wdata (periph_io_wdata),
            .io_wr    (periph_io_wr),
            .fb_addr  (fb_addr),
            .fb_wdata (fb_wdata),
            .fb_wr    (fb_wr),
            .fb_cs    (fb_cs)
        );
        assign fb_rd = 1'b0;  // console port is write-only for now

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
    end endgenerate;

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
    //  Diagnostic LED heartbeats (3-level liveness check)
    // =====================================================================
    // sys_top routes these three signals to the DE10-Nano onboard LED
    // array (LEDR[0], LEDR[4], LEDR[2] respectively). Each LED proves
    // liveness at a different layer — if the CPU LED (LED_USER) isn't
    // blinking, we can still see whether the 50 MHz input clock and the
    // PLL-derived cpu_clk are running.
    //
    //   LED_USER       ← CPU heartbeat via I/O port 0x378 (full chain)
    //   LED_POWER[0]   ← 50 MHz counter bit 25 (~0.75 Hz, input clock only)
    //   LED_DISK[0]    ← cpu_clk counter bit 24 (~1 Hz, depends on PLL)
    //   [1] bit on both = "manual control, ignore system status"
    //
    // The 50 MHz counter uses CLK_50M directly so it's independent of the
    // PLL and combined_rst_n. If this LED doesn't blink, the bitstream
    // isn't running at all.
    logic [26:0] clk50_heartbeat;
    always_ff @(posedge CLK_50M) begin
        clk50_heartbeat <= clk50_heartbeat + 27'd1;
    end

    // The cpu_clk counter is GATED by combined_rst_n: it only advances
    // when the CPU is released from reset. If this LED blinks on hardware,
    // we know both the PLL is locked AND combined_rst_n is deasserted —
    // which pins "CPU can't be blinking LED_USER" down to decode/execute
    // rather than a stuck-in-reset problem.
    logic [26:0] cpuclk_heartbeat;
    always_ff @(posedge cpu_clk or negedge combined_rst_n) begin
        if (!combined_rst_n)
            cpuclk_heartbeat <= 27'd0;
        else
            cpuclk_heartbeat <= cpuclk_heartbeat + 27'd1;
    end

    // CPU-driven heartbeat: BIOS ROM writes bit 0 of port 0x378.
    logic diag_led_state;
    always_ff @(posedge cpu_clk or negedge combined_rst_n) begin
        if (!combined_rst_n)
            diag_led_state <= 1'b0;
        else if (periph_io_wr && periph_io_addr == 16'h0378)
            diag_led_state <= periph_io_wdata[0];
    end

    // Debug: L2-to-DDRAM activity probes. These catch the case where the
    // CPU never reaches OUT because it's stuck somewhere upstream (e.g.,
    // L2 not fetching from BIOS, fetch unit stalled, decode hanging on a
    // specific opcode). The mux's BIOS window is 0xC000..0xFFFF (where
    // fabi386's reset vector at 0xFFF0 actually lands), word-addr bits
    // [28:11] == 18'h3.
    wire l2_any_rd   = l2_ddram_rd;
    wire l2_bios_rd  = l2_ddram_rd && (l2_ddram_addr[28:11] == 18'h00003);

    // Sticky bits: set on first read, never cleared until reset.
    logic l2_any_rd_ever, l2_bios_rd_ever;
    always_ff @(posedge cpu_clk or negedge combined_rst_n) begin
        if (!combined_rst_n) begin
            l2_any_rd_ever  <= 1'b0;
            l2_bios_rd_ever <= 1'b0;
        end else begin
            if (l2_any_rd)  l2_any_rd_ever  <= 1'b1;
            if (l2_bios_rd) l2_bios_rd_ever <= 1'b1;
        end
    end

    // Activity monostable: ~30 ms on-time per BIOS read, retriggered by
    // subsequent reads. Lets slow-eye readers see "L2 is actively fetching
    // ROM" as steady-on vs. "fetched once long ago" as the sticky bit.
    logic [19:0] bios_activity_extender;
    always_ff @(posedge cpu_clk or negedge combined_rst_n) begin
        if (!combined_rst_n)
            bios_activity_extender <= 20'd0;
        else if (l2_bios_rd)
            bios_activity_extender <= 20'hFFFFF;
        else if (bios_activity_extender != 20'd0)
            bios_activity_extender <= bios_activity_extender - 20'd1;
    end
    wire bios_active = (bios_activity_extender != 20'd0);

    // L2 write-back observable path.
    //
    // OUT is broken (microcode IO_WAIT never fires io_port_wr in this config),
    // so the diag ROM can't use port 0x378 to signal liveness. But *memory*
    // writes flow through LSQ → L2 → DDRAM just fine. When the ROM issues
    // MOV [mem], reg, the store is cached dirty in L2 until the line evicts,
    // at which point the mux sees an l2_ddram_we burst. Counting those
    // gives us a visible "CPU is doing memory work" indicator.
    //
    // Sticky: set on the first wb, never cleared until reset.
    logic l2_wb_ever;
    always_ff @(posedge cpu_clk or negedge combined_rst_n) begin
        if (!combined_rst_n)
            l2_wb_ever <= 1'b0;
        else if (l2_ddram_we)
            l2_wb_ever <= 1'b1;
    end

    // Counter: bit[22] toggles every ~256K write beats, giving a slow
    // visible blink once L2 starts evicting regularly.
    logic [22:0] l2_wb_cnt;
    always_ff @(posedge cpu_clk or negedge combined_rst_n) begin
        if (!combined_rst_n)
            l2_wb_cnt <= 23'd0;
        else if (l2_ddram_we)
            l2_wb_cnt <= l2_wb_cnt + 23'd1;
    end

    // Any-I/O-write activity extender (~30 ms at ~33 MHz). Lets us
    // see "CPU is executing at least some OUT instruction" even if
    // it's not the 0x378 LED port we expected.
    logic [19:0] any_iowr_extender;
    always_ff @(posedge cpu_clk or negedge combined_rst_n) begin
        if (!combined_rst_n)
            any_iowr_extender <= 20'd0;
        else if (periph_io_wr)
            any_iowr_extender <= 20'hFFFFF;
        else if (any_iowr_extender != 20'd0)
            any_iowr_extender <= any_iowr_extender - 20'd1;
    end
    wire any_iowr_active = (any_iowr_extender != 20'd0);

    // Console-port write activity extender (ports 0xC000..0xC003).
    // Separates "CPU writing to console" from "CPU writing to LED port".
    logic [19:0] console_wr_extender;
    wire         console_port_hit = periph_io_wr && (periph_io_addr[15:2] == 14'h3000);
    always_ff @(posedge cpu_clk or negedge combined_rst_n) begin
        if (!combined_rst_n)
            console_wr_extender <= 20'd0;
        else if (console_port_hit)
            console_wr_extender <= 20'hFFFFF;
        else if (console_wr_extender != 20'd0)
            console_wr_extender <= console_wr_extender - 20'd1;
    end
    wire console_wr_active = (console_wr_extender != 20'd0);

    // =====================================================================
    //  Full 8-LED status display (DE10-Nano LEDR[7:0])
    // =====================================================================
    //
    //   Reading top (LED[7]) to bottom (LED[0], nearest KEY[0]):
    //
    //   LEDR[7]  L2 has fetched from BIOS region at some point (sticky)
    //   LEDR[6]  L2 has issued ANY DDRAM read at some point (sticky)
    //   LEDR[5]  L2 actively fetching BIOS (30 ms activity extender)
    //   LEDR[4]  50 MHz bitstream heartbeat (~1.5 Hz; no reset, no PLL)
    //   LEDR[3]  CPU executing any OUT (30 ms activity extender)
    //   LEDR[2]  cpu_clk heartbeat, reset-gated (PLL locked + rst released)
    //   LEDR[1]  CPU writing to console ports 0xC000..0xC003 (extender)
    //   LEDR[0]  CPU toggling port 0x378 bit 0 (original LED heartbeat)
    //
    // Legend on a fully-working system:
    //   4 & 2    steady blinking — clocks/PLL OK
    //   6 & 7    ON (sticky) — L2 did reach the BIOS fetch path
    //   5        ON or blinking — L2 currently fetching BIOS
    //   3 & 1    ON/blinking — CPU is doing I/O writes
    //   0        blinking — CPU's LED heartbeat from the ROM
    //
    // Reading failure modes:
    //   6 OFF    → L2 never issued ANY ddram read → fetch unit stuck
    //   7 OFF but 6 ON → L2 fetches but NEVER from BIOS → addr decode?
    //   5 blinks, 3 OFF → CPU fetches but no OUT → decode/execute stuck
    //   3 blinks, 1 & 0 OFF → OUTs happen but not to our ports → decode bug
    //
    // Updated layout — LED_DEBUG[3] and LED_DEBUG[1] now expose memory-write
    // activity, since the OUT / console port paths both require the broken
    // microcode IO path and stay dark. Memory writes (MOV [mem], reg) use
    // the LSQ→L2→DDRAM path which does work.
    assign LED_DEBUG[7] = l2_bios_rd_ever;
    assign LED_DEBUG[6] = l2_any_rd_ever;
    assign LED_DEBUG[5] = bios_active;
    assign LED_DEBUG[4] = clk50_heartbeat[25];
    assign LED_DEBUG[3] = l2_wb_cnt[22];       // slow blink once L2 evicts
    assign LED_DEBUG[2] = cpuclk_heartbeat[24];
    assign LED_DEBUG[1] = l2_wb_ever;          // sticky: ever wrote DDRAM
    assign LED_DEBUG[0] = diag_led_state;      // legacy: CPU→port 0x378

    // Keep the legacy framework paths silent so LED[0/2/4] show exactly
    // what LED_DEBUG drives (sys_top OR's them together; zero is a no-op).
    assign LED_USER  = 1'b0;
    assign LED_POWER = 2'b00;
    assign LED_DISK  = 2'b00;
    assign BUTTONS   = 2'b00;

    // VGA extras
    assign VGA_F1      = 1'b0;     // no interlace
    assign VGA_SL      = 2'b00;    // no scanlines
    assign CE_PIXEL    = 1'b1;     // 1:1 (CLK_VIDEO == pixel rate)
    assign CLK_VIDEO   = pixel_clk;
    assign VIDEO_ARX   = 13'd4;    // 4:3 aspect
    assign VIDEO_ARY   = 13'd3;
    assign VGA_SCALER  = 1'b0;
    assign VGA_DISABLE = 1'b0;

    // HDMI hints unused
    assign HDMI_FREEZE    = 1'b0;
    assign HDMI_BLACKOUT  = 1'b0;
    assign HDMI_BOB_DEINT = 1'b0;

    // SD card unused for now (disk I/O will go through HPS DDRAM)
    assign SD_SCK  = 1'b0;
    assign SD_MOSI = 1'b0;
    assign SD_CS   = 1'b1;

    // User I/O port unused
    assign USER_OUT = 7'h7F;       // open-drain: high => read mode

    // HPS_BUS driven above: by hps_io when MISTER_FULL is defined,
    // otherwise tied high-Z inside the ifdef guard.

    // ADC bus high-Z
    assign ADC_BUS = 4'bzzzz;

    // SDRAM daughterboard unused — drive to idle/high-Z
    assign SDRAM_CLK  = 1'b0;
    assign SDRAM_CKE  = 1'b0;
    assign SDRAM_A    = 13'd0;
    assign SDRAM_BA   = 2'd0;
    assign SDRAM_DQ   = 16'bz;
    assign SDRAM_DQML = 1'b1;
    assign SDRAM_DQMH = 1'b1;
    assign SDRAM_nCS  = 1'b1;      // chip deselect (idle)
    assign SDRAM_nCAS = 1'b1;
    assign SDRAM_nRAS = 1'b1;
    assign SDRAM_nWE  = 1'b1;

    // DDRAM clock follows CPU clock (L2/LSQ already drive DDRAM_* signals)
    assign DDRAM_CLK  = cpu_clk;

    // UART unused
    assign UART_RTS = 1'b0;
    assign UART_TXD = 1'b1;        // idle high
    assign UART_DTR = 1'b0;

    // System reset request (from PS/2 controller command 0xFE)
    // Combine with async RESET from sys_top once framework wiring lands.
    assign sys_reset_req = ps2_sys_reset;

endmodule
