/*
 * fabi386: ETX Display Engine — Top-Level Wrapper
 * -------------------------------------------------
 * Feature-gated: CONF_ENABLE_ETX (default 0).
 * Instantiates all ETX sub-modules: register block, glyph cache,
 * scanout pipeline, line buffers, cursor overlay, memory hub,
 * tile tracker, command decoder, and blit engine.
 *
 * This resource-estimation stub intentionally uses a single internal clock
 * domain (`clk`) for timing, rendering, memory, and video output. `pixel_clk`
 * is retained only for top-level interface compatibility.
 *
 * All producer/consumer paths are live to prevent dead-logic pruning.
 * Resource stub for Quartus ALM/M10K estimation.
 */

import f386_pkg::*;

module f386_etx_engine (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         pixel_clk,

    // ---- I/O Port Interface ----
    input  logic [15:0]  io_addr,
    input  logic [7:0]   io_wdata,
    output logic [7:0]   io_rdata,
    input  logic         io_wr,
    input  logic         io_rd,
    input  logic         io_cs,

    // ---- Video Output (VGA-compatible) ----
    output logic [7:0]   vga_r,
    output logic [7:0]   vga_g,
    output logic [7:0]   vga_b,
    output logic         vga_hs,
    output logic         vga_vs,
    output logic         vga_de
);

    // =========================================================================
    //  Timing Generator (single internal clk domain)
    // =========================================================================
    // Fixed blanking intervals; active region from registers so Quartus
    // cannot constant-fold the comparators.
    localparam int H_FP   = 16;
    localparam int H_SYNC = 96;
    localparam int H_BP   = 48;
    localparam int V_FP   = 12;
    localparam int V_SYNC = 2;
    localparam int V_BP   = 35;

    logic [10:0] h_cnt;
    logic [9:0]  v_cnt;
    logic        h_active, v_active, pixel_valid;
    logic        hsync, vsync;

    // Total line/frame lengths derived from register values
    logic [10:0] h_total;
    logic [9:0]  v_total;
    assign h_total = mode_active_w[10:0] + H_FP[10:0] + H_SYNC[10:0] + H_BP[10:0];
    assign v_total = mode_active_h[9:0]  + V_FP[9:0]  + V_SYNC[9:0]  + V_BP[9:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= '0;
            v_cnt <= '0;
        end else begin
            if (h_cnt >= h_total - 1'b1) begin
                h_cnt <= '0;
                if (v_cnt >= v_total - 1'b1)
                    v_cnt <= '0;
                else
                    v_cnt <= v_cnt + 1'b1;
            end else begin
                h_cnt <= h_cnt + 1'b1;
            end
        end
    end

    assign h_active    = (h_cnt < mode_active_w[10:0]);
    assign v_active    = (v_cnt < mode_active_h[9:0]);
    assign pixel_valid = h_active && v_active;
    assign hsync = (h_cnt >= mode_active_w[10:0] + H_FP[10:0]) &&
                   (h_cnt <  mode_active_w[10:0] + H_FP[10:0] + H_SYNC[10:0]);
    assign vsync = (v_cnt >= mode_active_h[9:0]  + V_FP[9:0]) &&
                   (v_cnt <  mode_active_h[9:0]  + V_FP[9:0]  + V_SYNC[9:0]);

    logic vsync_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            vsync_r <= 1'b0;
        else
            vsync_r <= vsync;
    end
    wire vsync_pulse = vsync && !vsync_r;

    // =========================================================================
    //  MMIO register decode
    // =========================================================================
    // ETX register space: 0x3E0-0x3EF (I/O ports)
    // ETX command submit:  0x3F0-0x3F7 (8-byte command staging register)
    logic        etx_cs, cmd_cs;
    logic [11:0] reg_addr;
    logic [31:0] reg_wdata, reg_rdata;
    logic        reg_wr, reg_rd;

    assign etx_cs   = io_cs && (io_addr[15:4] == 12'h03E);
    assign cmd_cs   = io_cs && (io_addr[15:3] == 13'h07E);  // 0x3F0-0x3F7
    assign reg_addr = io_addr[11:0];
    assign reg_wdata = {24'd0, io_wdata};
    assign reg_wr    = io_wr && etx_cs;
    assign reg_rd    = io_rd && etx_cs;
    assign io_rdata  = etx_cs ? reg_rdata[7:0] : 8'd0;

    // =========================================================================
    //  Config wires (from register block)
    // =========================================================================
    logic [15:0] mode_active_w, mode_active_h;
    logic [7:0]  cell_w, cell_h, layout_cols, layout_rows;
    logic [31:0] surf0_base_addr, surf1_base_addr;
    logic [15:0] surf0_stride, surf0_cols, surf0_rows;
    logic [3:0]  surf0_format;
    logic [15:0] surf1_stride, surf1_cols, surf1_rows;
    logic [3:0]  surf1_format;
    logic [31:0] font_base_addr [8];
    logic [15:0] font_count [8];
    logic [15:0] font_geometry [8];
    logic [3:0]  font_format [8];
    logic [15:0] cursor_pos_x [4], cursor_pos_y [4];
    logic [7:0]  cursor_hotspot [4];
    logic [1:0]  cursor_shape [4];
    logic [7:0]  cursor_blink [4], cursor_alpha [4];
    logic [15:0] cursor_size [4];
    logic [15:0] effects_basic, effects_advanced;
    logic [31:0] effects_params;
    logic [7:0]  utf8_ctrl;
    logic [20:0] utf8_repl_cp;
    logic        cache_flush;

    // =========================================================================
    //  Register Block
    // =========================================================================
    f386_etx_regs regs (
        .clk            (clk),
        .rst_n          (rst_n),
        .reg_addr       (reg_addr),
        .reg_wdata      (reg_wdata),
        .reg_rdata      (reg_rdata),
        .reg_wr         (reg_wr),
        .reg_rd         (reg_rd),
        .mode_active_w  (mode_active_w),
        .mode_active_h  (mode_active_h),
        .cell_w         (cell_w),
        .cell_h         (cell_h),
        .layout_cols    (layout_cols),
        .layout_rows    (layout_rows),
        .surf0_base_addr(surf0_base_addr),
        .surf0_stride   (surf0_stride),
        .surf0_cols     (surf0_cols),
        .surf0_rows     (surf0_rows),
        .surf0_format   (surf0_format),
        .surf1_base_addr(surf1_base_addr),
        .surf1_stride   (surf1_stride),
        .surf1_cols     (surf1_cols),
        .surf1_rows     (surf1_rows),
        .surf1_format   (surf1_format),
        .font_base_addr (font_base_addr),
        .font_count     (font_count),
        .font_geometry  (font_geometry),
        .font_format    (font_format),
        .cursor_pos_x   (cursor_pos_x),
        .cursor_pos_y   (cursor_pos_y),
        .cursor_hotspot (cursor_hotspot),
        .cursor_shape   (cursor_shape),
        .cursor_blink   (cursor_blink),
        .cursor_alpha   (cursor_alpha),
        .cursor_size    (cursor_size),
        .effects_basic  (effects_basic),
        .effects_advanced(effects_advanced),
        .effects_params (effects_params),
        .utf8_ctrl      (utf8_ctrl),
        .utf8_repl_cp   (utf8_repl_cp),
        .cache_flush    (cache_flush)
    );

    // =========================================================================
    //  Glyph Cache + Miss-Refill FSM (clk domain)
    // =========================================================================
    logic [15:0]  gc_lookup_id;
    logic         gc_lookup_valid, gc_lookup_hit, gc_lookup_ready;
    logic [127:0] gc_lookup_data;
    logic [15:0]  gc_fill_id;
    logic [127:0] gc_fill_data;
    logic         gc_fill_valid;

    f386_etx_glyph_cache glyph_cache (
        .clk              (clk),
        .rst_n            (rst_n),
        .lookup_glyph_id  (gc_lookup_id),
        .lookup_valid     (gc_lookup_valid),
        .lookup_hit       (gc_lookup_hit),
        .lookup_data      (gc_lookup_data),
        .lookup_ready     (gc_lookup_ready),
        .fill_glyph_id    (gc_fill_id),
        .fill_data        (gc_fill_data),
        .fill_valid       (gc_fill_valid),
        .flush            (cache_flush)
    );

    // --- Glyph miss-refill FSM ---
    // On cache miss → request glyph data via mem hub A1 → fill on ack.
    // 128-bit glyph = 4 × 32-bit SDRAM reads.
    typedef enum logic [2:0] {
        GCR_IDLE,
        GCR_REQ,
        GCR_WAIT,
        GCR_COLLECT,
        GCR_FILL
    } gcr_state_t;

    gcr_state_t   gcr_state;
    logic [15:0]  gcr_glyph_id;
    logic [24:0]  gcr_addr;
    logic [127:0] gcr_data;
    logic [1:0]   gcr_word_cnt;
    logic         gcr_req;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gcr_state    <= GCR_IDLE;
            gcr_glyph_id <= '0;
            gcr_addr     <= '0;
            gcr_data     <= '0;
            gcr_word_cnt <= '0;
            gcr_req      <= 1'b0;
            gc_fill_id   <= '0;
            gc_fill_data <= '0;
            gc_fill_valid <= 1'b0;
        end else begin
            gc_fill_valid <= 1'b0;
            gcr_req       <= 1'b0;

            case (gcr_state)
                GCR_IDLE: begin
                    if (gc_lookup_ready && !gc_lookup_hit && gc_lookup_valid) begin
                        gcr_glyph_id <= gc_lookup_id;
                        gcr_addr     <= font_base_addr[0][24:0] +
                                        {9'd0, gc_lookup_id} * 25'd16;
                        gcr_word_cnt <= '0;
                        gcr_data     <= '0;
                        gcr_state    <= GCR_REQ;
                    end
                end

                GCR_REQ: begin
                    gcr_req   <= 1'b1;
                    gcr_state <= GCR_WAIT;
                end

                GCR_WAIT: begin
                    if (mem_hub_a1_ack) begin
                        gcr_data[gcr_word_cnt*32 +: 32] <= mem_hub_a1_rdata;
                        gcr_state <= GCR_COLLECT;
                    end
                end

                GCR_COLLECT: begin
                    if (gcr_word_cnt == 2'd3) begin
                        gcr_state <= GCR_FILL;
                    end else begin
                        gcr_word_cnt <= gcr_word_cnt + 1'b1;
                        gcr_addr     <= gcr_addr + 25'd4;
                        gcr_state    <= GCR_REQ;
                    end
                end

                GCR_FILL: begin
                    gc_fill_id    <= gcr_glyph_id;
                    gc_fill_data  <= gcr_data;
                    gc_fill_valid <= 1'b1;
                    gcr_state     <= GCR_IDLE;
                end

                default: gcr_state <= GCR_IDLE;
            endcase
        end
    end

    // =========================================================================
    //  Cursor Overlay (clk domain)
    // =========================================================================
    logic [10:0] co_pixel_x;
    logic [9:0]  co_pixel_y;
    logic [23:0] co_color;
    logic        co_active;
    logic [7:0]  co_alpha;
    logic [7:0]  frame_counter;

    // Frame counter on the ETX internal clock domain.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            frame_counter <= '0;
        else if (vsync_pulse)
            frame_counter <= frame_counter + 1'b1;
    end

    f386_etx_cursor_overlay cursor_ov (
        .clk            (clk),
        .rst_n          (rst_n),
        .pixel_x        (co_pixel_x),
        .pixel_y        (co_pixel_y),
        .cursor_pos_x   (cursor_pos_x),
        .cursor_pos_y   (cursor_pos_y),
        .cursor_hotspot (cursor_hotspot),
        .cursor_shape   (cursor_shape),
        .cursor_blink   (cursor_blink),
        .cursor_alpha   (cursor_alpha),
        .cursor_size    (cursor_size),
        .frame_counter  (frame_counter),
        .cursor_color   (co_color),
        .cursor_active  (co_active),
        .cursor_alpha_out(co_alpha)
    );

    // =========================================================================
    //  Scanout Pipeline (single internal clk domain)
    // =========================================================================
    logic [7:0] pipe_r, pipe_g, pipe_b;
    logic       pipe_valid;

    f386_etx_scanout_pipe scanout (
        .clk               (clk),
        .rst_n             (rst_n),
        .pixel_valid       (pixel_valid),
        .pixel_x           (h_cnt),
        .pixel_y           (v_cnt),
        .cell_w            (cell_w),
        .cell_h            (cell_h),
        .layout_cols       (layout_cols),
        .layout_rows       (layout_rows),
        .surf_base_addr    (surf0_base_addr),
        .surf_stride       (surf0_stride),
        .surf_format       (surf0_format),
        .effects_basic     (effects_basic),
        .effects_advanced  (effects_advanced),
        .cache_lookup_id   (gc_lookup_id),
        .cache_lookup_valid(gc_lookup_valid),
        .cache_lookup_hit  (gc_lookup_hit),
        .cache_lookup_data (gc_lookup_data),
        .cache_lookup_ready(gc_lookup_ready),
        .cursor_pixel_x    (co_pixel_x),
        .cursor_pixel_y    (co_pixel_y),
        .cursor_color      (co_color),
        .cursor_active     (co_active),
        .cursor_alpha      (co_alpha),
        .out_r             (pipe_r),
        .out_g             (pipe_g),
        .out_b             (pipe_b),
        .out_valid         (pipe_valid)
    );

    // =========================================================================
    //  Line Buffers (single internal clk domain)
    // =========================================================================
    logic [23:0] lb_rd_color;
    logic        line_swap;

    assign line_swap = (h_cnt == mode_active_w[10:0] - 1'b1) && v_active;

    f386_etx_line_buffer line_buf (
        .clk       (clk),
        .rst_n     (rst_n),
        .wr_x      (h_cnt),
        .wr_color  ({pipe_r, pipe_g, pipe_b}),
        .wr_valid  (pipe_valid),
        .rd_x      (h_cnt),
        .rd_color  (lb_rd_color),
        .line_swap (line_swap)
    );

    // =========================================================================
    //  Scanout Prefetch Producer (clk domain)
    // =========================================================================
    logic        prefetch_req;
    logic [24:0] prefetch_addr;
    logic        prefetch_wr;
    logic [31:0] prefetch_wdata;

    logic [10:0] prefetch_col;
    logic        prefetch_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prefetch_req    <= 1'b0;
            prefetch_addr   <= '0;
            prefetch_col    <= '0;
            prefetch_active <= 1'b0;
        end else begin
            prefetch_req <= 1'b0;

            if (h_cnt == mode_active_w[10:0] && v_active) begin
                prefetch_active <= 1'b1;
                prefetch_col    <= '0;
                prefetch_addr   <= surf0_base_addr[24:0] +
                                   {15'd0, v_cnt} * {9'd0, surf0_stride};
            end else if (prefetch_active) begin
                if (prefetch_col < {3'd0, layout_cols}) begin
                    prefetch_req  <= 1'b1;
                    if (mem_hub_a0_ack) begin
                        prefetch_col  <= prefetch_col + 1'b1;
                        prefetch_addr <= prefetch_addr + 25'd2;
                    end
                end else begin
                    prefetch_active <= 1'b0;
                end
            end
        end
    end

    assign prefetch_wr    = 1'b0;
    assign prefetch_wdata = '0;

    // =========================================================================
    //  CPU Surface Write Producer (clk domain)
    // =========================================================================
    logic        cpu_surf_req;
    logic [24:0] cpu_surf_addr;
    logic        cpu_surf_wr;
    logic [31:0] cpu_surf_wdata;

    assign cpu_surf_req   = io_wr && cmd_cs;
    assign cpu_surf_addr  = surf0_base_addr[24:0] + {13'd0, io_addr[11:0]};
    assign cpu_surf_wr    = 1'b1;
    assign cpu_surf_wdata = {24'd0, io_wdata};

    // =========================================================================
    //  RAMFont Fetch Producer (clk domain)
    // =========================================================================
    logic        ramfont_req;
    logic [24:0] ramfont_addr;

    assign ramfont_req  = (gcr_state == GCR_REQ);
    assign ramfont_addr = font_base_addr[utf8_ctrl[2:0]][24:0] +
                          {9'd0, gcr_glyph_id} * 25'd16 +
                          {23'd0, gcr_word_cnt} * 25'd4;

    // =========================================================================
    //  Scanout Urgent (single internal clk domain)
    // =========================================================================
    logic scanout_urgent;
    assign scanout_urgent = h_active &&
                            (h_cnt > mode_active_w[10:0] - 11'd32);

    // =========================================================================
    //  SDRAM Stub Responders
    // =========================================================================
    // 2-cycle FSM per channel: req → pending → ack + address-derived data.
    // Address bits rotated to fill full 32-bit range (prevents constant-fold).
    logic        sdram_a_req_w, sdram_b_req_w;
    logic [24:0] sdram_a_addr_w, sdram_b_addr_w;
    logic        sdram_a_wr_w, sdram_b_wr_w;
    logic [31:0] sdram_a_wdata_w, sdram_b_wdata_w;
    logic        sdram_a_ack, sdram_b_ack;
    logic [31:0] sdram_a_rdata, sdram_b_rdata;

    // Channel A stub
    logic sdram_a_pending;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sdram_a_ack     <= 1'b0;
            sdram_a_rdata   <= '0;
            sdram_a_pending <= 1'b0;
        end else begin
            sdram_a_ack <= 1'b0;
            if (sdram_a_pending) begin
                sdram_a_ack     <= 1'b1;
                sdram_a_rdata   <= {sdram_a_addr_w[24:0], sdram_a_addr_w[24:18]};
                sdram_a_pending <= 1'b0;
            end else if (sdram_a_req_w) begin
                sdram_a_pending <= 1'b1;
            end
        end
    end

    // Channel B stub
    logic sdram_b_pending;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sdram_b_ack     <= 1'b0;
            sdram_b_rdata   <= '0;
            sdram_b_pending <= 1'b0;
        end else begin
            sdram_b_ack <= 1'b0;
            if (sdram_b_pending) begin
                sdram_b_ack     <= 1'b1;
                sdram_b_rdata   <= {sdram_b_addr_w[24:0], sdram_b_addr_w[24:18]};
                sdram_b_pending <= 1'b0;
            end else if (sdram_b_req_w) begin
                sdram_b_pending <= 1'b1;
            end
        end
    end

    // =========================================================================
    //  Memory Hub — all requestors wired to live producers
    // =========================================================================
    logic mem_hub_a0_ack, mem_hub_a1_ack, mem_hub_a2_ack;
    logic mem_hub_b0_ack, mem_hub_b1_ack, mem_hub_b2_ack;
    logic [31:0] mem_hub_a0_rdata, mem_hub_a1_rdata;
    logic [31:0] mem_hub_b0_rdata, mem_hub_b1_rdata, mem_hub_b2_rdata;

    logic        blit_mem_req;
    logic [24:0] blit_mem_addr;
    logic        blit_mem_wr;
    logic [31:0] blit_mem_wdata;

    logic        ring_rd_req;
    logic [24:0] ring_rd_addr;

    f386_etx_mem_hub mem_hub (
        .clk            (clk),
        .rst_n          (rst_n),
        // Channel A
        .a0_req         (prefetch_req),
        .a0_addr        (prefetch_addr),
        .a0_wr          (prefetch_wr),
        .a0_wdata       (prefetch_wdata),
        .a0_rdata       (mem_hub_a0_rdata),
        .a0_ack         (mem_hub_a0_ack),
        .a1_req         (gcr_req),
        .a1_addr        (gcr_addr),
        .a1_rdata       (mem_hub_a1_rdata),
        .a1_ack         (mem_hub_a1_ack),
        .a2_req         (cpu_surf_req),
        .a2_addr        (cpu_surf_addr),
        .a2_wr          (cpu_surf_wr),
        .a2_wdata       (cpu_surf_wdata),
        .a2_ack         (mem_hub_a2_ack),
        // Channel B
        .b0_req         (ramfont_req),
        .b0_addr        (ramfont_addr),
        .b0_rdata       (mem_hub_b0_rdata),
        .b0_ack         (mem_hub_b0_ack),
        .b1_req         (ring_rd_req),
        .b1_addr        (ring_rd_addr),
        .b1_rdata       (mem_hub_b1_rdata),
        .b1_ack         (mem_hub_b1_ack),
        .b2_req         (blit_mem_req),
        .b2_addr        (blit_mem_addr),
        .b2_wr          (blit_mem_wr),
        .b2_wdata       (blit_mem_wdata),
        .b2_rdata       (mem_hub_b2_rdata),
        .b2_ack         (mem_hub_b2_ack),
        // SDRAM stubs
        .sdram_a_req    (sdram_a_req_w),
        .sdram_a_addr   (sdram_a_addr_w),
        .sdram_a_wr     (sdram_a_wr_w),
        .sdram_a_wdata  (sdram_a_wdata_w),
        .sdram_a_rdata  (sdram_a_rdata),
        .sdram_a_ack    (sdram_a_ack),
        .sdram_b_req    (sdram_b_req_w),
        .sdram_b_addr   (sdram_b_addr_w),
        .sdram_b_wr     (sdram_b_wr_w),
        .sdram_b_wdata  (sdram_b_wdata_w),
        .sdram_b_rdata  (sdram_b_rdata),
        .sdram_b_ack    (sdram_b_ack),
        .scanout_urgent (scanout_urgent)
    );

    // =========================================================================
    //  Tile Tracker (single internal clk domain)
    // =========================================================================
    logic [11:0] blit_dirty_idx;
    logic        blit_dirty_set;

    logic [11:0] scanout_tile_idx;
    assign scanout_tile_idx = {v_cnt[9:4], h_cnt[10:5]};

    logic scanout_tile_clear;
    assign scanout_tile_clear = pixel_valid &&
                                (h_cnt[4:0] == 5'd31) && (v_cnt[3:0] == 4'd15);

    f386_etx_tile_tracker tile_tracker (
        .clk             (clk),
        .rst_n           (rst_n),
        .set_tile_idx    (blit_dirty_idx),
        .set_dirty       (blit_dirty_set),
        .clear_tile_idx  (scanout_tile_idx),
        .clear_dirty     (scanout_tile_clear),
        .query_tile_idx  (scanout_tile_idx),
        .query_is_dirty  (),
        .clear_all       (vsync_pulse)
    );

    // =========================================================================
    //  Command Staging Register (8-byte, byte-lane addressed)
    // =========================================================================
    // Software writes 8 bytes to 0x3F0-0x3F7 (one byte per I/O write).
    // Writing byte 7 (containing opcode in bits [63:56]) triggers submit.
    // This ensures cmd_wdata[63:60] is software-controlled, not constant-zero.
    logic [63:0] cmd_staging;
    logic [63:0] cmd_wdata;
    logic        cmd_wr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cmd_staging <= '0;
        else if (io_wr && cmd_cs)
            cmd_staging[io_addr[2:0]*8 +: 8] <= io_wdata;
    end

    // Submit when MSB byte written — opcode in live io_wdata, rest from staging
    assign cmd_wr    = io_wr && cmd_cs && (io_addr[2:0] == 3'd7);
    assign cmd_wdata = {io_wdata, cmd_staging[55:0]};

    // =========================================================================
    //  Command Decoder + Blit Engine
    // =========================================================================
    logic [3:0]  blit_opcode;
    logic [24:0] blit_src_addr, blit_dst_addr;
    logic [15:0] blit_width, blit_height, blit_src_stride, blit_dst_stride;
    logic [31:0] blit_fill_color;
    logic [23:0] blit_colorkey;
    logic        blit_start, blit_done;

    f386_etx_cmd_decoder cmd_dec (
        .clk            (clk),
        .rst_n          (rst_n),
        .cmd_wdata      (cmd_wdata),
        .cmd_wr         (cmd_wr),
        .cmd_full       (),
        .blit_opcode    (blit_opcode),
        .blit_src_addr  (blit_src_addr),
        .blit_dst_addr  (blit_dst_addr),
        .blit_width     (blit_width),
        .blit_height    (blit_height),
        .blit_src_stride(blit_src_stride),
        .blit_dst_stride(blit_dst_stride),
        .blit_fill_color(blit_fill_color),
        .blit_colorkey  (blit_colorkey),
        .blit_start     (blit_start),
        .blit_done      (blit_done),
        .ring_rd_req    (ring_rd_req),
        .ring_rd_addr   (ring_rd_addr),
        .ring_rd_data   (mem_hub_b1_rdata),
        .ring_rd_ack    (mem_hub_b1_ack),
        .fence_seq      (),
        .fence_valid    ()
    );

    f386_etx_blit_engine blit_eng (
        .clk            (clk),
        .rst_n          (rst_n),
        .opcode         (blit_opcode),
        .src_addr       (blit_src_addr),
        .dst_addr       (blit_dst_addr),
        .width          (blit_width),
        .height         (blit_height),
        .src_stride     (blit_src_stride),
        .dst_stride     (blit_dst_stride),
        .fill_color     (blit_fill_color),
        .colorkey       (blit_colorkey),
        .start          (blit_start),
        .done           (blit_done),
        .mem_req        (blit_mem_req),
        .mem_addr       (blit_mem_addr),
        .mem_wr         (blit_mem_wr),
        .mem_wdata      (blit_mem_wdata),
        .mem_rdata      (mem_hub_b2_rdata),
        .mem_ack        (mem_hub_b2_ack),
        .dirty_tile_idx (blit_dirty_idx),
        .dirty_set      (blit_dirty_set)
    );

    // =========================================================================
    //  Video output (single internal clk domain)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vga_r  <= '0;
            vga_g  <= '0;
            vga_b  <= '0;
            vga_hs <= 1'b0;
            vga_vs <= 1'b0;
            vga_de <= 1'b0;
        end else begin
            vga_hs <= ~hsync;
            vga_vs <= ~vsync;
            vga_de <= pixel_valid;
            if (pixel_valid) begin
                vga_r <= lb_rd_color[23:16];
                vga_g <= lb_rd_color[15:8];
                vga_b <= lb_rd_color[7:0];
            end else begin
                vga_r <= '0;
                vga_g <= '0;
                vga_b <= '0;
            end
        end
    end

endmodule
