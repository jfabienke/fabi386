/*
 * fabi386: Out-of-Order Core Top-Level (v18.0)
 * ---------------------------------------------
 * The primary integration hub for the superscalar pipeline.
 */

import f386_pkg::*;

module f386_ooo_core_top (
    input  logic         clk,
    input  logic         rst_n,

    // External Bus Interface (386 Socket)
    interface.slave      bus_if,

    // Telemetry Port (Ultra-RE/HARE Suite)
    output telemetry_pkt_t trace_out,
    output logic           trace_valid
);

    // --- Internal Wiring ---
    ooo_instr_t decode_u, decode_v;
    logic       rename_ready;

    ooo_instr_t iq_issue_instr;
    logic       iq_issue_valid;

    rob_entry_t rob_retire_u, rob_retire_v;

    // 1. Decoder: Fetches and generates Micro-op packets
    f386_decode_unit decoder (
        .clk(clk), .rst_n(rst_n),
        .instr_u(decode_u), .instr_v(decode_v)
    );

    // 2. Renamer: Maps Arch-Regs to 32 Physical-Regs
    f386_register_rename renamer (
        .clk(clk), .reset_n(rst_n),
        .arch_dest_u(decode_u.p_dest[2:0]),
        .phys_dest_u(decode_u.p_dest),
        .retire_valid(rob_retire_u.valid),
        .retire_phys(rob_retire_u.instr.p_dest),
        .can_rename(rename_ready)
    );

    // 3. Issue Queue: The Scheduler
    f386_issue_queue iq (
        .clk(clk), .reset_n(rst_n),
        .dispatch_instr(decode_u),
        .dispatch_valid(decode_u.valid && rename_ready),
        .issue_instr(iq_issue_instr),
        .issue_valid(iq_issue_valid),
        .exec_ready(1'b1)
    );

    // 4. ROB: Retirement & Consistency
    f386_rob rob (
        .clk(clk), .rst_n(rst_n),
        .dispatch_u(decode_u),
        .dispatch_v(decode_v),
        .retire_u(rob_retire_u),
        .retire_v(rob_retire_v)
    );

    // 5. AAR Engine: RE Telemetry
    f386_aar_engine aar (
        .clk(clk), .reset_n(rst_n),
        .cpu_instr(rob_retire_u.instr),
        .cpu_instr_valid(rob_retire_u.valid),
        .aar_pkt(trace_out),
        .aar_valid(trace_valid)
    );

endmodule
