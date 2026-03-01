/*
 * fabi386: Pipeline Top Level
 * Phase 5 Integration: Connects the Superscalar Core to the
 * "Ultra-RE" hardware suite and the Supervisor MSR file.
 */

import f386_pkg::*;

module f386_pipeline_top (
    input  logic         clk,
    input  logic         reset_n,

    // External Memory/Bus Interface
    output logic [31:0]  addr,
    input  logic [31:0]  data_in,
    output logic [31:0]  data_out,
    output logic         req,
    output logic         we,
    input  logic         ack
);

    // --- Internal Control Signals (from MSRs) ---
    logic [31:0] g_start, g_end;
    logic        g_en;
    logic [31:0] t_base;
    logic        t_en;
    logic [31:0] d_pc_0, d_pc_1, d_pc_2, d_pc_3;
    logic [3:0]  d_en;
    logic        d_unlock;

    // --- 1. MSR Control File ---
    logic [31:0] alu_msr_idx;
    logic [63:0] alu_msr_din, alu_msr_dout;
    logic        alu_msr_re, alu_msr_we, alu_msr_ack;

    f386_msr_file msr_inst (
        .clk(clk), .reset_n(reset_n),
        .msr_idx(alu_msr_idx), .msr_din(alu_msr_din),
        .msr_we(alu_msr_we), .msr_re(alu_msr_re),
        .msr_dout(alu_msr_dout), .msr_ack(alu_msr_ack),
        .guard_start(g_start), .guard_end(g_end), .guard_en(g_en),
        .thermal_base(t_base), .telemetry_en(t_en),
        .host_debug_pc_0(d_pc_0), .host_debug_pc_1(d_pc_1),
        .host_debug_pc_2(d_pc_2), .host_debug_pc_3(d_pc_3),
        .host_debug_en(d_en), .host_debug_unlock(d_unlock),
        .rob_commit_pulse(1'b0),
        .perfctr0_out(), .perfctr1_out()
    );

    // --- 2. Hardware Guard Unit (HGU) ---
    logic guard_fault;
    f386_guard_unit hgu_inst (
        .clk(clk), .reset_n(reset_n),
        .pc(addr), .pc_valid(req && !we), // Monitor instruction fetches
        .safe_start(g_start), .safe_end(g_end),
        .guard_en(g_en), .fault_trap(guard_fault)
    );

    // --- 3. Active Reconstruction Engine (AAR) ---
    telemetry_pkt_t aar_pkt;
    logic           aar_valid;
    f386_aar_engine aar_inst (
        .clk(clk), .reset_n(reset_n),
        // ... (Connections to Pipeline and Bus)
        .aar_pkt(aar_pkt), .aar_valid(aar_valid && t_en)
    );

    // --- 4. Hardware Debug Unit (HDU) ---
    logic dbg_halt, dbg_irq;
    f386_debug_unit hdu_inst (
        .clk(clk), .reset_n(reset_n),
        .curr_pc(addr), .pc_valid(req && !we),
        .host_trig_pc_0(d_pc_0), .host_trig_pc_1(d_pc_1),
        .host_trig_pc_2(d_pc_2), .host_trig_pc_3(d_pc_3),
        .host_trig_en(d_en),
        .host_unlock(d_unlock), .debug_halt(dbg_halt), .debug_irq(dbg_irq)
    );

    // --- 5. Dual-Issue Execution Core ---
    // (Integration of f386_dispatch and f386_alu here...)

endmodule
