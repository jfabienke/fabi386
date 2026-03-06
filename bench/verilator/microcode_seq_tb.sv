/*
 * Microcode Sequencer Testbench Wrapper
 * Standalone wrapper around f386_microcode_sequencer for Verilator.
 * Exposes sequencer ports directly for C++ testbench control.
 */

import f386_pkg::*;

module microcode_seq_tb (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         flush,

    // Trigger
    input  logic         start,
    input  logic [7:0]   opcode,
    input  logic [7:0]   opcode_ext,
    input  logic         is_0f_prefix,
    input  logic         is_rep_prefix,
    input  logic         is_repne,
    input  logic         is_32bit,
    input  logic [2:0]   modrm_reg,
    input  logic [31:0]  instr_pc,

    // Micro-op output
    output logic         uop_valid,
    output logic [47:0]  uop_data,
    output logic [3:0]   uop_op_type,
    output logic [3:0]   uop_alu_op,
    output logic [2:0]   uop_dest_reg,
    output logic [2:0]   uop_src_a_reg,
    output logic [2:0]   uop_src_b_reg,
    output logic [2:0]   uop_seg_reg,
    output logic [7:0]   uop_special_cmd,
    output logic [15:0]  uop_immediate,
    output logic         uop_is_last,
    output logic         uop_is_atomic,

    // Flow control
    input  logic         exec_ack,
    output logic         busy,
    output logic         block_interrupt,

    // REP status
    input  logic         rep_ecx_zero,
    input  logic         rep_zf_value
);

    // Internal wires for the op_type_t enum conversion
    op_type_t uop_op_type_enum;

    f386_microcode_sequencer u_seq (
        .clk            (clk),
        .rst_n          (rst_n),
        .flush          (flush),
        .start          (start),
        .opcode         (opcode),
        .opcode_ext     (opcode_ext),
        .is_0f_prefix   (is_0f_prefix),
        .is_rep_prefix  (is_rep_prefix),
        .is_repne       (is_repne),
        .is_32bit       (is_32bit),
        .modrm_reg      (modrm_reg),
        .instr_pc       (instr_pc),
        .uop_valid      (uop_valid),
        .uop_data       (uop_data),
        .uop_op_type    (uop_op_type_enum),
        .uop_alu_op     (uop_alu_op),
        .uop_dest_reg   (uop_dest_reg),
        .uop_src_a_reg  (uop_src_a_reg),
        .uop_src_b_reg  (uop_src_b_reg),
        .uop_seg_reg    (uop_seg_reg),
        .uop_special_cmd(uop_special_cmd),
        .uop_immediate  (uop_immediate),
        .uop_is_last    (uop_is_last),
        .uop_is_atomic  (uop_is_atomic),
        .exec_ack       (exec_ack),
        .busy           (busy),
        .block_interrupt(block_interrupt),
        .rep_ecx_zero   (rep_ecx_zero),
        .rep_zf_value   (rep_zf_value)
    );

    // Convert enum to logic for Verilator
    assign uop_op_type = uop_op_type_enum;

endmodule
