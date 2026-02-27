/*
 * fabi386: Hierarchical Microcode ROM (v13.0)
 * --------------------------------------------
 * Supports CPUID, CLFLUSH, and Atomic sequences.
 */

import f386_pkg::*;

module f386_microcode_rom (
    input  logic         clk,
    input  logic [7:0]   opcode,
    input  logic [7:0]   opcode_ext,
    input  logic         is_0f_prefix,
    input  logic [2:0]   u_step,

    input  logic         is_32bit,
    input  logic [2:0]   modrm_reg,

    output ooo_instr_t   u_op,
    output logic [5:0]   u_max_step,
    output logic         u_is_atomic
);

    logic [9:0] micro_entry;

    always_comb begin
        micro_entry = 10'h000;
        if (!is_0f_prefix) begin
            case (opcode)
                8'h90: micro_entry = {8'h00, 2'b00}; // NOP
                8'h60: micro_entry = {8'h0A, 2'b01}; // PUSHA
                default: micro_entry = 10'h000;
            endcase
        end else begin
            case (opcode_ext)
                8'hA2: micro_entry = {8'h09, 2'b01}; // CPUID
                8'h08: micro_entry = {8'h0C, 2'b01}; // INVD
                8'hAE: if (modrm_reg == 3'b111)
                       micro_entry = {8'h0E, 2'b00}; // CLFLUSH
                default: micro_entry = 10'h000;
            endcase
        end
    end

    logic [15:0] nano_template;
    always_comb begin
        case (micro_entry[9:2])
            8'h09: nano_template = {OP_ALU_IMM, 8'hA2}; // CPUID
            8'h0A: nano_template = {OP_STORE,   8'h60}; // PUSHA
            8'h0E: nano_template = {OP_SYS_CALL, 8'hAE}; // CLFLUSH
            default: nano_template = '0;
        endcase
    end

    always_comb begin
        u_op = '0;
        u_op.valid = (micro_entry != 0);
        u_is_atomic = micro_entry[0];
        u_op.op_cat = op_type_t'(nano_template[15:12]);
        u_op.opcode = nano_template[11:4];

        case (micro_entry[9:2])
            8'h09: begin // CPUID Writeback
                u_max_step = 6'd4;
                case (u_step)
                    0: u_op.p_dest = 5'd0; // EAX
                    1: u_op.p_dest = 5'd3; // EBX
                    2: u_op.p_dest = 5'd2; // EDX
                    3: u_op.p_dest = 5'd1; // ECX
                endcase
            end
            8'h0A: u_max_step = 6'd8;
            default: u_max_step = 6'd1;
        endcase
    end

endmodule
