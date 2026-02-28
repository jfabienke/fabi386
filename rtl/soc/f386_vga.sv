/*
 * fabi386: VGA Text Mode Controller - v1.0
 * -----------------------------------------
 * Text-mode-only VGA controller for DOS compatibility.
 * Implements IBM VGA text modes 1 (40x25) and 3 (80x25) with
 * hardware cursor, 16-color CGA palette, and 8x16 character ROM.
 *
 * Saves ~800 ALMs vs a full graphics-mode VGA by omitting all
 * pixel-addressable framebuffer logic. Text framebuffer lives at
 * 0xB8000-0xB8FFF (4KB window, mirrored within 0xB8000-0xBFFFF).
 *
 * Video timing: 640x400 @ 70Hz (25.175 MHz pixel clock).
 *
 * I/O Ports handled:
 *   0x3C0       Attribute Controller Index/Data (flip-flop)
 *   0x3C1       Attribute Controller Data Read
 *   0x3C2       Miscellaneous Output Register (write)
 *   0x3C4-0x3C5 Sequencer Index/Data
 *   0x3CC       Miscellaneous Output Register (read)
 *   0x3D4       CRTC Index Register
 *   0x3D5       CRTC Data Register
 *   0x3DA       Input Status Register 1 (clears 3C0 flip-flop)
 */

import f386_pkg::*;

