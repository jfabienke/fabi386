/*
 * fabi386: Semantic Intelligence Engine (v18.0)
 * ----------------------------------------------
 * 9-pattern look-ahead to identify function boundaries, inter-segment
 * Far Returns (RETF), and CPU mode switches from the fetch block.
 *
 * Adapted from Neo-386 Pro n386_semantic_tagger.
 */

import f386_pkg::*;

module f386_semantic_tagger (
    input  logic           clk,
    input  logic [7:0]     opcode,
    input  logic [31:0]    pc,

    // Pre-fetch look-ahead (sampled from 128-bit fetch block)
    input  logic [7:0]     next_byte_0,
    input  logic [7:0]     next_byte_1,

    output semantic_tag_t  semantic_out
);

    always_comb begin
        semantic_out = SEM_NONE;

        // --- 1. Function Prologue Patterns ---
        // P_STD_32: PUSH EBP; MOV EBP, ESP (55 89 E5)
        if (opcode == 8'h55 && next_byte_0 == 8'h89 && next_byte_1 == 8'hE5)
            semantic_out = SEM_PROLOGUE;
        // P_ALT_32: PUSH EBP; MOV EBP, ESP (55 8B EC)
        else if (opcode == 8'h55 && next_byte_0 == 8'h8B && next_byte_1 == 8'hEC)
            semantic_out = SEM_PROLOGUE;
        // P_ENTER: ENTER imm16, imm8 (C8)
        else if (opcode == 8'hC8)
            semantic_out = SEM_PROLOGUE;

        // --- 2. Function Epilogue Patterns ---
        // E_LEAVE_RET: LEAVE; RET (C9 C3)
        else if (opcode == 8'hC9 && next_byte_0 == 8'hC3)
            semantic_out = SEM_EPILOGUE;
        // E_POP_RET: POP EBP; RET (5D C3)
        else if (opcode == 8'h5D && next_byte_0 == 8'hC3)
            semantic_out = SEM_EPILOGUE;

        // --- 3. Far Return (inter-segment) ---
        // RETF (CB) or RETF imm16 (CA)
        else if (opcode == 8'hCB || opcode == 8'hCA)
            semantic_out = SEM_FAR_RET;

        // --- 4. System Call Entry ---
        // INT imm8 (CD xx)
        else if (opcode == 8'hCD)
            semantic_out = SEM_INT_CALL;

        // --- 5. IRET (CF) — potential mode switch ---
        else if (opcode == 8'hCF)
            semantic_out = SEM_MODE_SW;
    end

endmodule
