/*
 * fabi386: AAR Telemetry Engine (v18.0)
 * ---------------------------------------
 * Aggregates the four HARE instrumentation submodules into a unified
 * telemetry pipeline:
 *
 *   1. Semantic Tagger  — function boundary / mode switch detection
 *   2. Shadow Stack     — hardware CALL/RET verification (512-entry)
 *   3. Stride Detector  — array / struct inference from bus patterns
 *   4. Telemetry DMA    — async trace buffer writes to HyperRAM
 *
 * Data flow:
 *   Retired instruction → Tagger + Shadow Stack → telemetry_pkt_t → DMA → HyperRAM
 *
 * The engine operates on retired instructions only (from the ROB), so it
 * never sees speculative work and always reflects the true program state.
 *
 * Submodules adapted from Neo-386 Pro (n386_semantic_tagger,
 * n386_shadow_stack, n386_stride_detector, n386_telemetry_dma).
 */

import f386_pkg::*;

module f386_aar_engine (
    input  logic           clk,
    input  logic           reset_n,

    // --- Retired Instruction Input (from ROB) ---
    input  ooo_instr_t     cpu_instr,
    input  logic           cpu_instr_valid,
    input  logic [31:0]    cpu_data,         // Retired data (address or result)

    // --- Bus Monitor (from BIU, for stride detection) ---
    input  logic [31:0]    bus_addr,
    input  logic           bus_req,
    input  logic           bus_ack,

    // --- Shadow Stack Validation ---
    input  logic [31:0]    actual_ret_target, // From stack read during RET
    input  logic           ret_target_valid,

    // --- HyperRAM DMA Interface ---
    output logic [31:0]    hr_addr,
    output logic [31:0]    hr_data,
    output logic           hr_req,
    output logic           hr_we,
    input  logic           hr_ack,

    // --- Configuration (from MSR file) ---
    input  logic [31:0]    trace_buf_base,
    input  logic [31:0]    trace_buf_mask,
    input  logic           telemetry_enable,

    // --- Status Outputs ---
    output telemetry_pkt_t aar_pkt,
    output logic           aar_valid,
    output logic           stack_fault,
    output logic [8:0]     call_depth,

    // --- Stride Detection Output ---
    output logic [31:0]    stride_val,
    output logic [31:0]    stride_base,
    output logic           stride_valid
);

    // =================================================================
    // 1. Semantic Tagger
    // =================================================================
    semantic_tag_t sem_tag;

    f386_semantic_tagger tagger (
        .clk         (clk),
        .opcode      (cpu_instr.opcode),
        .pc          (cpu_instr.pc),
        .next_byte_0 (cpu_instr.raw_instr[15:8]),   // 2nd byte of fetch
        .next_byte_1 (cpu_instr.raw_instr[23:16]),   // 3rd byte of fetch
        .semantic_out(sem_tag)
    );

    // =================================================================
    // 2. Shadow Stack
    // =================================================================
    logic [31:0] shadow_expected_ret;

    f386_shadow_stack_monitor shadow (
        .clk              (clk),
        .reset_n          (reset_n),
        .curr_pc          (cpu_instr.pc),
        .opcode           (cpu_instr.opcode),
        .modrm            (cpu_instr.raw_instr[15:8]),
        .instr_len        (cpu_instr.raw_instr[31:24]),  // Decoder packs length here
        .instr_valid      (cpu_instr_valid),
        .actual_ret_target(actual_ret_target),
        .ret_target_valid (ret_target_valid),
        .stack_fault      (stack_fault),
        .expected_ret     (shadow_expected_ret),
        .depth            (call_depth)
    );

    // =================================================================
    // 3. Stride Detector
    // =================================================================
    f386_stride_detector stride (
        .clk          (clk),
        .reset_n      (reset_n),
        .bus_addr     (bus_addr),
        .bus_req      (bus_req),
        .bus_ack      (bus_ack),
        .stride_val   (stride_val),
        .stride_base  (stride_base),
        .stride_valid (stride_valid)
    );

    // =================================================================
    // 4. Telemetry Packet Assembly
    // =================================================================
    telemetry_pkt_t pkt;
    logic           pkt_valid;
    logic           dma_accept;

    always_comb begin
        pkt       = '0;
        pkt_valid = 1'b0;

        if (cpu_instr_valid && telemetry_enable) begin
            pkt.is_data     = (cpu_instr.op_cat == OP_LOAD ||
                               cpu_instr.op_cat == OP_STORE);
            pkt.instr       = cpu_instr;
            pkt.data.addr   = cpu_data;
            pkt.data.value  = cpu_data;
            pkt.data.m_class = CLASS_INTERNAL;
            pkt.data.taint  = 1'b0;
            pkt.stack_fault = stack_fault;
            pkt_valid       = 1'b1;
        end
    end

    // Output the assembled packet for external consumers
    assign aar_pkt   = pkt;
    assign aar_valid = pkt_valid;

    // =================================================================
    // 5. Telemetry DMA
    // =================================================================
    f386_telemetry_dma dma (
        .clk        (clk),
        .reset_n    (reset_n),
        .pkt_in     (pkt),
        .pkt_valid  (pkt_valid && dma_accept),
        .pkt_accept (dma_accept),
        .hr_addr    (hr_addr),
        .hr_data    (hr_data),
        .hr_req     (hr_req),
        .hr_we      (hr_we),
        .hr_ack     (hr_ack),
        .buf_base   (trace_buf_base),
        .buf_mask   (trace_buf_mask)
    );

endmodule