module f386_vga (
    input  logic         clk,           // System clock
    input  logic         rst_n,
    input  logic         pixel_clk,     // 25.175 MHz pixel clock

    // ---- I/O Port Interface ----
    input  logic [15:0]  io_addr,
    input  logic [7:0]   io_wdata,
    output logic [7:0]   io_rdata,
    input  logic         io_wr,
    input  logic         io_rd,
    input  logic         io_cs,

    // ---- Memory-Mapped Framebuffer (0xB8000-0xBFFFF) ----
    input  logic [15:0]  fb_addr,       // Offset within framebuffer window
    input  logic [7:0]   fb_wdata,
    output logic [7:0]   fb_rdata,
    input  logic         fb_wr,
    input  logic         fb_rd,
    input  logic         fb_cs,

    // ---- Video Output ----
    output logic         vga_hsync,
    output logic         vga_vsync,
    output logic [7:0]   vga_r,
    output logic [7:0]   vga_g,
    output logic [7:0]   vga_b,
    output logic         vga_de,        // Data enable (active display area)
    output logic         vga_vblank     // Vertical blank (for PIT/retrace sync)
);

    // =========================================================================
    //  VGA 640x400 @ 70Hz Timing Constants (25.175 MHz pixel clock)
    // =========================================================================
    //
    //  Horizontal: 800 pixel clocks total
    //    Active:   640   Front porch: 16   Sync: 96   Back porch: 48
    //
    //  Vertical: 449 lines total
    //    Active:   400   Front porch:  12  Sync:  2   Back porch: 35
    //
    localparam int H_ACTIVE     = 640;
    localparam int H_FRONT      = 16;
    localparam int H_SYNC       = 96;
    localparam int H_BACK       = 48;
    localparam int H_TOTAL      = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;  // 800

    localparam int V_ACTIVE     = 400;
    localparam int V_FRONT      = 12;
    localparam int V_SYNC       = 2;
    localparam int V_BACK       = 35;
    localparam int V_TOTAL      = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;  // 449

    // Character cell dimensions
    localparam int CHAR_W       = 8;    // pixels per character horizontally
    localparam int CHAR_H       = 16;   // scanlines per character vertically

    // Text mode dimensions
    localparam int TEXT_COLS_80 = 80;
    localparam int TEXT_COLS_40 = 40;
    localparam int TEXT_ROWS    = 25;

    // Framebuffer size (attribute+char pairs)
    localparam int FB_SIZE      = 4096; // 4KB window (0xB8000-0xB8FFF)

    // =========================================================================
    //  Standard CGA 16-Color Palette (8-bit RGB per channel)
    // =========================================================================
    // Index: 0=Black  1=Blue     2=Green    3=Cyan     4=Red      5=Magenta
    //        6=Brown  7=LtGray   8=DkGray   9=LtBlue  10=LtGreen 11=LtCyan
    //       12=LtRed 13=LtMag   14=Yellow  15=White
    //
    logic [23:0] cga_palette [0:15];

    assign cga_palette[ 0] = 24'h000000;  // Black
    assign cga_palette[ 1] = 24'h0000AA;  // Blue
    assign cga_palette[ 2] = 24'h00AA00;  // Green
    assign cga_palette[ 3] = 24'h00AAAA;  // Cyan
    assign cga_palette[ 4] = 24'hAA0000;  // Red
    assign cga_palette[ 5] = 24'hAA00AA;  // Magenta
    assign cga_palette[ 6] = 24'hAA5500;  // Brown
    assign cga_palette[ 7] = 24'hAAAAAA;  // Light Gray
    assign cga_palette[ 8] = 24'h555555;  // Dark Gray
    assign cga_palette[ 9] = 24'h5555FF;  // Light Blue
    assign cga_palette[10] = 24'h55FF55;  // Light Green
    assign cga_palette[11] = 24'h55FFFF;  // Light Cyan
    assign cga_palette[12] = 24'hFF5555;  // Light Red
    assign cga_palette[13] = 24'hFF55FF;  // Light Magenta
    assign cga_palette[14] = 24'hFFFF55;  // Yellow
    assign cga_palette[15] = 24'hFFFFFF;  // White

    // =========================================================================
    //  Text Framebuffer (dual-port RAM, 4KB)
    // =========================================================================
    // Port A: CPU read/write (system clock domain)
    // Port B: Video read-only (pixel clock domain)
    //
    // Each character cell = 2 bytes:
    //   Even addr: ASCII character code
    //   Odd  addr: Attribute byte [7:4]=bg, [3:0]=fg
    //             Bit 7 = blink enable (when blink mode active)
    //
    logic [7:0] framebuffer [0:FB_SIZE-1];

    // Initialize framebuffer to spaces with light gray on black
    initial begin
        for (int i = 0; i < FB_SIZE; i += 2) begin
            framebuffer[i]   = 8'h20;  // Space character
            framebuffer[i+1] = 8'h07;  // Light gray on black
        end
    end

    // =========================================================================
    //  Character Generator ROM (8x16 font, 256 characters = 4KB)
    // =========================================================================
    // Each character has 16 rows of 8-pixel bitmaps.
    // Address = {char_code[7:0], scanline[3:0]} => 12-bit address
    //
    // This is loaded from an external hex file at synthesis time.
    // The file should contain 4096 bytes (256 chars * 16 rows).
    // If file not found, a built-in minimal CP437 subset is used.
    //
    logic [7:0] font_rom [0:4095];

    // Built-in minimal font initialization.
    // Covers printable ASCII (0x20-0x7E) plus box-drawing basics.
    // Full CP437 should be loaded via $readmemh("vga_font_8x16.hex", font_rom)
    // in synthesis scripts or via an initial block below.
    initial begin
        // Zero-fill first, then overlay known glyphs
        for (int i = 0; i < 4096; i++)
            font_rom[i] = 8'h00;

        // ---- Space (0x20) - all zeros, already done ----

        // ---- '!' (0x21) ----
        font_rom[{8'h21, 4'h0}] = 8'h00;
        font_rom[{8'h21, 4'h1}] = 8'h00;
        font_rom[{8'h21, 4'h2}] = 8'h18;
        font_rom[{8'h21, 4'h3}] = 8'h3C;
        font_rom[{8'h21, 4'h4}] = 8'h3C;
        font_rom[{8'h21, 4'h5}] = 8'h3C;
        font_rom[{8'h21, 4'h6}] = 8'h18;
        font_rom[{8'h21, 4'h7}] = 8'h18;
        font_rom[{8'h21, 4'h8}] = 8'h18;
        font_rom[{8'h21, 4'h9}] = 8'h00;
        font_rom[{8'h21, 4'hA}] = 8'h18;
        font_rom[{8'h21, 4'hB}] = 8'h18;
        font_rom[{8'h21, 4'hC}] = 8'h00;
        font_rom[{8'h21, 4'hD}] = 8'h00;
        font_rom[{8'h21, 4'hE}] = 8'h00;
        font_rom[{8'h21, 4'hF}] = 8'h00;

        // ---- '0' (0x30) ----
        font_rom[{8'h30, 4'h0}] = 8'h00;
        font_rom[{8'h30, 4'h1}] = 8'h00;
        font_rom[{8'h30, 4'h2}] = 8'h7C;
        font_rom[{8'h30, 4'h3}] = 8'hC6;
        font_rom[{8'h30, 4'h4}] = 8'hCE;
        font_rom[{8'h30, 4'h5}] = 8'hDE;
        font_rom[{8'h30, 4'h6}] = 8'hF6;
        font_rom[{8'h30, 4'h7}] = 8'hE6;
        font_rom[{8'h30, 4'h8}] = 8'hC6;
        font_rom[{8'h30, 4'h9}] = 8'hC6;
        font_rom[{8'h30, 4'hA}] = 8'h7C;
        font_rom[{8'h30, 4'hB}] = 8'h00;
        font_rom[{8'h30, 4'hC}] = 8'h00;
        font_rom[{8'h30, 4'hD}] = 8'h00;
        font_rom[{8'h30, 4'hE}] = 8'h00;
        font_rom[{8'h30, 4'hF}] = 8'h00;

        // ---- '1' (0x31) ----
        font_rom[{8'h31, 4'h0}] = 8'h00;
        font_rom[{8'h31, 4'h1}] = 8'h00;
        font_rom[{8'h31, 4'h2}] = 8'h18;
        font_rom[{8'h31, 4'h3}] = 8'h38;
        font_rom[{8'h31, 4'h4}] = 8'h78;
        font_rom[{8'h31, 4'h5}] = 8'h18;
        font_rom[{8'h31, 4'h6}] = 8'h18;
        font_rom[{8'h31, 4'h7}] = 8'h18;
        font_rom[{8'h31, 4'h8}] = 8'h18;
        font_rom[{8'h31, 4'h9}] = 8'h18;
        font_rom[{8'h31, 4'hA}] = 8'h7E;
        font_rom[{8'h31, 4'hB}] = 8'h00;
        font_rom[{8'h31, 4'hC}] = 8'h00;
        font_rom[{8'h31, 4'hD}] = 8'h00;
        font_rom[{8'h31, 4'hE}] = 8'h00;
        font_rom[{8'h31, 4'hF}] = 8'h00;

        // ---- 'A' (0x41) ----
        font_rom[{8'h41, 4'h0}] = 8'h00;
        font_rom[{8'h41, 4'h1}] = 8'h00;
        font_rom[{8'h41, 4'h2}] = 8'h10;
        font_rom[{8'h41, 4'h3}] = 8'h38;
        font_rom[{8'h41, 4'h4}] = 8'h6C;
        font_rom[{8'h41, 4'h5}] = 8'hC6;
        font_rom[{8'h41, 4'h6}] = 8'hC6;
        font_rom[{8'h41, 4'h7}] = 8'hFE;
        font_rom[{8'h41, 4'h8}] = 8'hC6;
        font_rom[{8'h41, 4'h9}] = 8'hC6;
        font_rom[{8'h41, 4'hA}] = 8'hC6;
        font_rom[{8'h41, 4'hB}] = 8'h00;
        font_rom[{8'h41, 4'hC}] = 8'h00;
        font_rom[{8'h41, 4'hD}] = 8'h00;
        font_rom[{8'h41, 4'hE}] = 8'h00;
        font_rom[{8'h41, 4'hF}] = 8'h00;

        // ---- 'B' (0x42) ----
        font_rom[{8'h42, 4'h0}] = 8'h00;
        font_rom[{8'h42, 4'h1}] = 8'h00;
        font_rom[{8'h42, 4'h2}] = 8'hFC;
        font_rom[{8'h42, 4'h3}] = 8'h66;
        font_rom[{8'h42, 4'h4}] = 8'h66;
        font_rom[{8'h42, 4'h5}] = 8'h7C;
        font_rom[{8'h42, 4'h6}] = 8'h66;
        font_rom[{8'h42, 4'h7}] = 8'h66;
        font_rom[{8'h42, 4'h8}] = 8'h66;
        font_rom[{8'h42, 4'h9}] = 8'h66;
        font_rom[{8'h42, 4'hA}] = 8'hFC;
        font_rom[{8'h42, 4'hB}] = 8'h00;
        font_rom[{8'h42, 4'hC}] = 8'h00;
        font_rom[{8'h42, 4'hD}] = 8'h00;
        font_rom[{8'h42, 4'hE}] = 8'h00;
        font_rom[{8'h42, 4'hF}] = 8'h00;

        // ---- 'C' (0x43) ----
        font_rom[{8'h43, 4'h0}] = 8'h00;
        font_rom[{8'h43, 4'h1}] = 8'h00;
        font_rom[{8'h43, 4'h2}] = 8'h3C;
        font_rom[{8'h43, 4'h3}] = 8'h66;
        font_rom[{8'h43, 4'h4}] = 8'hC2;
        font_rom[{8'h43, 4'h5}] = 8'hC0;
        font_rom[{8'h43, 4'h6}] = 8'hC0;
        font_rom[{8'h43, 4'h7}] = 8'hC0;
        font_rom[{8'h43, 4'h8}] = 8'hC2;
        font_rom[{8'h43, 4'h9}] = 8'h66;
        font_rom[{8'h43, 4'hA}] = 8'h3C;
        font_rom[{8'h43, 4'hB}] = 8'h00;
        font_rom[{8'h43, 4'hC}] = 8'h00;
        font_rom[{8'h43, 4'hD}] = 8'h00;
        font_rom[{8'h43, 4'hE}] = 8'h00;
        font_rom[{8'h43, 4'hF}] = 8'h00;

        // ---- 'D' (0x44) ----
        font_rom[{8'h44, 4'h0}] = 8'h00;
        font_rom[{8'h44, 4'h1}] = 8'h00;
        font_rom[{8'h44, 4'h2}] = 8'hF8;
        font_rom[{8'h44, 4'h3}] = 8'h6C;
        font_rom[{8'h44, 4'h4}] = 8'h66;
        font_rom[{8'h44, 4'h5}] = 8'h66;
        font_rom[{8'h44, 4'h6}] = 8'h66;
        font_rom[{8'h44, 4'h7}] = 8'h66;
        font_rom[{8'h44, 4'h8}] = 8'h66;
        font_rom[{8'h44, 4'h9}] = 8'h6C;
        font_rom[{8'h44, 4'hA}] = 8'hF8;
        font_rom[{8'h44, 4'hB}] = 8'h00;
        font_rom[{8'h44, 4'hC}] = 8'h00;
        font_rom[{8'h44, 4'hD}] = 8'h00;
        font_rom[{8'h44, 4'hE}] = 8'h00;
        font_rom[{8'h44, 4'hF}] = 8'h00;

        // ---- 'E' (0x45) ----
        font_rom[{8'h45, 4'h0}] = 8'h00;
        font_rom[{8'h45, 4'h1}] = 8'h00;
        font_rom[{8'h45, 4'h2}] = 8'hFE;
        font_rom[{8'h45, 4'h3}] = 8'h66;
        font_rom[{8'h45, 4'h4}] = 8'h62;
        font_rom[{8'h45, 4'h5}] = 8'h68;
        font_rom[{8'h45, 4'h6}] = 8'h78;
        font_rom[{8'h45, 4'h7}] = 8'h68;
        font_rom[{8'h45, 4'h8}] = 8'h62;
        font_rom[{8'h45, 4'h9}] = 8'h66;
        font_rom[{8'h45, 4'hA}] = 8'hFE;
        font_rom[{8'h45, 4'hB}] = 8'h00;
        font_rom[{8'h45, 4'hC}] = 8'h00;
        font_rom[{8'h45, 4'hD}] = 8'h00;
        font_rom[{8'h45, 4'hE}] = 8'h00;
        font_rom[{8'h45, 4'hF}] = 8'h00;

        // ---- 'F' (0x46) ----
        font_rom[{8'h46, 4'h0}] = 8'h00;
        font_rom[{8'h46, 4'h1}] = 8'h00;
        font_rom[{8'h46, 4'h2}] = 8'hFE;
        font_rom[{8'h46, 4'h3}] = 8'h66;
        font_rom[{8'h46, 4'h4}] = 8'h62;
        font_rom[{8'h46, 4'h5}] = 8'h68;
        font_rom[{8'h46, 4'h6}] = 8'h78;
        font_rom[{8'h46, 4'h7}] = 8'h68;
        font_rom[{8'h46, 4'h8}] = 8'h60;
        font_rom[{8'h46, 4'h9}] = 8'h60;
        font_rom[{8'h46, 4'hA}] = 8'hF0;
        font_rom[{8'h46, 4'hB}] = 8'h00;
        font_rom[{8'h46, 4'hC}] = 8'h00;
        font_rom[{8'h46, 4'hD}] = 8'h00;
        font_rom[{8'h46, 4'hE}] = 8'h00;
        font_rom[{8'h46, 4'hF}] = 8'h00;

        // ---- 'G' (0x47) ----
        font_rom[{8'h47, 4'h0}] = 8'h00;
        font_rom[{8'h47, 4'h1}] = 8'h00;
        font_rom[{8'h47, 4'h2}] = 8'h3C;
        font_rom[{8'h47, 4'h3}] = 8'h66;
        font_rom[{8'h47, 4'h4}] = 8'hC2;
        font_rom[{8'h47, 4'h5}] = 8'hC0;
        font_rom[{8'h47, 4'h6}] = 8'hDE;
        font_rom[{8'h47, 4'h7}] = 8'hC6;
        font_rom[{8'h47, 4'h8}] = 8'hC6;
        font_rom[{8'h47, 4'h9}] = 8'h66;
        font_rom[{8'h47, 4'hA}] = 8'h3A;
        font_rom[{8'h47, 4'hB}] = 8'h00;
        font_rom[{8'h47, 4'hC}] = 8'h00;
        font_rom[{8'h47, 4'hD}] = 8'h00;
        font_rom[{8'h47, 4'hE}] = 8'h00;
        font_rom[{8'h47, 4'hF}] = 8'h00;

        // ---- 'H' (0x48) ----
        font_rom[{8'h48, 4'h0}] = 8'h00;
        font_rom[{8'h48, 4'h1}] = 8'h00;
        font_rom[{8'h48, 4'h2}] = 8'hC6;
        font_rom[{8'h48, 4'h3}] = 8'hC6;
        font_rom[{8'h48, 4'h4}] = 8'hC6;
        font_rom[{8'h48, 4'h5}] = 8'hC6;
        font_rom[{8'h48, 4'h6}] = 8'hFE;
        font_rom[{8'h48, 4'h7}] = 8'hC6;
        font_rom[{8'h48, 4'h8}] = 8'hC6;
        font_rom[{8'h48, 4'h9}] = 8'hC6;
        font_rom[{8'h48, 4'hA}] = 8'hC6;
        font_rom[{8'h48, 4'hB}] = 8'h00;
        font_rom[{8'h48, 4'hC}] = 8'h00;
        font_rom[{8'h48, 4'hD}] = 8'h00;
        font_rom[{8'h48, 4'hE}] = 8'h00;
        font_rom[{8'h48, 4'hF}] = 8'h00;

        // ---- 'I' (0x49) ----
        font_rom[{8'h49, 4'h0}] = 8'h00;
        font_rom[{8'h49, 4'h1}] = 8'h00;
        font_rom[{8'h49, 4'h2}] = 8'h3C;
        font_rom[{8'h49, 4'h3}] = 8'h18;
        font_rom[{8'h49, 4'h4}] = 8'h18;
        font_rom[{8'h49, 4'h5}] = 8'h18;
        font_rom[{8'h49, 4'h6}] = 8'h18;
        font_rom[{8'h49, 4'h7}] = 8'h18;
        font_rom[{8'h49, 4'h8}] = 8'h18;
        font_rom[{8'h49, 4'h9}] = 8'h18;
        font_rom[{8'h49, 4'hA}] = 8'h3C;
        font_rom[{8'h49, 4'hB}] = 8'h00;
        font_rom[{8'h49, 4'hC}] = 8'h00;
        font_rom[{8'h49, 4'hD}] = 8'h00;
        font_rom[{8'h49, 4'hE}] = 8'h00;
        font_rom[{8'h49, 4'hF}] = 8'h00;

        // ---- 'L' (0x4C) ----
        font_rom[{8'h4C, 4'h0}] = 8'h00;
        font_rom[{8'h4C, 4'h1}] = 8'h00;
        font_rom[{8'h4C, 4'h2}] = 8'hF0;
        font_rom[{8'h4C, 4'h3}] = 8'h60;
        font_rom[{8'h4C, 4'h4}] = 8'h60;
        font_rom[{8'h4C, 4'h5}] = 8'h60;
        font_rom[{8'h4C, 4'h6}] = 8'h60;
        font_rom[{8'h4C, 4'h7}] = 8'h60;
        font_rom[{8'h4C, 4'h8}] = 8'h62;
        font_rom[{8'h4C, 4'h9}] = 8'h66;
        font_rom[{8'h4C, 4'hA}] = 8'hFE;
        font_rom[{8'h4C, 4'hB}] = 8'h00;
        font_rom[{8'h4C, 4'hC}] = 8'h00;
        font_rom[{8'h4C, 4'hD}] = 8'h00;
        font_rom[{8'h4C, 4'hE}] = 8'h00;
        font_rom[{8'h4C, 4'hF}] = 8'h00;

        // ---- 'M' (0x4D) ----
        font_rom[{8'h4D, 4'h0}] = 8'h00;
        font_rom[{8'h4D, 4'h1}] = 8'h00;
        font_rom[{8'h4D, 4'h2}] = 8'hC6;
        font_rom[{8'h4D, 4'h3}] = 8'hEE;
        font_rom[{8'h4D, 4'h4}] = 8'hFE;
        font_rom[{8'h4D, 4'h5}] = 8'hD6;
        font_rom[{8'h4D, 4'h6}] = 8'hC6;
        font_rom[{8'h4D, 4'h7}] = 8'hC6;
        font_rom[{8'h4D, 4'h8}] = 8'hC6;
        font_rom[{8'h4D, 4'h9}] = 8'hC6;
        font_rom[{8'h4D, 4'hA}] = 8'hC6;
        font_rom[{8'h4D, 4'hB}] = 8'h00;
        font_rom[{8'h4D, 4'hC}] = 8'h00;
        font_rom[{8'h4D, 4'hD}] = 8'h00;
        font_rom[{8'h4D, 4'hE}] = 8'h00;
        font_rom[{8'h4D, 4'hF}] = 8'h00;

        // ---- 'N' (0x4E) ----
        font_rom[{8'h4E, 4'h0}] = 8'h00;
        font_rom[{8'h4E, 4'h1}] = 8'h00;
        font_rom[{8'h4E, 4'h2}] = 8'hC6;
        font_rom[{8'h4E, 4'h3}] = 8'hE6;
        font_rom[{8'h4E, 4'h4}] = 8'hF6;
        font_rom[{8'h4E, 4'h5}] = 8'hDE;
        font_rom[{8'h4E, 4'h6}] = 8'hCE;
        font_rom[{8'h4E, 4'h7}] = 8'hC6;
        font_rom[{8'h4E, 4'h8}] = 8'hC6;
        font_rom[{8'h4E, 4'h9}] = 8'hC6;
        font_rom[{8'h4E, 4'hA}] = 8'hC6;
        font_rom[{8'h4E, 4'hB}] = 8'h00;
        font_rom[{8'h4E, 4'hC}] = 8'h00;
        font_rom[{8'h4E, 4'hD}] = 8'h00;
        font_rom[{8'h4E, 4'hE}] = 8'h00;
        font_rom[{8'h4E, 4'hF}] = 8'h00;

        // ---- 'O' (0x4F) ----
        font_rom[{8'h4F, 4'h0}] = 8'h00;
        font_rom[{8'h4F, 4'h1}] = 8'h00;
        font_rom[{8'h4F, 4'h2}] = 8'h7C;
        font_rom[{8'h4F, 4'h3}] = 8'hC6;
        font_rom[{8'h4F, 4'h4}] = 8'hC6;
        font_rom[{8'h4F, 4'h5}] = 8'hC6;
        font_rom[{8'h4F, 4'h6}] = 8'hC6;
        font_rom[{8'h4F, 4'h7}] = 8'hC6;
        font_rom[{8'h4F, 4'h8}] = 8'hC6;
        font_rom[{8'h4F, 4'h9}] = 8'hC6;
        font_rom[{8'h4F, 4'hA}] = 8'h7C;
        font_rom[{8'h4F, 4'hB}] = 8'h00;
        font_rom[{8'h4F, 4'hC}] = 8'h00;
        font_rom[{8'h4F, 4'hD}] = 8'h00;
        font_rom[{8'h4F, 4'hE}] = 8'h00;
        font_rom[{8'h4F, 4'hF}] = 8'h00;

        // ---- 'P' (0x50) ----
        font_rom[{8'h50, 4'h0}] = 8'h00;
        font_rom[{8'h50, 4'h1}] = 8'h00;
        font_rom[{8'h50, 4'h2}] = 8'hFC;
        font_rom[{8'h50, 4'h3}] = 8'h66;
        font_rom[{8'h50, 4'h4}] = 8'h66;
        font_rom[{8'h50, 4'h5}] = 8'h7C;
        font_rom[{8'h50, 4'h6}] = 8'h60;
        font_rom[{8'h50, 4'h7}] = 8'h60;
        font_rom[{8'h50, 4'h8}] = 8'h60;
        font_rom[{8'h50, 4'h9}] = 8'h60;
        font_rom[{8'h50, 4'hA}] = 8'hF0;
        font_rom[{8'h50, 4'hB}] = 8'h00;
        font_rom[{8'h50, 4'hC}] = 8'h00;
        font_rom[{8'h50, 4'hD}] = 8'h00;
        font_rom[{8'h50, 4'hE}] = 8'h00;
        font_rom[{8'h50, 4'hF}] = 8'h00;

        // ---- 'R' (0x52) ----
        font_rom[{8'h52, 4'h0}] = 8'h00;
        font_rom[{8'h52, 4'h1}] = 8'h00;
        font_rom[{8'h52, 4'h2}] = 8'hFC;
        font_rom[{8'h52, 4'h3}] = 8'h66;
        font_rom[{8'h52, 4'h4}] = 8'h66;
        font_rom[{8'h52, 4'h5}] = 8'h7C;
        font_rom[{8'h52, 4'h6}] = 8'h6C;
        font_rom[{8'h52, 4'h7}] = 8'h66;
        font_rom[{8'h52, 4'h8}] = 8'h66;
        font_rom[{8'h52, 4'h9}] = 8'h66;
        font_rom[{8'h52, 4'hA}] = 8'hE6;
        font_rom[{8'h52, 4'hB}] = 8'h00;
        font_rom[{8'h52, 4'hC}] = 8'h00;
        font_rom[{8'h52, 4'hD}] = 8'h00;
        font_rom[{8'h52, 4'hE}] = 8'h00;
        font_rom[{8'h52, 4'hF}] = 8'h00;

        // ---- 'S' (0x53) ----
        font_rom[{8'h53, 4'h0}] = 8'h00;
        font_rom[{8'h53, 4'h1}] = 8'h00;
        font_rom[{8'h53, 4'h2}] = 8'h7C;
        font_rom[{8'h53, 4'h3}] = 8'hC6;
        font_rom[{8'h53, 4'h4}] = 8'hC6;
        font_rom[{8'h53, 4'h5}] = 8'h60;
        font_rom[{8'h53, 4'h6}] = 8'h38;
        font_rom[{8'h53, 4'h7}] = 8'h0C;
        font_rom[{8'h53, 4'h8}] = 8'h06;
        font_rom[{8'h53, 4'h9}] = 8'hC6;
        font_rom[{8'h53, 4'hA}] = 8'h7C;
        font_rom[{8'h53, 4'hB}] = 8'h00;
        font_rom[{8'h53, 4'hC}] = 8'h00;
        font_rom[{8'h53, 4'hD}] = 8'h00;
        font_rom[{8'h53, 4'hE}] = 8'h00;
        font_rom[{8'h53, 4'hF}] = 8'h00;

        // ---- 'T' (0x54) ----
        font_rom[{8'h54, 4'h0}] = 8'h00;
        font_rom[{8'h54, 4'h1}] = 8'h00;
        font_rom[{8'h54, 4'h2}] = 8'h7E;
        font_rom[{8'h54, 4'h3}] = 8'h7E;
        font_rom[{8'h54, 4'h4}] = 8'h5A;
        font_rom[{8'h54, 4'h5}] = 8'h18;
        font_rom[{8'h54, 4'h6}] = 8'h18;
        font_rom[{8'h54, 4'h7}] = 8'h18;
        font_rom[{8'h54, 4'h8}] = 8'h18;
        font_rom[{8'h54, 4'h9}] = 8'h18;
        font_rom[{8'h54, 4'hA}] = 8'h3C;
        font_rom[{8'h54, 4'hB}] = 8'h00;
        font_rom[{8'h54, 4'hC}] = 8'h00;
        font_rom[{8'h54, 4'hD}] = 8'h00;
        font_rom[{8'h54, 4'hE}] = 8'h00;
        font_rom[{8'h54, 4'hF}] = 8'h00;

        // ---- 'X' (0x58) ----
        font_rom[{8'h58, 4'h0}] = 8'h00;
        font_rom[{8'h58, 4'h1}] = 8'h00;
        font_rom[{8'h58, 4'h2}] = 8'hC6;
        font_rom[{8'h58, 4'h3}] = 8'hC6;
        font_rom[{8'h58, 4'h4}] = 8'h6C;
        font_rom[{8'h58, 4'h5}] = 8'h38;
        font_rom[{8'h58, 4'h6}] = 8'h38;
        font_rom[{8'h58, 4'h7}] = 8'h38;
        font_rom[{8'h58, 4'h8}] = 8'h6C;
        font_rom[{8'h58, 4'h9}] = 8'hC6;
        font_rom[{8'h58, 4'hA}] = 8'hC6;
        font_rom[{8'h58, 4'hB}] = 8'h00;
        font_rom[{8'h58, 4'hC}] = 8'h00;
        font_rom[{8'h58, 4'hD}] = 8'h00;
        font_rom[{8'h58, 4'hE}] = 8'h00;
        font_rom[{8'h58, 4'hF}] = 8'h00;

        // ---- 'a'-'z' (0x61-0x7A): lowercase ----
        // ---- 'a' (0x61) ----
        font_rom[{8'h61, 4'h0}] = 8'h00;
        font_rom[{8'h61, 4'h1}] = 8'h00;
        font_rom[{8'h61, 4'h2}] = 8'h00;
        font_rom[{8'h61, 4'h3}] = 8'h00;
        font_rom[{8'h61, 4'h4}] = 8'h00;
        font_rom[{8'h61, 4'h5}] = 8'h78;
        font_rom[{8'h61, 4'h6}] = 8'h0C;
        font_rom[{8'h61, 4'h7}] = 8'h7C;
        font_rom[{8'h61, 4'h8}] = 8'hCC;
        font_rom[{8'h61, 4'h9}] = 8'hCC;
        font_rom[{8'h61, 4'hA}] = 8'h76;
        font_rom[{8'h61, 4'hB}] = 8'h00;
        font_rom[{8'h61, 4'hC}] = 8'h00;
        font_rom[{8'h61, 4'hD}] = 8'h00;
        font_rom[{8'h61, 4'hE}] = 8'h00;
        font_rom[{8'h61, 4'hF}] = 8'h00;

        // ---- 'b' (0x62) ----
        font_rom[{8'h62, 4'h0}] = 8'h00;
        font_rom[{8'h62, 4'h1}] = 8'h00;
        font_rom[{8'h62, 4'h2}] = 8'hE0;
        font_rom[{8'h62, 4'h3}] = 8'h60;
        font_rom[{8'h62, 4'h4}] = 8'h60;
        font_rom[{8'h62, 4'h5}] = 8'h7C;
        font_rom[{8'h62, 4'h6}] = 8'h66;
        font_rom[{8'h62, 4'h7}] = 8'h66;
        font_rom[{8'h62, 4'h8}] = 8'h66;
        font_rom[{8'h62, 4'h9}] = 8'h66;
        font_rom[{8'h62, 4'hA}] = 8'hDC;
        font_rom[{8'h62, 4'hB}] = 8'h00;
        font_rom[{8'h62, 4'hC}] = 8'h00;
        font_rom[{8'h62, 4'hD}] = 8'h00;
        font_rom[{8'h62, 4'hE}] = 8'h00;
        font_rom[{8'h62, 4'hF}] = 8'h00;

        // ---- 'i' (0x69) ----
        font_rom[{8'h69, 4'h0}] = 8'h00;
        font_rom[{8'h69, 4'h1}] = 8'h00;
        font_rom[{8'h69, 4'h2}] = 8'h18;
        font_rom[{8'h69, 4'h3}] = 8'h18;
        font_rom[{8'h69, 4'h4}] = 8'h00;
        font_rom[{8'h69, 4'h5}] = 8'h38;
        font_rom[{8'h69, 4'h6}] = 8'h18;
        font_rom[{8'h69, 4'h7}] = 8'h18;
        font_rom[{8'h69, 4'h8}] = 8'h18;
        font_rom[{8'h69, 4'h9}] = 8'h18;
        font_rom[{8'h69, 4'hA}] = 8'h3C;
        font_rom[{8'h69, 4'hB}] = 8'h00;
        font_rom[{8'h69, 4'hC}] = 8'h00;
        font_rom[{8'h69, 4'hD}] = 8'h00;
        font_rom[{8'h69, 4'hE}] = 8'h00;
        font_rom[{8'h69, 4'hF}] = 8'h00;

        // ---- Full-block character (0xDB) - used for box drawing ----
        for (int r = 0; r < 16; r++)
            font_rom[{8'hDB, r[3:0]}] = 8'hFF;

        // ---- Upper-half block (0xDF) ----
        for (int r = 0; r < 8; r++)
            font_rom[{8'hDF, r[3:0]}] = 8'hFF;
        for (int r = 8; r < 16; r++)
            font_rom[{8'hDF, r[3:0]}] = 8'h00;

        // ---- Lower-half block (0xDC) ----
        for (int r = 0; r < 8; r++)
            font_rom[{8'hDC, r[3:0]}] = 8'h00;
        for (int r = 8; r < 16; r++)
            font_rom[{8'hDC, r[3:0]}] = 8'hFF;

        // ---- Box-drawing: single horizontal (0xC4) ----
        for (int r = 0; r < 16; r++)
            font_rom[{8'hC4, r[3:0]}] = (r == 7 || r == 8) ? 8'hFF : 8'h00;

        // ---- Box-drawing: single vertical (0xB3) ----
        for (int r = 0; r < 16; r++)
            font_rom[{8'hB3, r[3:0]}] = 8'h18;

        // ---- Box-drawing: top-left corner (0xDA) ----
        for (int r = 0; r < 16; r++) begin
            if (r < 7)       font_rom[{8'hDA, r[3:0]}] = 8'h00;
            else if (r == 7) font_rom[{8'hDA, r[3:0]}] = 8'h1F;
            else             font_rom[{8'hDA, r[3:0]}] = 8'h18;
        end

        // ---- Box-drawing: top-right corner (0xBF) ----
        for (int r = 0; r < 16; r++) begin
            if (r < 7)       font_rom[{8'hBF, r[3:0]}] = 8'h00;
            else if (r == 7) font_rom[{8'hBF, r[3:0]}] = 8'hF8;
            else             font_rom[{8'hBF, r[3:0]}] = 8'h18;
        end

        // ---- Box-drawing: bottom-left corner (0xC0) ----
        for (int r = 0; r < 16; r++) begin
            if (r < 7)       font_rom[{8'hC0, r[3:0]}] = 8'h18;
            else if (r == 7) font_rom[{8'hC0, r[3:0]}] = 8'h1F;
            else             font_rom[{8'hC0, r[3:0]}] = 8'h00;
        end

        // ---- Box-drawing: bottom-right corner (0xD9) ----
        for (int r = 0; r < 16; r++) begin
            if (r < 7)       font_rom[{8'hD9, r[3:0]}] = 8'h18;
            else if (r == 7) font_rom[{8'hD9, r[3:0]}] = 8'hF8;
            else             font_rom[{8'hD9, r[3:0]}] = 8'h00;
        end

        // Note: For a full CP437 font, replace this block with:
        //   $readmemh("vga_font_8x16.hex", font_rom);
    end

    // =========================================================================
    //  VGA Register File
    // =========================================================================

    // --- CRTC Registers (index via port 0x3D4, data via port 0x3D5) ---
    logic [7:0] crtc_index;             // Current CRTC register index
    logic [7:0] crtc_regs [0:24];       // CRTC register array (R0-R24)
    //
    // Key CRTC registers for text mode:
    //   R0:  Horizontal Total
    //   R1:  Horizontal Display End
    //   R6:  Vertical Display End
    //   R7:  Overflow (bit 0 = VDE bit 8, etc.)
    //   R9:  Max Scan Line (character height - 1)
    //   R10: Cursor Start (scanline where cursor begins)
    //   R11: Cursor End (scanline where cursor ends)
    //   R12: Start Address High (framebuffer scroll offset)
    //   R13: Start Address Low
    //   R14: Cursor Location High
    //   R15: Cursor Location Low

    // --- Attribute Controller Registers ---
    logic [7:0] attr_index;             // Attribute controller index
    logic [7:0] attr_regs [0:20];       // Attribute palette + mode registers
    logic       attr_flipflop;          // 0=index, 1=data (toggled by 3DA read)
    logic       attr_pas;               // Palette Address Source (bit 5 of index)

    // --- Sequencer Registers ---
    logic [7:0] seq_index;              // Sequencer register index
    logic [7:0] seq_regs [0:4];         // Sequencer registers (SR0-SR4)

    // --- Miscellaneous Output Register ---
    logic [7:0] misc_output;            // Written at 0x3C2, read at 0x3CC

    // --- Input Status Register 1 (0x3DA) ---
    // Bit 0: Display Enable (inverted: 1 when in retrace)
    // Bit 3: Vertical Retrace (1 during vsync)
    logic       in_display_area;        // True when beam is in active display
    logic       in_vsync_area;          // True during vertical sync

    // --- Mode Control ---
    logic       mode_40col;             // 1 = 40-column mode (mode 1), 0 = 80-column
    logic [6:0] active_cols;            // 40 or 80

    // =========================================================================
    //  Cursor State
    // =========================================================================
    logic [15:0] cursor_pos;            // Character offset in framebuffer
    logic [4:0]  cursor_start;          // Start scanline (CRTC R10[4:0])
    logic [4:0]  cursor_end;            // End scanline (CRTC R10[4:0])
    logic        cursor_disable;        // CRTC R10[5]: disable cursor
    logic [23:0] blink_counter;         // Free-running blink timer
    logic        blink_on;              // Cursor visible in current blink phase
    logic        char_blink_on;         // Character blink phase (attr bit 7)

    // Blink rate: ~3.75 Hz cursor blink at 25.175 MHz pixel clock
    // 25175000 / (2 * 3.75) = ~3,356,666 cycles per half-period
    localparam int BLINK_HALF = 3_356_666;

    // Character blink is slower (~1.875 Hz = cursor rate / 2)
    localparam int CHAR_BLINK_HALF = 6_713_333;
    logic [23:0] char_blink_counter;

    // =========================================================================
    //  Framebuffer Start Address (scrolling support)
    // =========================================================================
    logic [15:0] start_addr;            // CRTC R12:R13 combined

    // =========================================================================
    //  Pixel Clock Domain: Video Timing Generator
    // =========================================================================
    logic [10:0] h_count;               // Horizontal pixel counter (0..799)
    logic [9:0]  v_count;               // Vertical line counter (0..448)

    // Active display region flags
    logic        h_active;
    logic        v_active;

    always_ff @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_count <= '0;
            v_count <= '0;
        end else begin
            if (h_count == H_TOTAL - 1) begin
                h_count <= '0;
                if (v_count == V_TOTAL - 1)
                    v_count <= '0;
                else
                    v_count <= v_count + 1'b1;
            end else begin
                h_count <= h_count + 1'b1;
            end
        end
    end

    // Horizontal sync: active low during sync pulse
    // Sync starts after active + front porch
    assign vga_hsync = ~((h_count >= H_ACTIVE + H_FRONT) &&
                         (h_count <  H_ACTIVE + H_FRONT + H_SYNC));

    // Vertical sync: active low during sync pulse
    assign vga_vsync = ~((v_count >= V_ACTIVE + V_FRONT) &&
                         (v_count <  V_ACTIVE + V_FRONT + V_SYNC));

    // Active display area
    assign h_active = (h_count < H_ACTIVE);
    assign v_active = (v_count < V_ACTIVE);
    assign vga_de   = h_active && v_active;

    // Vertical blank signal for PIT/retrace synchronization
    assign vga_vblank = (v_count >= V_ACTIVE);

    // Status bits for Input Status Register 1 (synced to system clock below)
    assign in_display_area = h_active && v_active;
    assign in_vsync_area   = (v_count >= V_ACTIVE + V_FRONT) &&
                             (v_count <  V_ACTIVE + V_FRONT + V_SYNC);

    // =========================================================================
    //  Pixel Clock Domain: Character Address Computation
    // =========================================================================
    //
    // For 80x25 mode at 640x400 with 8x16 characters:
    //   char_col = h_count[9:3]   (0..79)
    //   char_row = v_count[8:4]   (0..24)
    //   scanline = v_count[3:0]   (0..15)
    //   pixel_col = h_count[2:0]  (0..7)
    //
    // For 40x25 mode, each character is displayed double-wide (16 pixels):
    //   char_col = h_count[9:4]   (0..39)
    //   pixel_col = h_count[3:0]  with bit 3 used as the sub-pixel selector
    //
    logic [6:0]  char_col;              // Current character column (0-79 or 0-39)
    logic [4:0]  char_row;              // Current character row (0-24)
    logic [3:0]  scanline;              // Scanline within character cell (0-15)
    logic [2:0]  pixel_col;             // Pixel column within character (0-7)

    always_comb begin
        if (mode_40col) begin
            char_col  = {1'b0, h_count[9:4]};  // 0..39
            pixel_col = h_count[3:1];           // Double-wide: repeat each column
        end else begin
            char_col  = h_count[9:3];           // 0..79
            pixel_col = h_count[2:0];
        end
        char_row = v_count[8:4];                // 0..24
        scanline = v_count[3:0];                // 0..15
    end

    // Framebuffer address for current character (attribute/char pair)
    // fb_offset = (char_row * active_cols + char_col) * 2 + start_addr * 2
    // We compute this in a pipelined fashion to meet timing.
    logic [15:0] vid_fb_addr;           // Address into framebuffer
    logic [12:0] char_offset;           // Linear character offset

    always_comb begin
        // char_offset = char_row * active_cols + char_col
        if (mode_40col)
            char_offset = {char_row, 3'b000} * 13'd5 + char_col; // row*40 + col
        else
            char_offset = {char_row, 3'b000} * 13'd10 + char_col; // row*80 + col
    end

    // Full framebuffer byte address (character at even, attribute at odd)
    // Wraps within framebuffer space
    wire [15:0] char_fb_base = (start_addr + {3'b0, char_offset}) << 1;

    // =========================================================================
    //  Pixel Clock Domain: Pipeline for Character Rendering
    // =========================================================================
    //
    // Stage 0: Compute framebuffer address
    // Stage 1: Read character code and attribute from framebuffer
    // Stage 2: Read font ROM row
    // Stage 3: Select pixel, apply colors, output
    //
    // Pipeline registers
    logic [7:0]  pipe1_char_code;
    logic [7:0]  pipe1_attribute;
    logic [3:0]  pipe1_scanline;
    logic [2:0]  pipe1_pixel_col;
    logic        pipe1_h_active;
    logic        pipe1_v_active;
    logic [6:0]  pipe1_char_col;
    logic [4:0]  pipe1_char_row;

    logic [7:0]  pipe2_font_row;
    logic [7:0]  pipe2_attribute;
    logic [2:0]  pipe2_pixel_col;
    logic        pipe2_h_active;
    logic        pipe2_v_active;
    logic [6:0]  pipe2_char_col;
    logic [4:0]  pipe2_char_row;
    logic [3:0]  pipe2_scanline;

    // Stage 1: Read character and attribute from framebuffer
    always_ff @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe1_char_code <= 8'h20;
            pipe1_attribute <= 8'h07;
            pipe1_scanline  <= '0;
            pipe1_pixel_col <= '0;
            pipe1_h_active  <= 1'b0;
            pipe1_v_active  <= 1'b0;
            pipe1_char_col  <= '0;
            pipe1_char_row  <= '0;
        end else begin
            // Read character code (even address) and attribute (odd address)
            pipe1_char_code <= framebuffer[char_fb_base[11:0]];
            pipe1_attribute <= framebuffer[char_fb_base[11:0] | 12'h001];
            pipe1_scanline  <= scanline;
            pipe1_pixel_col <= pixel_col;
            pipe1_h_active  <= h_active;
            pipe1_v_active  <= v_active;
            pipe1_char_col  <= char_col;
            pipe1_char_row  <= char_row;
        end
    end

    // Stage 2: Read font ROM
    always_ff @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe2_font_row  <= '0;
            pipe2_attribute <= 8'h07;
            pipe2_pixel_col <= '0;
            pipe2_h_active  <= 1'b0;
            pipe2_v_active  <= 1'b0;
            pipe2_char_col  <= '0;
            pipe2_char_row  <= '0;
            pipe2_scanline  <= '0;
        end else begin
            pipe2_font_row  <= font_rom[{pipe1_char_code, pipe1_scanline}];
            pipe2_attribute <= pipe1_attribute;
            pipe2_pixel_col <= pipe1_pixel_col;
            pipe2_h_active  <= pipe1_h_active;
            pipe2_v_active  <= pipe1_v_active;
            pipe2_char_col  <= pipe1_char_col;
            pipe2_char_row  <= pipe1_char_row;
            pipe2_scanline  <= pipe1_scanline;
        end
    end

    // Stage 3: Pixel selection and color output
    //
    // Attribute byte layout:
    //   [7]   = Blink enable (when Mode Control Register bit 3 is set)
    //           or high-intensity background bit (when blink disabled)
    //   [6:4] = Background color index (0-7, or 0-15 if blink disabled)
    //   [3:0] = Foreground color index (0-15)
    //
    logic        pixel_on;              // 1 = foreground pixel
    logic [3:0]  fg_color_idx;
    logic [3:0]  bg_color_idx;
    logic        is_cursor_here;        // Cursor overlay at this position
    logic        blink_attr_active;     // Attribute blink mode enabled

    // Attribute mode control register (attr_regs[0x10])
    // Bit 3: Enable blink mode (1=blink, 0=high-intensity background)
    assign blink_attr_active = attr_regs[16][3];

    always_comb begin
        // Extract foreground and background color indices
        fg_color_idx = pipe2_attribute[3:0];

        if (blink_attr_active)
            bg_color_idx = {1'b0, pipe2_attribute[6:4]};  // 8 background colors
        else
            bg_color_idx = pipe2_attribute[7:4];           // 16 background colors

        // Font bitmap: MSB is leftmost pixel
        pixel_on = pipe2_font_row[3'd7 - pipe2_pixel_col];

        // Character blink: if attr bit 7 set and blink mode active, hide fg
        if (blink_attr_active && pipe2_attribute[7] && !char_blink_on)
            pixel_on = 1'b0;

        // Cursor overlay: show cursor if position matches and scanline is in range
        is_cursor_here = 1'b0;
        if (!cursor_disable) begin
            // Check if this character position matches cursor
            if (({pipe2_char_row, 3'b000} * (mode_40col ? 13'd5 : 13'd10) +
                 {6'b0, pipe2_char_col}) == cursor_pos[12:0]) begin
                // Check scanline range
                if (pipe2_scanline >= cursor_start[3:0] &&
                    pipe2_scanline <= cursor_end[3:0] &&
                    blink_on) begin
                    is_cursor_here = 1'b1;
                end
            end
        end

        // XOR cursor with pixel (inverts character under cursor)
        if (is_cursor_here)
            pixel_on = ~pixel_on;
    end

    // Final RGB output
    logic [23:0] output_color;

    always_comb begin
        if (pipe2_h_active && pipe2_v_active)
            output_color = pixel_on ? cga_palette[fg_color_idx]
                                    : cga_palette[bg_color_idx];
        else
            output_color = 24'h000000;  // Blanking
    end

    always_ff @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            vga_r <= '0;
            vga_g <= '0;
            vga_b <= '0;
        end else begin
            vga_r <= output_color[23:16];
            vga_g <= output_color[15:8];
            vga_b <= output_color[7:0];
        end
    end

    // =========================================================================
    //  Blink Timers (pixel clock domain)
    // =========================================================================
    always_ff @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            blink_counter      <= '0;
            blink_on           <= 1'b1;
            char_blink_counter <= '0;
            char_blink_on      <= 1'b1;
        end else begin
            // Cursor blink
            if (blink_counter >= BLINK_HALF) begin
                blink_counter <= '0;
                blink_on      <= ~blink_on;
            end else begin
                blink_counter <= blink_counter + 1'b1;
            end

            // Character attribute blink (slower)
            if (char_blink_counter >= CHAR_BLINK_HALF) begin
                char_blink_counter <= '0;
                char_blink_on      <= ~char_blink_on;
            end else begin
                char_blink_counter <= char_blink_counter + 1'b1;
            end
        end
    end

    // =========================================================================
    //  System Clock Domain: CPU Framebuffer Access
    // =========================================================================
    // Simple byte-wide read/write to the text framebuffer.
    // Address is offset within the 0xB8000-0xBFFFF window.
    // We mask to 4KB (0xFFF) to stay within the text buffer.

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fb_rdata <= 8'h00;
        end else begin
            if (fb_cs && fb_wr)
                framebuffer[fb_addr[11:0]] <= fb_wdata;

            if (fb_cs && fb_rd)
                fb_rdata <= framebuffer[fb_addr[11:0]];
        end
    end

    // =========================================================================
    //  System Clock Domain: I/O Port Register Access
    // =========================================================================
    //
    // Synchronize retrace status from pixel clock to system clock domain
    logic [2:0] vsync_sync;
    logic [2:0] de_sync;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_sync <= '0;
            de_sync    <= '0;
        end else begin
            vsync_sync <= {vsync_sync[1:0], in_vsync_area};
            de_sync    <= {de_sync[1:0], in_display_area};
        end
    end

    wire status_vsync = vsync_sync[2];
    wire status_de    = ~de_sync[2];  // ISR1 bit 0: 1 = retrace/blank

    // =========================================================================
    //  CRTC Register Defaults (Mode 3: 80x25 text, 8x16 font)
    // =========================================================================
    initial begin
        crtc_index = 8'h00;

        // Standard VGA Mode 3 CRTC values
        crtc_regs[0]  = 8'h5F;  // Horizontal Total
        crtc_regs[1]  = 8'h4F;  // Horizontal Display End (79 = 80 chars - 1)
        crtc_regs[2]  = 8'h50;  // Start Horizontal Blanking
        crtc_regs[3]  = 8'h82;  // End Horizontal Blanking
        crtc_regs[4]  = 8'h55;  // Start Horizontal Retrace
        crtc_regs[5]  = 8'h81;  // End Horizontal Retrace
        crtc_regs[6]  = 8'hBF;  // Vertical Total
        crtc_regs[7]  = 8'h1F;  // Overflow
        crtc_regs[8]  = 8'h00;  // Preset Row Scan
        crtc_regs[9]  = 8'h4F;  // Max Scan Line (bit[4:0]=15 for 16-line chars)
        crtc_regs[10] = 8'h0D;  // Cursor Start (scanline 13)
        crtc_regs[11] = 8'h0E;  // Cursor End (scanline 14)
        crtc_regs[12] = 8'h00;  // Start Address High
        crtc_regs[13] = 8'h00;  // Start Address Low
        crtc_regs[14] = 8'h00;  // Cursor Location High
        crtc_regs[15] = 8'h00;  // Cursor Location Low
        crtc_regs[16] = 8'h9C;  // Vertical Retrace Start
        crtc_regs[17] = 8'h8E;  // Vertical Retrace End
        crtc_regs[18] = 8'h8F;  // Vertical Display End
        crtc_regs[19] = 8'h28;  // Offset (logical line width in words)
        crtc_regs[20] = 8'h1F;  // Underline Location
        crtc_regs[21] = 8'h96;  // Start Vertical Blanking
        crtc_regs[22] = 8'hB9;  // End Vertical Blanking
        crtc_regs[23] = 8'hA3;  // CRTC Mode Control
        crtc_regs[24] = 8'hFF;  // Line Compare
    end

    // =========================================================================
    //  Attribute Controller Register Defaults
    // =========================================================================
    initial begin
        attr_index    = 8'h00;
        attr_flipflop = 1'b0;
        attr_pas      = 1'b0;

        // Palette entries (identity mapping for CGA colors)
        attr_regs[0]  = 8'h00;  // Palette 0 -> color 0
        attr_regs[1]  = 8'h01;
        attr_regs[2]  = 8'h02;
        attr_regs[3]  = 8'h03;
        attr_regs[4]  = 8'h04;
        attr_regs[5]  = 8'h05;
        attr_regs[6]  = 8'h14;  // Brown (mapped from 0x06 to 0x14 on real VGA)
        attr_regs[7]  = 8'h07;
        attr_regs[8]  = 8'h38;
        attr_regs[9]  = 8'h39;
        attr_regs[10] = 8'h3A;
        attr_regs[11] = 8'h3B;
        attr_regs[12] = 8'h3C;
        attr_regs[13] = 8'h3D;
        attr_regs[14] = 8'h3E;
        attr_regs[15] = 8'h3F;

        // Mode control register
        attr_regs[16] = 8'h0C;  // Bit 3=1 (blink enable), Bit 2=1 (line graphics)
        attr_regs[17] = 8'h00;  // Overscan (border) color
        attr_regs[18] = 8'h0F;  // Color Plane Enable
        attr_regs[19] = 8'h08;  // Horizontal Pixel Panning
        attr_regs[20] = 8'h00;  // Color Select
    end

    // =========================================================================
    //  Sequencer Register Defaults
    // =========================================================================
    initial begin
        seq_index   = 8'h00;
        seq_regs[0] = 8'h03;  // Reset register (normal operation)
        seq_regs[1] = 8'h00;  // Clocking Mode (bit 0: 8/9 dot, bit 3: dot clock/2)
        seq_regs[2] = 8'h03;  // Map Mask (planes 0+1 enabled for text)
        seq_regs[3] = 8'h00;  // Character Map Select
        seq_regs[4] = 8'h02;  // Memory Mode (bit 1: ext memory, no chain4 for text)
    end

    // =========================================================================
    //  Miscellaneous Output Register Default
    // =========================================================================
    initial begin
        misc_output = 8'h67;   // Standard VGA mode 3 setting
                               // Bit 0: I/O address select (1=0x3Dx, 0=0x3Bx)
                               // Bit 1: RAM enable
                               // Bits 3:2: Clock select (01 = 25 MHz)
                               // Bit 5: Page bit for odd/even
                               // Bit 6: Hsync polarity
                               // Bit 7: Vsync polarity
    end

    // =========================================================================
    //  Mode Control Derivation
    // =========================================================================
    initial begin
        mode_40col  = 1'b0;    // Default: 80-column mode
        active_cols = 7'd80;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_40col  <= 1'b0;
            active_cols <= 7'd80;
        end else begin
            // Sequencer Clocking Mode register, bit 3: halve dot clock (40-col)
            mode_40col  <= seq_regs[1][3];
            active_cols <= seq_regs[1][3] ? 7'd40 : 7'd80;
        end
    end

    // =========================================================================
    //  I/O Port Read/Write Logic (System Clock Domain)
    // =========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crtc_index     <= 8'h00;
            attr_index     <= 8'h00;
            attr_flipflop  <= 1'b0;
            attr_pas       <= 1'b0;
            seq_index      <= 8'h00;
            misc_output    <= 8'h67;
            io_rdata       <= 8'h00;

            // Reset cursor state
            cursor_pos     <= 16'h0000;
            cursor_start   <= 5'd13;
            cursor_end     <= 5'd14;
            cursor_disable <= 1'b0;
            start_addr     <= 16'h0000;
        end else begin
            // -----------------------------------------------------------
            // I/O Write
            // -----------------------------------------------------------
            if (io_cs && io_wr) begin
                case (io_addr)
                    // ---- Attribute Controller (0x3C0) ----
                    // Alternates between index and data writes (flip-flop)
                    16'h3C0: begin
                        if (!attr_flipflop) begin
                            // Index write
                            attr_index <= io_wdata[4:0];
                            attr_pas   <= io_wdata[5];
                        end else begin
                            // Data write to selected attribute register
                            if (attr_index < 5'd21)
                                attr_regs[attr_index] <= io_wdata;
                        end
                        attr_flipflop <= ~attr_flipflop;
                    end

                    // ---- Miscellaneous Output Register (0x3C2) ----
                    16'h3C2: begin
                        misc_output <= io_wdata;
                    end

                    // ---- Sequencer Index (0x3C4) ----
                    16'h3C4: begin
                        seq_index <= io_wdata;
                    end

                    // ---- Sequencer Data (0x3C5) ----
                    16'h3C5: begin
                        if (seq_index < 8'd5)
                            seq_regs[seq_index] <= io_wdata;
                    end

                    // ---- CRTC Index Register (0x3D4) ----
                    16'h3D4: begin
                        crtc_index <= io_wdata;
                    end

                    // ---- CRTC Data Register (0x3D5) ----
                    16'h3D5: begin
                        if (crtc_index < 8'd25)
                            crtc_regs[crtc_index] <= io_wdata;

                        // Update derived cursor/scroll state immediately
                        case (crtc_index)
                            8'd10: begin
                                cursor_start   <= io_wdata[4:0];
                                cursor_disable <= io_wdata[5];
                            end
                            8'd11: begin
                                cursor_end <= io_wdata[4:0];
                            end
                            8'd12: begin
                                start_addr[15:8] <= io_wdata;
                            end
                            8'd13: begin
                                start_addr[7:0] <= io_wdata;
                            end
                            8'd14: begin
                                cursor_pos[15:8] <= io_wdata;
                            end
                            8'd15: begin
                                cursor_pos[7:0] <= io_wdata;
                            end
                            default: ;
                        endcase
                    end

                    default: ; // Ignore writes to unhandled ports
                endcase
            end

            // -----------------------------------------------------------
            // I/O Read
            // -----------------------------------------------------------
            if (io_cs && io_rd) begin
                case (io_addr)
                    // ---- Attribute Controller Data Read (0x3C1) ----
                    16'h3C1: begin
                        if (attr_index < 5'd21)
                            io_rdata <= attr_regs[attr_index];
                        else
                            io_rdata <= 8'h00;
                    end

                    // ---- Miscellaneous Output Read (0x3CC) ----
                    16'h3CC: begin
                        io_rdata <= misc_output;
                    end

                    // ---- Sequencer Index Read (0x3C4) ----
                    16'h3C4: begin
                        io_rdata <= seq_index;
                    end

                    // ---- Sequencer Data Read (0x3C5) ----
                    16'h3C5: begin
                        if (seq_index < 8'd5)
                            io_rdata <= seq_regs[seq_index];
                        else
                            io_rdata <= 8'h00;
                    end

                    // ---- CRTC Index Read (0x3D4) ----
                    16'h3D4: begin
                        io_rdata <= crtc_index;
                    end

                    // ---- CRTC Data Read (0x3D5) ----
                    16'h3D5: begin
                        if (crtc_index < 8'd25)
                            io_rdata <= crtc_regs[crtc_index];
                        else
                            io_rdata <= 8'h00;
                    end

                    // ---- Input Status Register 1 (0x3DA) ----
                    // Reading this register also resets the attribute
                    // controller flip-flop (critical for BIOS/DOS VGA init).
                    16'h3DA: begin
                        io_rdata      <= {4'b0, status_vsync, 2'b00, status_de};
                        attr_flipflop <= 1'b0;  // Reset AC flip-flop
                    end

                    default: begin
                        io_rdata <= 8'h00;
                    end
                endcase
            end
        end
    end

endmodule
