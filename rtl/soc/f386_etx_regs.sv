/*
 * fabi386: ETX Display Engine — Register Block
 * ---------------------------------------------
 * MMIO register file for ETX configuration.
 * Resource stub: correct register widths for Quartus ALM estimation.
 */

import f386_pkg::*;

module f386_etx_regs (
    input  logic         clk,
    input  logic         rst_n,

    // MMIO interface
    input  logic [11:0]  reg_addr,
    input  logic [31:0]  reg_wdata,
    output logic [31:0]  reg_rdata,
    input  logic         reg_wr,
    input  logic         reg_rd,

    // Global config outputs
    output logic [15:0]  mode_active_w,
    output logic [15:0]  mode_active_h,
    output logic [7:0]   cell_w,
    output logic [7:0]   cell_h,
    output logic [7:0]   layout_cols,
    output logic [7:0]   layout_rows,

    // Surface descriptors (2 surfaces)
    output logic [31:0]  surf0_base_addr,
    output logic [15:0]  surf0_stride,
    output logic [15:0]  surf0_cols,
    output logic [15:0]  surf0_rows,
    output logic [3:0]   surf0_format,
    output logic [31:0]  surf1_base_addr,
    output logic [15:0]  surf1_stride,
    output logic [15:0]  surf1_cols,
    output logic [15:0]  surf1_rows,
    output logic [3:0]   surf1_format,

    // Font bank descriptors (8 banks)
    output logic [31:0]  font_base_addr [8],
    output logic [15:0]  font_count     [8],
    output logic [15:0]  font_geometry  [8],
    output logic [3:0]   font_format    [8],

    // Cursor descriptors (4 cursors)
    output logic [15:0]  cursor_pos_x   [4],
    output logic [15:0]  cursor_pos_y   [4],
    output logic [7:0]   cursor_hotspot [4],
    output logic [1:0]   cursor_shape   [4],
    output logic [7:0]   cursor_blink   [4],
    output logic [7:0]   cursor_alpha   [4],
    output logic [15:0]  cursor_size    [4],

    // Effects
    output logic [15:0]  effects_basic,
    output logic [15:0]  effects_advanced,
    output logic [31:0]  effects_params,

    // UTF-8 control
    output logic [7:0]   utf8_ctrl,
    output logic [20:0]  utf8_repl_cp,

    // Cache flush
    output logic         cache_flush
);

    // =========================================================================
    //  Capability registers (read-only)
    // =========================================================================
    localparam logic [31:0] CAP0 = 32'hE7D1_0001;  // ID + version
    localparam logic [31:0] CAP1 = 32'h0000_0408;  // max cell 8x16
    localparam logic [31:0] CAP2 = 32'h0000_0004;  // 4 cursors

    // =========================================================================
    //  Telemetry counters (10 x 32-bit)
    // =========================================================================
    logic [31:0] telemetry [10];

    // =========================================================================
    //  UTF-8 status/fault/counters
    // =========================================================================
    logic [7:0]  utf8_status;
    logic [15:0] utf8_fault;
    logic [31:0] utf8_counters [6];

    // =========================================================================
    //  Register write
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_active_w   <= 16'd640;
            mode_active_h   <= 16'd400;
            cell_w          <= 8'd8;
            cell_h          <= 8'd16;
            layout_cols     <= 8'd80;
            layout_rows     <= 8'd25;
            surf0_base_addr <= '0; surf0_stride <= '0; surf0_cols <= '0;
            surf0_rows      <= '0; surf0_format <= '0;
            surf1_base_addr <= '0; surf1_stride <= '0; surf1_cols <= '0;
            surf1_rows      <= '0; surf1_format <= '0;
            effects_basic   <= '0; effects_advanced <= '0; effects_params <= '0;
            utf8_ctrl       <= '0; utf8_repl_cp <= 21'hFFFD;
            cache_flush     <= 1'b0;
            utf8_status     <= '0; utf8_fault <= '0;
            for (int i = 0; i < 8; i++) begin
                font_base_addr[i] <= '0; font_count[i] <= '0;
                font_geometry[i]  <= '0; font_format[i] <= '0;
            end
            for (int i = 0; i < 4; i++) begin
                cursor_pos_x[i]   <= '0; cursor_pos_y[i]   <= '0;
                cursor_hotspot[i] <= '0; cursor_shape[i]    <= '0;
                cursor_blink[i]   <= '0; cursor_alpha[i]    <= 8'hFF;
                cursor_size[i]    <= '0;
            end
            for (int i = 0; i < 10; i++) telemetry[i] <= '0;
            for (int i = 0; i < 6; i++) utf8_counters[i] <= '0;
        end else begin
            cache_flush <= 1'b0;  // self-clearing
            if (reg_wr) begin
                case (reg_addr[11:2])
                    // Global
                    10'd1: mode_active_w <= reg_wdata[15:0];
                    10'd2: mode_active_h <= reg_wdata[15:0];
                    10'd3: {cell_h, cell_w} <= reg_wdata[15:0];
                    10'd4: {layout_rows, layout_cols} <= reg_wdata[15:0];
                    // Surface 0
                    10'd8:  surf0_base_addr <= reg_wdata;
                    10'd9:  surf0_stride    <= reg_wdata[15:0];
                    10'd10: {surf0_rows, surf0_cols} <= reg_wdata;
                    10'd11: surf0_format    <= reg_wdata[3:0];
                    // Surface 1
                    10'd12: surf1_base_addr <= reg_wdata;
                    10'd13: surf1_stride    <= reg_wdata[15:0];
                    10'd14: {surf1_rows, surf1_cols} <= reg_wdata;
                    10'd15: surf1_format    <= reg_wdata[3:0];
                    // Font banks 0-7 (4 regs each, starting at 10'd16)
                    10'd16: font_base_addr[0] <= reg_wdata;
                    10'd17: font_count[0]     <= reg_wdata[15:0];
                    10'd18: font_geometry[0]  <= reg_wdata[15:0];
                    10'd19: font_format[0]    <= reg_wdata[3:0];
                    10'd20: font_base_addr[1] <= reg_wdata;
                    10'd21: font_count[1]     <= reg_wdata[15:0];
                    10'd22: font_geometry[1]  <= reg_wdata[15:0];
                    10'd23: font_format[1]    <= reg_wdata[3:0];
                    10'd24: font_base_addr[2] <= reg_wdata;
                    10'd25: font_count[2]     <= reg_wdata[15:0];
                    10'd26: font_geometry[2]  <= reg_wdata[15:0];
                    10'd27: font_format[2]    <= reg_wdata[3:0];
                    10'd28: font_base_addr[3] <= reg_wdata;
                    10'd29: font_count[3]     <= reg_wdata[15:0];
                    10'd30: font_geometry[3]  <= reg_wdata[15:0];
                    10'd31: font_format[3]    <= reg_wdata[3:0];
                    10'd32: font_base_addr[4] <= reg_wdata;
                    10'd33: font_count[4]     <= reg_wdata[15:0];
                    10'd34: font_geometry[4]  <= reg_wdata[15:0];
                    10'd35: font_format[4]    <= reg_wdata[3:0];
                    10'd36: font_base_addr[5] <= reg_wdata;
                    10'd37: font_count[5]     <= reg_wdata[15:0];
                    10'd38: font_geometry[5]  <= reg_wdata[15:0];
                    10'd39: font_format[5]    <= reg_wdata[3:0];
                    10'd40: font_base_addr[6] <= reg_wdata;
                    10'd41: font_count[6]     <= reg_wdata[15:0];
                    10'd42: font_geometry[6]  <= reg_wdata[15:0];
                    10'd43: font_format[6]    <= reg_wdata[3:0];
                    10'd44: font_base_addr[7] <= reg_wdata;
                    10'd45: font_count[7]     <= reg_wdata[15:0];
                    10'd46: font_geometry[7]  <= reg_wdata[15:0];
                    10'd47: font_format[7]    <= reg_wdata[3:0];
                    // Cursors 0-3 (4 regs each, starting at 10'd48)
                    10'd48: {cursor_pos_y[0], cursor_pos_x[0]} <= reg_wdata;
                    10'd49: {cursor_shape[0], cursor_hotspot[0], cursor_blink[0], cursor_alpha[0]} <= reg_wdata[25:0];
                    10'd50: cursor_size[0] <= reg_wdata[15:0];
                    10'd52: {cursor_pos_y[1], cursor_pos_x[1]} <= reg_wdata;
                    10'd53: {cursor_shape[1], cursor_hotspot[1], cursor_blink[1], cursor_alpha[1]} <= reg_wdata[25:0];
                    10'd54: cursor_size[1] <= reg_wdata[15:0];
                    10'd56: {cursor_pos_y[2], cursor_pos_x[2]} <= reg_wdata;
                    10'd57: {cursor_shape[2], cursor_hotspot[2], cursor_blink[2], cursor_alpha[2]} <= reg_wdata[25:0];
                    10'd58: cursor_size[2] <= reg_wdata[15:0];
                    10'd60: {cursor_pos_y[3], cursor_pos_x[3]} <= reg_wdata;
                    10'd61: {cursor_shape[3], cursor_hotspot[3], cursor_blink[3], cursor_alpha[3]} <= reg_wdata[25:0];
                    10'd62: cursor_size[3] <= reg_wdata[15:0];
                    // Effects
                    10'd64: effects_basic    <= reg_wdata[15:0];
                    10'd65: effects_advanced <= reg_wdata[15:0];
                    10'd66: effects_params  <= reg_wdata;
                    // UTF-8
                    10'd68: utf8_ctrl    <= reg_wdata[7:0];
                    10'd69: utf8_repl_cp <= reg_wdata[20:0];
                    // Cache flush
                    10'd72: cache_flush <= reg_wdata[0];
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    //  Register read
    // =========================================================================
    always_comb begin
        reg_rdata = '0;
        if (reg_rd) begin
            case (reg_addr[11:2])
                10'd0: reg_rdata = CAP0;
                10'd1: reg_rdata = {16'd0, mode_active_w};
                10'd2: reg_rdata = {16'd0, mode_active_h};
                10'd3: reg_rdata = {16'd0, cell_h, cell_w};
                10'd4: reg_rdata = {16'd0, layout_rows, layout_cols};
                10'd8:  reg_rdata = surf0_base_addr;
                10'd9:  reg_rdata = {16'd0, surf0_stride};
                10'd11: reg_rdata = {28'd0, surf0_format};
                10'd12: reg_rdata = surf1_base_addr;
                // Telemetry (10'd80+)
                10'd80: reg_rdata = telemetry[0];
                10'd81: reg_rdata = telemetry[1];
                10'd82: reg_rdata = telemetry[2];
                10'd83: reg_rdata = telemetry[3];
                10'd84: reg_rdata = telemetry[4];
                10'd85: reg_rdata = telemetry[5];
                10'd86: reg_rdata = telemetry[6];
                10'd87: reg_rdata = telemetry[7];
                10'd88: reg_rdata = telemetry[8];
                10'd89: reg_rdata = telemetry[9];
                // UTF-8 status
                10'd90: reg_rdata = {24'd0, utf8_status};
                10'd91: reg_rdata = {16'd0, utf8_fault};
                default: reg_rdata = '0;
            endcase
        end
    end

endmodule
