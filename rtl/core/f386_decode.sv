/*
 * fabi386: Superscalar Instruction Decoder
 * -----------------------------------------
 * Full variable-length x86 decode for the 486DX instruction set.
 * Identifies instruction boundaries within a 128-bit fetch block,
 * extracts prefixes, opcodes, ModRM/SIB, displacement, and
 * immediates for dual-issue dispatch to U and V pipes.
 *
 * Covers all one-byte opcodes (0x00-0xFF) and two-byte opcodes
 * (0x0F 0x00-0xFF) per the i486 Programmer's Reference Manual.
 *
 * References:
 *   - ao486_original: rtl/ao486/commands/ (78 instruction definitions)
 *   - 80x86: rtl/InsnDecoder.sv (6-state decode FSM)
 *   - Intel i486 Programmer's Reference Manual, Appendix A
 */

import f386_pkg::*;

module f386_decode (
    input  logic         clk,
    input  logic         rst_n,

    // Fetch Buffer Interface
    input  logic [127:0] fetch_block,   // 16-byte fetch window
    input  logic         fetch_valid,
    input  logic [31:0]  current_pc,
    output logic         fetch_ack,

    // Pipeline Dispatch Interface (to Renamer)
    output ooo_instr_t   instr_u,       // Primary (U-Pipe)
    output logic         instr_u_valid,
    output ooo_instr_t   instr_v,       // Secondary (V-Pipe)
    output logic         instr_v_valid,
    input  logic         rename_ready,  // Back-pressure from renamer

    // Branch Target Pre-Calculation (to Branch Predictor)
    output logic [31:0]  branch_target_u,   // Computed branch target for U-pipe
    output logic         branch_target_u_valid,
    output logic         branch_indirect_u,  // U-pipe is indirect branch (target unknown)
    output logic [31:0]  branch_target_v,
    output logic         branch_target_v_valid,
    output logic         branch_indirect_v,

    // Flags Dependency Tracking (to Renamer / Scoreboard)
    output logic         u_reads_flags,      // U-pipe instruction reads EFLAGS
    output logic         u_writes_flags,     // U-pipe instruction writes EFLAGS
    output logic         v_reads_flags,
    output logic         v_writes_flags,

    // Address Register Info (to AGU / Load-Store Unit)
    output logic [2:0]   u_addr_base,        // U-pipe memory address base register
    output logic         u_addr_base_valid,
    output logic [2:0]   u_addr_index,       // U-pipe memory address index register
    output logic         u_addr_index_valid,
    output logic [1:0]   u_addr_scale,       // U-pipe SIB scale (00=x1..11=x8)
    output logic [2:0]   v_addr_base,
    output logic         v_addr_base_valid,
    output logic [2:0]   v_addr_index,
    output logic         v_addr_index_valid,
    output logic [1:0]   v_addr_scale,

    // Memory operand size (for LSQ, 0=byte, 1=word, 2=dword)
    output logic [1:0]   u_mem_size,
    output logic [1:0]   v_mem_size,

    // Far pointer segment selector (for FMT_FAR: JMP/CALL far)
    output logic [15:0]  u_far_selector,

    // CPU Mode Context
    input  logic         pe_mode,       // CR0.PE — Protected Mode
    input  logic         v86_mode,      // EFLAGS.VM — Virtual 8086
    input  logic         default_32     // CS.D — Default operand/addr size
);

    // =========================================================================
    // Encoding Format Classification
    // =========================================================================
    //
    // Each opcode maps to a format that describes its operand encoding.
    // The length calculator uses this plus the ModRM byte to determine
    // total instruction length (1-15 bytes).

    typedef enum logic [3:0] {
        FMT_NONE,       // Opcode only (NOP, CLI, STI, PUSHA, etc.)
        FMT_MODRM,      // + ModRM [+ SIB] [+ disp]
        FMT_MODRM_I8,   // + ModRM [+ SIB] [+ disp] + imm8
        FMT_MODRM_IV,   // + ModRM [+ SIB] [+ disp] + imm16/32
        FMT_I8,         // + imm8
        FMT_IV,         // + imm16/32 (operand-size dependent)
        FMT_I16,        // + imm16 (always 16-bit: RET imm16, ENTER)
        FMT_ADDR,       // + moffs16/32 (address-size dependent)
        FMT_REL8,       // + rel8
        FMT_RELV,       // + rel16/32 (operand-size dependent)
        FMT_FAR,        // + ptr16:16 or ptr16:32 (seg:offset)
        FMT_ENTER,      // + imm16 + imm8 (ENTER special)
        FMT_GRP3B,      // + ModRM, then if reg==000/001: + imm8 (Grp3 byte)
        FMT_GRP3V,      // + ModRM, then if reg==000/001: + immv (Grp3 word/dword)
        FMT_PREFIX,     // Prefix byte — not a complete instruction
        FMT_INVALID     // Undefined / reserved opcode
    } opcode_fmt_t;


    // =========================================================================
    // One-Byte Opcode Format Table (0x00 - 0xFF)
    // =========================================================================
    //
    // Derived from the i486 Programmer's Reference Manual, Appendix A.
    // The ALU block (ADD/OR/ADC/SBB/AND/SUB/XOR/CMP) repeats a 6-opcode
    // pattern every 8 entries: modrm, modrm, modrm, modrm, i8, iv.
    // Entries 6 and 7 of each block are PUSH/POP seg or special instructions.

    function automatic opcode_fmt_t get_1byte_fmt(logic [7:0] op);
        case (op)
            // ----- 0x00-0x3F: ALU operations + segment + adjusts -----
            // ADD r/m8,r8 | ADD r/m32,r32 | ADD r8,r/m8 | ADD r32,r/m32
            8'h00, 8'h01, 8'h02, 8'h03: return FMT_MODRM;
            8'h04: return FMT_I8;           // ADD AL, imm8
            8'h05: return FMT_IV;           // ADD eAX, imm16/32
            8'h06: return FMT_NONE;         // PUSH ES
            8'h07: return FMT_NONE;         // POP ES
            // OR
            8'h08, 8'h09, 8'h0A, 8'h0B: return FMT_MODRM;
            8'h0C: return FMT_I8;           // OR AL, imm8
            8'h0D: return FMT_IV;           // OR eAX, imm16/32
            8'h0E: return FMT_NONE;         // PUSH CS
            8'h0F: return FMT_NONE;         // 0F escape (handled separately)
            // ADC
            8'h10, 8'h11, 8'h12, 8'h13: return FMT_MODRM;
            8'h14: return FMT_I8;           // ADC AL, imm8
            8'h15: return FMT_IV;           // ADC eAX, imm16/32
            8'h16: return FMT_NONE;         // PUSH SS
            8'h17: return FMT_NONE;         // POP SS
            // SBB
            8'h18, 8'h19, 8'h1A, 8'h1B: return FMT_MODRM;
            8'h1C: return FMT_I8;           // SBB AL, imm8
            8'h1D: return FMT_IV;           // SBB eAX, imm16/32
            8'h1E: return FMT_NONE;         // PUSH DS
            8'h1F: return FMT_NONE;         // POP DS
            // AND
            8'h20, 8'h21, 8'h22, 8'h23: return FMT_MODRM;
            8'h24: return FMT_I8;           // AND AL, imm8
            8'h25: return FMT_IV;           // AND eAX, imm16/32
            8'h26: return FMT_PREFIX;       // ES: segment override
            8'h27: return FMT_NONE;         // DAA
            // SUB
            8'h28, 8'h29, 8'h2A, 8'h2B: return FMT_MODRM;
            8'h2C: return FMT_I8;           // SUB AL, imm8
            8'h2D: return FMT_IV;           // SUB eAX, imm16/32
            8'h2E: return FMT_PREFIX;       // CS: segment override
            8'h2F: return FMT_NONE;         // DAS
            // XOR
            8'h30, 8'h31, 8'h32, 8'h33: return FMT_MODRM;
            8'h34: return FMT_I8;           // XOR AL, imm8
            8'h35: return FMT_IV;           // XOR eAX, imm16/32
            8'h36: return FMT_PREFIX;       // SS: segment override
            8'h37: return FMT_NONE;         // AAA
            // CMP
            8'h38, 8'h39, 8'h3A, 8'h3B: return FMT_MODRM;
            8'h3C: return FMT_I8;           // CMP AL, imm8
            8'h3D: return FMT_IV;           // CMP eAX, imm16/32
            8'h3E: return FMT_PREFIX;       // DS: segment override
            8'h3F: return FMT_NONE;         // AAS

            // ----- 0x40-0x5F: INC/DEC/PUSH/POP register -----
            8'h40, 8'h41, 8'h42, 8'h43,
            8'h44, 8'h45, 8'h46, 8'h47: return FMT_NONE;  // INC reg
            8'h48, 8'h49, 8'h4A, 8'h4B,
            8'h4C, 8'h4D, 8'h4E, 8'h4F: return FMT_NONE;  // DEC reg
            8'h50, 8'h51, 8'h52, 8'h53,
            8'h54, 8'h55, 8'h56, 8'h57: return FMT_NONE;  // PUSH reg
            8'h58, 8'h59, 8'h5A, 8'h5B,
            8'h5C, 8'h5D, 8'h5E, 8'h5F: return FMT_NONE;  // POP reg

            // ----- 0x60-0x6F: PUSHA/POPA, BOUND, ARPL, prefixes, PUSH/IMUL -----
            8'h60: return FMT_NONE;         // PUSHA
            8'h61: return FMT_NONE;         // POPA
            8'h62: return FMT_MODRM;        // BOUND r, m
            8'h63: return FMT_MODRM;        // ARPL r/m16, r16
            8'h64: return FMT_PREFIX;       // FS: segment override
            8'h65: return FMT_PREFIX;       // GS: segment override
            8'h66: return FMT_PREFIX;       // Operand-size override
            8'h67: return FMT_PREFIX;       // Address-size override
            8'h68: return FMT_IV;           // PUSH imm16/32
            8'h69: return FMT_MODRM_IV;     // IMUL r, r/m, imm16/32
            8'h6A: return FMT_I8;           // PUSH imm8
            8'h6B: return FMT_MODRM_I8;     // IMUL r, r/m, imm8
            8'h6C: return FMT_NONE;         // INSB
            8'h6D: return FMT_NONE;         // INSD
            8'h6E: return FMT_NONE;         // OUTSB
            8'h6F: return FMT_NONE;         // OUTSD

            // ----- 0x70-0x7F: Short conditional jumps -----
            8'h70, 8'h71, 8'h72, 8'h73,
            8'h74, 8'h75, 8'h76, 8'h77,
            8'h78, 8'h79, 8'h7A, 8'h7B,
            8'h7C, 8'h7D, 8'h7E, 8'h7F: return FMT_REL8;  // Jcc rel8

            // ----- 0x80-0x8F: Grp1, TEST, XCHG, MOV, LEA, POP -----
            8'h80: return FMT_MODRM_I8;     // Grp1 r/m8, imm8
            8'h81: return FMT_MODRM_IV;     // Grp1 r/m16/32, imm16/32
            8'h82: return FMT_MODRM_I8;     // Grp1 r/m8, imm8 (alias 80h)
            8'h83: return FMT_MODRM_I8;     // Grp1 r/m16/32, imm8 (sign-ext)
            8'h84: return FMT_MODRM;        // TEST r/m8, r8
            8'h85: return FMT_MODRM;        // TEST r/m16/32, r16/32
            8'h86: return FMT_MODRM;        // XCHG r/m8, r8
            8'h87: return FMT_MODRM;        // XCHG r/m16/32, r16/32
            8'h88: return FMT_MODRM;        // MOV r/m8, r8
            8'h89: return FMT_MODRM;        // MOV r/m16/32, r16/32
            8'h8A: return FMT_MODRM;        // MOV r8, r/m8
            8'h8B: return FMT_MODRM;        // MOV r16/32, r/m16/32
            8'h8C: return FMT_MODRM;        // MOV r/m16, Sreg
            8'h8D: return FMT_MODRM;        // LEA r16/32, m
            8'h8E: return FMT_MODRM;        // MOV Sreg, r/m16
            8'h8F: return FMT_MODRM;        // POP r/m16/32

            // ----- 0x90-0x9F: NOP/XCHG, CBW, CWD, CALL far, WAIT, flags -----
            8'h90: return FMT_NONE;         // NOP (XCHG EAX,EAX)
            8'h91, 8'h92, 8'h93,
            8'h94, 8'h95, 8'h96, 8'h97: return FMT_NONE;  // XCHG EAX, reg
            8'h98: return FMT_NONE;         // CBW / CWDE
            8'h99: return FMT_NONE;         // CWD / CDQ
            8'h9A: return FMT_FAR;          // CALL ptr16:16/32
            8'h9B: return FMT_NONE;         // WAIT / FWAIT
            8'h9C: return FMT_NONE;         // PUSHF / PUSHFD
            8'h9D: return FMT_NONE;         // POPF / POPFD
            8'h9E: return FMT_NONE;         // SAHF
            8'h9F: return FMT_NONE;         // LAHF

            // ----- 0xA0-0xAF: MOV moffs, string ops, TEST -----
            8'hA0: return FMT_ADDR;         // MOV AL, moffs8
            8'hA1: return FMT_ADDR;         // MOV eAX, moffs16/32
            8'hA2: return FMT_ADDR;         // MOV moffs8, AL
            8'hA3: return FMT_ADDR;         // MOV moffs16/32, eAX
            8'hA4: return FMT_NONE;         // MOVSB
            8'hA5: return FMT_NONE;         // MOVSD
            8'hA6: return FMT_NONE;         // CMPSB
            8'hA7: return FMT_NONE;         // CMPSD
            8'hA8: return FMT_I8;           // TEST AL, imm8
            8'hA9: return FMT_IV;           // TEST eAX, imm16/32
            8'hAA: return FMT_NONE;         // STOSB
            8'hAB: return FMT_NONE;         // STOSD
            8'hAC: return FMT_NONE;         // LODSB
            8'hAD: return FMT_NONE;         // LODSD
            8'hAE: return FMT_NONE;         // SCASB
            8'hAF: return FMT_NONE;         // SCASD

            // ----- 0xB0-0xBF: MOV reg, immediate -----
            8'hB0, 8'hB1, 8'hB2, 8'hB3,
            8'hB4, 8'hB5, 8'hB6, 8'hB7: return FMT_I8;   // MOV r8, imm8
            8'hB8, 8'hB9, 8'hBA, 8'hBB,
            8'hBC, 8'hBD, 8'hBE, 8'hBF: return FMT_IV;   // MOV r16/32, imm16/32

            // ----- 0xC0-0xCF: Shifts, RET, LES/LDS, MOV, ENTER, LEAVE, INT -----
            8'hC0: return FMT_MODRM_I8;     // Grp2 r/m8, imm8 (shift)
            8'hC1: return FMT_MODRM_I8;     // Grp2 r/m16/32, imm8 (shift)
            8'hC2: return FMT_I16;          // RET imm16 (near)
            8'hC3: return FMT_NONE;         // RET (near)
            8'hC4: return FMT_MODRM;        // LES r, m
            8'hC5: return FMT_MODRM;        // LDS r, m
            8'hC6: return FMT_MODRM_I8;     // MOV r/m8, imm8
            8'hC7: return FMT_MODRM_IV;     // MOV r/m16/32, imm16/32
            8'hC8: return FMT_ENTER;        // ENTER imm16, imm8
            8'hC9: return FMT_NONE;         // LEAVE
            8'hCA: return FMT_I16;          // RETF imm16
            8'hCB: return FMT_NONE;         // RETF
            8'hCC: return FMT_NONE;         // INT 3
            8'hCD: return FMT_I8;           // INT imm8
            8'hCE: return FMT_NONE;         // INTO
            8'hCF: return FMT_NONE;         // IRET / IRETD

            // ----- 0xD0-0xDF: Shifts, AAM/AAD, FPU escape -----
            8'hD0: return FMT_MODRM;        // Grp2 r/m8, 1
            8'hD1: return FMT_MODRM;        // Grp2 r/m16/32, 1
            8'hD2: return FMT_MODRM;        // Grp2 r/m8, CL
            8'hD3: return FMT_MODRM;        // Grp2 r/m16/32, CL
            8'hD4: return FMT_I8;           // AAM imm8
            8'hD5: return FMT_I8;           // AAD imm8
            8'hD6: return FMT_NONE;         // SALC (undocumented but common)
            8'hD7: return FMT_NONE;         // XLAT
            // x87 FPU escape (0xD8-0xDF all use ModRM)
            8'hD8, 8'hD9, 8'hDA, 8'hDB,
            8'hDC, 8'hDD, 8'hDE, 8'hDF: return FMT_MODRM;  // x87 FPU

            // ----- 0xE0-0xEF: Loops, IN/OUT, CALL/JMP -----
            8'hE0: return FMT_REL8;         // LOOPNE rel8
            8'hE1: return FMT_REL8;         // LOOPE rel8
            8'hE2: return FMT_REL8;         // LOOP rel8
            8'hE3: return FMT_REL8;         // JCXZ / JECXZ rel8
            8'hE4: return FMT_I8;           // IN AL, imm8
            8'hE5: return FMT_I8;           // IN eAX, imm8
            8'hE6: return FMT_I8;           // OUT imm8, AL
            8'hE7: return FMT_I8;           // OUT imm8, eAX
            8'hE8: return FMT_RELV;         // CALL rel16/32
            8'hE9: return FMT_RELV;         // JMP rel16/32
            8'hEA: return FMT_FAR;          // JMP ptr16:16/32
            8'hEB: return FMT_REL8;         // JMP rel8
            8'hEC: return FMT_NONE;         // IN AL, DX
            8'hED: return FMT_NONE;         // IN eAX, DX
            8'hEE: return FMT_NONE;         // OUT DX, AL
            8'hEF: return FMT_NONE;         // OUT DX, eAX

            // ----- 0xF0-0xFF: Prefixes, HLT, flags, Grp3/4/5 -----
            8'hF0: return FMT_PREFIX;       // LOCK
            8'hF1: return FMT_NONE;         // INT1 / ICEBP
            8'hF2: return FMT_PREFIX;       // REPNE
            8'hF3: return FMT_PREFIX;       // REP / REPE
            8'hF4: return FMT_NONE;         // HLT
            8'hF5: return FMT_NONE;         // CMC
            8'hF6: return FMT_GRP3B;        // Grp3 r/m8 (TEST has imm8)
            8'hF7: return FMT_GRP3V;        // Grp3 r/m16/32 (TEST has immv)
            8'hF8: return FMT_NONE;         // CLC
            8'hF9: return FMT_NONE;         // STC
            8'hFA: return FMT_NONE;         // CLI
            8'hFB: return FMT_NONE;         // STI
            8'hFC: return FMT_NONE;         // CLD
            8'hFD: return FMT_NONE;         // STD
            8'hFE: return FMT_MODRM;        // Grp4: INC/DEC r/m8
            8'hFF: return FMT_MODRM;        // Grp5: INC/DEC/CALL/JMP/PUSH r/m
            default: return FMT_INVALID;
        endcase
    endfunction


    // =========================================================================
    // Two-Byte Opcode Format Table (0x0F 0x00 - 0x0F 0xFF)
    // =========================================================================
    //
    // i486 two-byte opcodes. Many slots are reserved/invalid; only the
    // opcodes defined by the i486 (plus CPUID/RDTSC/RDMSR/WRMSR for
    // fabi386-specific MSR access) are populated.

    function automatic opcode_fmt_t get_2byte_fmt(logic [7:0] op);
        case (op)
            // ----- System instructions -----
            8'h00: return FMT_MODRM;        // Grp6: SLDT/STR/LLDT/LTR/VERR/VERW
            8'h01: return FMT_MODRM;        // Grp7: SGDT/SIDT/LGDT/LIDT/SMSW/LMSW/INVLPG
            8'h02: return FMT_MODRM;        // LAR r, r/m
            8'h03: return FMT_MODRM;        // LSL r, r/m
            8'h06: return FMT_NONE;         // CLTS
            8'h08: return FMT_NONE;         // INVD (486)
            8'h09: return FMT_NONE;         // WBINVD (486)

            // ----- Control/Debug register moves -----
            8'h20: return FMT_MODRM;        // MOV r32, CRn
            8'h21: return FMT_MODRM;        // MOV r32, DRn
            8'h22: return FMT_MODRM;        // MOV CRn, r32
            8'h23: return FMT_MODRM;        // MOV DRn, r32

            // ----- MSR / TSC (fabi386 extensions, Pentium-origin) -----
            8'h30: return FMT_NONE;         // WRMSR
            8'h31: return FMT_NONE;         // RDTSC
            8'h32: return FMT_NONE;         // RDMSR

            // ----- Pentium extensions (feature-gated) -----
            8'h33: return FMT_NONE;         // RDPMC
            8'h18: return FMT_MODRM;        // PREFETCH (hint, NOP completion)

            // ----- CMOVcc (Pentium Pro) -----
            8'h40, 8'h41, 8'h42, 8'h43,
            8'h44, 8'h45, 8'h46, 8'h47,
            8'h48, 8'h49, 8'h4A, 8'h4B,
            8'h4C, 8'h4D, 8'h4E, 8'h4F: return FMT_MODRM; // CMOVcc r, r/m

            // ----- POPCNT (0F B8) -----
            8'hB8: return FMT_MODRM;        // POPCNT r, r/m (F3 prefix distinguishes from JMPE)

            // ----- Near conditional jumps (long form) -----
            8'h80, 8'h81, 8'h82, 8'h83,
            8'h84, 8'h85, 8'h86, 8'h87,
            8'h88, 8'h89, 8'h8A, 8'h8B,
            8'h8C, 8'h8D, 8'h8E, 8'h8F: return FMT_RELV;  // Jcc rel16/32

            // ----- SETcc -----
            8'h90, 8'h91, 8'h92, 8'h93,
            8'h94, 8'h95, 8'h96, 8'h97,
            8'h98, 8'h99, 8'h9A, 8'h9B,
            8'h9C, 8'h9D, 8'h9E, 8'h9F: return FMT_MODRM; // SETcc r/m8

            // ----- Segment register push/pop -----
            8'hA0: return FMT_NONE;         // PUSH FS
            8'hA1: return FMT_NONE;         // POP FS
            8'hA2: return FMT_NONE;         // CPUID (486+/fabi386)
            8'hA3: return FMT_MODRM;        // BT r/m, r

            // ----- SHLD -----
            8'hA4: return FMT_MODRM_I8;     // SHLD r/m, r, imm8
            8'hA5: return FMT_MODRM;        // SHLD r/m, r, CL

            // ----- GS push/pop -----
            8'hA8: return FMT_NONE;         // PUSH GS
            8'hA9: return FMT_NONE;         // POP GS

            // ----- Bit operations -----
            8'hAB: return FMT_MODRM;        // BTS r/m, r

            // ----- Grp15: FXSAVE/FXRSTOR/CLFLUSH (0F AE) -----
            8'hAE: return FMT_MODRM;        // Grp15: CLFLUSH /7 (486+/fabi386)

            // ----- SHRD -----
            8'hAC: return FMT_MODRM_I8;     // SHRD r/m, r, imm8
            8'hAD: return FMT_MODRM;        // SHRD r/m, r, CL

            // ----- IMUL -----
            8'hAF: return FMT_MODRM;        // IMUL r, r/m

            // ----- 486 additions -----
            8'hB0: return FMT_MODRM;        // CMPXCHG r/m8, r8 (486)
            8'hB1: return FMT_MODRM;        // CMPXCHG r/m16/32, r16/32 (486)

            // ----- Segment load -----
            8'hB2: return FMT_MODRM;        // LSS r, m
            8'hB3: return FMT_MODRM;        // BTR r/m, r
            8'hB4: return FMT_MODRM;        // LFS r, m
            8'hB5: return FMT_MODRM;        // LGS r, m

            // ----- Zero/Sign extend -----
            8'hB6: return FMT_MODRM;        // MOVZX r16/32, r/m8
            8'hB7: return FMT_MODRM;        // MOVZX r32, r/m16

            // ----- Bit test with immediate -----
            8'hBA: return FMT_MODRM_I8;     // Grp8: BT/BTS/BTR/BTC r/m, imm8
            8'hBB: return FMT_MODRM;        // BTC r/m, r

            // ----- Bit scan -----
            8'hBC: return FMT_MODRM;        // BSF r, r/m
            8'hBD: return FMT_MODRM;        // BSR r, r/m

            // ----- Sign extend -----
            8'hBE: return FMT_MODRM;        // MOVSX r16/32, r/m8
            8'hBF: return FMT_MODRM;        // MOVSX r32, r/m16

            // ----- 486 additions -----
            8'hC0: return FMT_MODRM;        // XADD r/m8, r8 (486)
            8'hC1: return FMT_MODRM;        // XADD r/m16/32, r16/32 (486)

            // ----- BSWAP (register encoded in low 3 bits of opcode) -----
            8'hC8, 8'hC9, 8'hCA, 8'hCB,
            8'hCC, 8'hCD, 8'hCE, 8'hCF: return FMT_NONE;  // BSWAP reg (486)

            default: return FMT_INVALID;    // Reserved / undefined
        endcase
    endfunction


    // =========================================================================
    // Pre-Decode: Extract Instruction Metadata
    // =========================================================================
    //
    // Walks the byte stream: prefixes → opcode → format lookup → ModRM →
    // SIB → displacement → immediate. Returns total length and decoded fields.

    typedef struct packed {
        logic [3:0]  insn_len;      // Total instruction length (1-15)
        logic [7:0]  opcode;        // Primary opcode byte
        logic        is_0f;         // Two-byte opcode (0x0F prefix)
        logic        has_modrm;     // Instruction uses ModRM
        logic [1:0]  mod;           // ModRM.mod field
        logic [2:0]  reg_field;     // ModRM.reg (opcode extension for groups)
        logic [2:0]  rm;            // ModRM.rm field
        logic        pref_66;       // Operand-size override
        logic        pref_67;       // Address-size override
        logic        pref_lock;     // LOCK prefix
        logic [1:0]  pref_rep;      // 00=none, 01=REPNE, 10=REPE
        logic [2:0]  pref_seg;      // Segment override (0=none, 1=ES..6=GS)
        logic        is_prefix;     // Byte is a prefix, not a complete instruction
        logic        invalid;       // Undefined opcode
        opcode_fmt_t fmt;           // Encoding format
        logic [31:0] imm_value;     // Extracted immediate/displacement value
        logic        imm_is_rel;    // Immediate is a relative offset (for branches)

        // SIB / Address Mode (populated in Phase 3 for memory operands)
        logic        has_sib;       // SIB byte present
        logic [2:0]  sib_base;      // SIB.base (bits [2:0])
        logic [2:0]  sib_index;     // SIB.index (bits [5:3])
        logic [1:0]  sib_scale;     // SIB.scale (bits [7:6]): 00=x1, 01=x2, 10=x4, 11=x8
        logic        addr_32;       // Effective address size (after prefix toggle)
        logic        has_mem;       // Instruction references memory (mod != 11)

        // Branch classification
        logic        is_indirect;   // Indirect branch (FF /2, FF /4, FF /5, far CALL/JMP)

        // Effective operand size (for memory op sizing)
        logic        eff_op32;      // 1=dword, 0=word (after prefix toggle)

        // Far pointer segment selector (FMT_FAR: JMP/CALL far)
        logic [15:0] far_selector;
    } predecode_t;

    function automatic predecode_t pre_decode(
        input logic [127:0] stream,
        input logic         use_32bit   // Effective default operand/address size
    );
        predecode_t d;
        logic [3:0] pos;               // Current byte position
        opcode_fmt_t fmt;
        logic        eff_addr32;        // Effective address size after prefix
        logic        eff_op32;          // Effective operand size after prefix
        logic [7:0]  b;                 // Current byte under examination
        logic        has_sib;           // SIB byte present in this instruction
        logic [2:0]  sib_base;          // SIB.base field (bits [2:0] of SIB byte)
        logic [3:0]  disp_pos;          // Byte position of displacement
        logic [31:0] disp_value;        // Extracted displacement value
        logic [1:0]  disp_size;         // 0=none, 1=disp8, 2=disp32

        d = '0;
        pos = 0;
        disp_pos   = 0;
        disp_value = 32'h0;
        disp_size  = 2'd0;

        // ---- Phase 1: Consume Prefixes (up to 4) ----
        for (int i = 0; i < 4; i++) begin
            b = stream[pos*8 +: 8];
            case (b)
                8'h66: begin d.pref_66 = 1; pos++; end
                8'h67: begin d.pref_67 = 1; pos++; end
                8'h26: begin d.pref_seg = 3'd1; pos++; end  // ES:
                8'h2E: begin d.pref_seg = 3'd2; pos++; end  // CS:
                8'h36: begin d.pref_seg = 3'd3; pos++; end  // SS:
                8'h3E: begin d.pref_seg = 3'd4; pos++; end  // DS:
                8'h64: begin d.pref_seg = 3'd5; pos++; end  // FS:
                8'h65: begin d.pref_seg = 3'd6; pos++; end  // GS:
                8'hF0: begin d.pref_lock = 1;   pos++; end  // LOCK
                8'hF2: begin d.pref_rep = 2'b01; pos++; end // REPNE
                8'hF3: begin d.pref_rep = 2'b10; pos++; end // REP/REPE
                default: break; // Not a prefix — move to opcode
            endcase
        end

        // Effective sizes (default XOR prefix toggle)
        eff_op32   = use_32bit ^ d.pref_66;
        eff_addr32 = use_32bit ^ d.pref_67;
        d.eff_op32 = eff_op32;

        // ---- Phase 2: Identify Opcode ----
        b = stream[pos*8 +: 8];
        if (b == 8'h0F) begin
            d.is_0f  = 1;
            pos++;
            d.opcode = stream[pos*8 +: 8];
            pos++;
            fmt = get_2byte_fmt(d.opcode);
        end else begin
            d.opcode = b;
            pos++;
            fmt = get_1byte_fmt(d.opcode);
        end

        d.fmt = fmt;
        d.is_prefix = (fmt == FMT_PREFIX);
        d.invalid   = (fmt == FMT_INVALID);

        // ---- Phase 3: ModRM / SIB / Displacement ----
        // All formats containing "MODRM" in the name require the ModRM byte.
        d.has_modrm = (fmt == FMT_MODRM)    || (fmt == FMT_MODRM_I8) ||
                      (fmt == FMT_MODRM_IV)  || (fmt == FMT_GRP3B)    ||
                      (fmt == FMT_GRP3V);

        if (d.has_modrm) begin
            b = stream[pos*8 +: 8];
            d.mod       = b[7:6];
            d.reg_field = b[5:3];
            d.rm        = b[2:0];
            pos++;

            d.has_mem = (d.mod != 2'b11);
            d.addr_32 = eff_addr32;
            has_sib  = 0;
            sib_base = 3'b000;

            if (eff_addr32) begin
                // --- 32-bit addressing ---
                has_sib = (d.mod != 2'b11 && d.rm == 3'b100);
                d.has_sib = has_sib;

                // Peek at SIB byte to read ALL fields BEFORE advancing pos
                if (has_sib) begin
                    sib_base    = stream[pos*8 +: 3];       // SIB.base  = bits [2:0]
                    d.sib_base  = sib_base;
                    d.sib_index = stream[pos*8 + 3 +: 3];   // SIB.index = bits [5:3]
                    d.sib_scale = stream[pos*8 + 6 +: 2];   // SIB.scale = bits [7:6]
                end else begin
                    sib_base    = 3'b000;
                    d.sib_base  = 3'b000;
                    d.sib_index = 3'b000;
                    d.sib_scale = 2'b00;
                end

                // Consume SIB byte
                if (has_sib)
                    pos++;

                // Displacement — save position before consuming
                disp_pos = pos;
                case (d.mod)
                    2'b00: begin
                        if (has_sib) begin
                            // SIB with mod==00 and base==101: disp32, no base reg
                            if (sib_base == 3'b101) begin
                                disp_value = stream[pos*8 +: 32];
                                disp_size  = 2'd2;  // disp32
                                pos += 4;
                            end
                        end else begin
                            // No SIB: rm==101 means disp32 (no base register)
                            if (d.rm == 3'b101) begin
                                disp_value = stream[pos*8 +: 32];
                                disp_size  = 2'd2;  // disp32
                                pos += 4;
                            end
                        end
                    end
                    2'b01: begin  // disp8 (sign-extended)
                        disp_value = {{24{stream[pos*8 + 7]}}, stream[pos*8 +: 8]};
                        disp_size  = 2'd1;
                        pos += 1;
                    end
                    2'b10: begin  // disp32
                        disp_value = stream[pos*8 +: 32];
                        disp_size  = 2'd2;
                        pos += 4;
                    end
                    2'b11: ;  // Register direct, no displacement
                endcase
            end else begin
                // --- 16-bit addressing ---
                // No SIB byte in 16-bit mode

                case (d.mod)
                    2'b00: begin
                        if (d.rm == 3'b110)
                            pos += 2;   // disp16 (direct address)
                    end
                    2'b01: pos += 1;    // disp8
                    2'b10: pos += 2;    // disp16
                    2'b11: ;            // Register direct
                endcase
            end
        end

        // ---- Phase 4: Immediate Operand Extraction ----
        // Extract the actual value from the byte stream at position 'pos',
        // then advance pos by the immediate width.
        d.imm_value = 32'h0;
        d.imm_is_rel = 0;

        case (fmt)
            FMT_I8, FMT_MODRM_I8: begin
                // 8-bit immediate, zero-extended
                d.imm_value = {24'h0, stream[pos*8 +: 8]};
                pos += 1;
            end

            FMT_REL8: begin
                // 8-bit relative offset, sign-extended to 32 bits
                d.imm_value = {{24{stream[pos*8 + 7]}}, stream[pos*8 +: 8]};
                d.imm_is_rel = 1;
                pos += 1;
            end

            FMT_IV, FMT_MODRM_IV: begin
                if (eff_op32) begin
                    d.imm_value = stream[pos*8 +: 32];
                    pos += 4;
                end else begin
                    d.imm_value = {16'h0, stream[pos*8 +: 16]};
                    pos += 2;
                end
            end

            FMT_RELV: begin
                // Relative offset, sign-extended
                d.imm_is_rel = 1;
                if (eff_op32) begin
                    d.imm_value = stream[pos*8 +: 32];
                    pos += 4;
                end else begin
                    d.imm_value = {{16{stream[pos*8 + 15]}}, stream[pos*8 +: 16]};
                    pos += 2;
                end
            end

            FMT_I16: begin
                // Always 16-bit (RET imm16, RETF imm16)
                d.imm_value = {16'h0, stream[pos*8 +: 16]};
                pos += 2;
            end

            FMT_ADDR: begin
                // Memory offset — size follows address size, not operand size
                if (eff_addr32) begin
                    d.imm_value = stream[pos*8 +: 32];
                    pos += 4;
                end else begin
                    d.imm_value = {16'h0, stream[pos*8 +: 16]};
                    pos += 2;
                end
            end

            FMT_FAR: begin
                // ptr16:16 or ptr16:32 — extract offset + segment selector
                if (eff_op32) begin
                    d.imm_value    = stream[pos*8 +: 32];
                    d.far_selector = stream[(pos+4)*8 +: 16];
                    pos += 6;   // offset32 + seg16
                end else begin
                    d.imm_value    = {16'h0, stream[pos*8 +: 16]};
                    d.far_selector = stream[(pos+2)*8 +: 16];
                    pos += 4;   // offset16 + seg16
                end
            end

            FMT_ENTER: begin
                // ENTER imm16, imm8 — pack both: imm16 in [15:0], nesting in [23:16]
                d.imm_value = {8'h0, stream[(pos+2)*8 +: 8], stream[pos*8 +: 16]};
                pos += 3;
            end

            FMT_GRP3B: begin
                // Grp3 byte: TEST (reg==000 or 001) has imm8
                if (d.reg_field[2:1] == 2'b00) begin
                    d.imm_value = {24'h0, stream[pos*8 +: 8]};
                    pos += 1;
                end
            end

            FMT_GRP3V: begin
                // Grp3 word/dword: TEST has imm16/32
                if (d.reg_field[2:1] == 2'b00) begin
                    if (eff_op32) begin
                        d.imm_value = stream[pos*8 +: 32];
                        pos += 4;
                    end else begin
                        d.imm_value = {16'h0, stream[pos*8 +: 16]};
                        pos += 2;
                    end
                end
            end

            default: ; // FMT_NONE, FMT_MODRM (no immediate), FMT_PREFIX, FMT_INVALID
        endcase

        // ---- Phase 4b: Displacement → imm_value for pure-ModRM formats ----
        // For FMT_MODRM (no immediate operand), the displacement from Phase 3
        // is the only offset. Store it in imm_value so the AGU can use it.
        // Formats with immediate (FMT_MODRM_I8, FMT_MODRM_IV, etc.) keep
        // imm_value from Phase 4; their displacement needs a separate path.
        if (fmt == FMT_MODRM && disp_size != 2'd0) begin
            d.imm_value = disp_value;
        end

        // ---- Phase 5: Indirect Branch Detection ----
        // Indirect branches have no computable target at decode time.
        // The branch predictor needs a separate signal for these.
        d.is_indirect = 0;
        if (!d.is_0f && d.opcode == 8'hFF && d.has_modrm) begin
            // Grp5: /2 = CALL near indirect, /4 = JMP near indirect, /5 = JMP far indirect
            if (d.reg_field == 3'b010 || d.reg_field == 3'b100 || d.reg_field == 3'b101)
                d.is_indirect = 1;
            // /3 = CALL far indirect (also indirect, but microcode)
            if (d.reg_field == 3'b011)
                d.is_indirect = 1;
        end
        // Far CALL/JMP with pointer in instruction stream aren't truly indirect
        // (target is in the instruction bytes), but we treat them as microcode anyway

        // Instruction length from byte position
        d.insn_len = pos;

        return d;
    endfunction


    // =========================================================================
    // Byte-Aligned Stream Shifter (V-Pipe Window)
    // =========================================================================
    //
    // Instead of a 128-bit variable barrel shifter (high fan-out, long path),
    // use a 16:1 byte-aligned mux. The synthesis tool can map this to a LUT
    // cascade with (* parallel_case *) guidance. On Cyclone V this maps to
    // ~200 ALMs vs ~400+ for a generic barrel shift.

    // =========================================================================
    // 2-Stage Pipelined Decode
    // =========================================================================
    //
    // Stage 1 (cycle N):   U-pipe pre_decode + v_stream_mux → pipeline reg
    // Stage 2 (cycle N+1): V-pipe pre_decode + classify/reg_usage → output reg
    //
    // Both U and V pipe results emerge on the same clock edge (stage 2).
    // This breaks the critical path: U_len → v_mux → V_decode, which was
    // ~8.5 ns single-cycle. Each stage is now ~4-5 ns, meeting 150 MHz.
    //
    // Decode latency: 2 cycles from fetch_valid to instr_u/v_valid.
    // The branch predictor hides this on predicted-taken branches.

    // Effective default size: V86 mode forces 16-bit regardless of CS.D
    logic eff_default_32;
    assign eff_default_32 = v86_mode ? 1'b0 : default_32;

    // --- Stage 1: U-pipe pre-decode (combinational) ---
    predecode_t pd_u_s1;

    always_comb begin
        pd_u_s1 = pre_decode(fetch_block, eff_default_32);
    end

    // --- V-pipe byte stream: shift fetch block by U-pipe instruction length ---
    logic [127:0] v_stream;

    always_comb begin : v_stream_mux
        case (pd_u_s1.insn_len)
            4'd0:  v_stream = fetch_block;
            4'd1:  v_stream = {8'h0,   fetch_block[127:8]};
            4'd2:  v_stream = {16'h0,  fetch_block[127:16]};
            4'd3:  v_stream = {24'h0,  fetch_block[127:24]};
            4'd4:  v_stream = {32'h0,  fetch_block[127:32]};
            4'd5:  v_stream = {40'h0,  fetch_block[127:40]};
            4'd6:  v_stream = {48'h0,  fetch_block[127:48]};
            4'd7:  v_stream = {56'h0,  fetch_block[127:56]};
            4'd8:  v_stream = {64'h0,  fetch_block[127:64]};
            4'd9:  v_stream = {72'h0,  fetch_block[127:72]};
            4'd10: v_stream = {80'h0,  fetch_block[127:80]};
            4'd11: v_stream = {88'h0,  fetch_block[127:88]};
            4'd12: v_stream = {96'h0,  fetch_block[127:96]};
            4'd13: v_stream = {104'h0, fetch_block[127:104]};
            4'd14: v_stream = {112'h0, fetch_block[127:112]};
            4'd15: v_stream = {120'h0, fetch_block[127:120]};
        endcase
    end

    // --- Pipeline Register: Stage 1 → Stage 2 ---
    logic [127:0]  v_stream_r;       // Registered V-pipe byte stream
    predecode_t    pd_u_r;           // Registered U-pipe pre-decode result
    logic [31:0]   u_pc_r;           // Registered U-pipe PC
    logic [31:0]   v_pc_r;           // Registered V-pipe PC (= pc + U_len)
    logic [31:0]   u_raw_r;          // Registered U-pipe raw instruction bytes
    logic          eff_default_32_r; // Registered mode for V-pipe decode
    logic          s1_valid;         // Stage 1 output valid
    logic          pipe_advance;     // Pipeline advances when stage 2 can accept

    assign pipe_advance = !s1_valid || rename_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_stream_r       <= '0;
            pd_u_r           <= '0;
            u_pc_r           <= 32'h0;
            v_pc_r           <= 32'h0;
            u_raw_r          <= 32'h0;
            eff_default_32_r <= 0;
            s1_valid         <= 0;
        end else if (pipe_advance) begin
            if (fetch_valid) begin
                v_stream_r       <= v_stream;
                pd_u_r           <= pd_u_s1;
                u_pc_r           <= current_pc;
                v_pc_r           <= current_pc + {28'h0, pd_u_s1.insn_len};
                u_raw_r          <= fetch_block[31:0];
                eff_default_32_r <= eff_default_32;
                s1_valid         <= 1;
            end else begin
                s1_valid         <= 0;
            end
        end
    end

    // fetch_ack: tell fetch unit we consumed this block (stage 1 accepted it)
    assign fetch_ack = fetch_valid && pipe_advance;

    // --- Stage 2: V-pipe pre-decode + classification (combinational) ---
    predecode_t pd_u, pd_v;

    always_comb begin
        pd_u = pd_u_r;  // U-pipe uses registered stage 1 result
        pd_v = pre_decode(v_stream_r, eff_default_32_r);  // V-pipe from registered stream
    end


    // =========================================================================
    // Operation Classification
    // =========================================================================
    // -----------------------------------------------------------------
    // Derive memory operand size from predecode (0=byte, 1=word, 2=dword)
    // -----------------------------------------------------------------
    // For x86 register/memory ALU forms, bit[0] of the opcode selects
    // byte(0) vs word/dword(1). PUSH/POP/LEA and string ops are always
    // word/dword. Two-byte (0F) MOVZX/MOVSX have explicit 8/16 source.
    // This is a best-effort heuristic for P2a; sign-extension info is
    // handled separately via agu_ld_signed (TODO).
    function automatic logic [1:0] derive_mem_size(predecode_t pd);
        if (pd.is_0f) begin
            // MOVZX r,r/m8  (0F B6): byte source
            // MOVSX r,r/m8  (0F BE): byte source
            if (pd.opcode == 8'hB6 || pd.opcode == 8'hBE)
                return 2'd0; // byte
            // MOVZX r,r/m16 (0F B7): word source
            // MOVSX r,r/m16 (0F BF): word source
            if (pd.opcode == 8'hB7 || pd.opcode == 8'hBF)
                return 2'd1; // word
            // Default 2-byte: use eff_op32
            return pd.eff_op32 ? 2'd2 : 2'd1;
        end

        // Byte-sized forms: ALU r/m8 (bit[0]=0 for opcodes 00-3F even),
        // MOV r/m8 (88,8A,C6), TEST/XCHG r/m8, etc.
        case (pd.opcode) inside
            8'h88, 8'h8A, 8'hC6, 8'hA0, 8'hA2: return 2'd0; // MOV byte forms
            [8'h00:8'h3F]: begin
                // ALU family: bit[0]=0 → byte
                if (!pd.opcode[0])
                    return 2'd0;
                return pd.eff_op32 ? 2'd2 : 2'd1;
            end
            // PUSH/POP/LEA always word/dword
            [8'h50:8'h5F], 8'h68, 8'h6A, 8'h8D, 8'h9C, 8'h9D:
                return pd.eff_op32 ? 2'd2 : 2'd1;
            // MOV r/m16/32 forms
            8'h89, 8'h8B, 8'hC7, 8'hA1, 8'hA3:
                return pd.eff_op32 ? 2'd2 : 2'd1;
            // Group 1 immediate: F6=byte, F7=word/dword
            8'hF6: return 2'd0;
            8'hF7: return pd.eff_op32 ? 2'd2 : 2'd1;
            // Group 2 shifts: C0/D0/D2=byte, C1/D1/D3=word/dword
            8'hC0, 8'hD0, 8'hD2: return 2'd0;
            8'hC1, 8'hD1, 8'hD3: return pd.eff_op32 ? 2'd2 : 2'd1;
            // Group 3/5 (FE byte, FF word/dword)
            8'hFE: return 2'd0;
            8'hFF: return pd.eff_op32 ? 2'd2 : 2'd1;
            default: return pd.eff_op32 ? 2'd2 : 2'd1;
        endcase
    endfunction

    //
    // Map opcode to op_type_t for the OoO pipeline. This determines which
    // execution unit handles the instruction.

    function automatic op_type_t classify_op(predecode_t pd);
        if (pd.invalid || pd.is_prefix)
            return OP_ALU_REG; // Will be flagged invalid separately

        // ----- Two-byte opcodes (0x0F prefix) -----
        if (pd.is_0f) begin
            // Jcc near (0F 80-8F)
            if (pd.opcode[7:4] == 4'h8)
                return OP_BRANCH;

            // CMOVcc (0F 40-4F) — conditional move, Pentium extensions
            if (CONF_ENABLE_PENTIUM_EXT && pd.opcode[7:4] == 4'h4)
                return (pd.mod != 2'b11) ? OP_LOAD : OP_CMOV;

            // POPCNT (0F B8 with F3 prefix) — Nehalem
            if (CONF_ENABLE_NEHALEM_EXT && pd.opcode == 8'hB8 && pd.pref_rep == 2'b10)
                return (pd.mod != 2'b11) ? OP_LOAD : OP_BITCOUNT;

            // LZCNT (0F BD with F3 prefix) / TZCNT (0F BC with F3 prefix) — Nehalem
            if (CONF_ENABLE_NEHALEM_EXT && pd.pref_rep == 2'b10 &&
                (pd.opcode == 8'hBD || pd.opcode == 8'hBC))
                return (pd.mod != 2'b11) ? OP_LOAD : OP_BITCOUNT;

            // PREFETCH (0F 18) — hint, NOP completion — PIII/P4
            if (CONF_ENABLE_P3_EXT && pd.opcode == 8'h18)
                return OP_ALU_REG;

            // MFENCE/LFENCE/SFENCE (0F AE /5,/6,/7 with mod=11) — PIII/P4
            if (CONF_ENABLE_P3_EXT && pd.opcode == 8'hAE && pd.mod == 2'b11 &&
                pd.reg_field >= 3'd5)
                return OP_FENCE;

            // RDPMC (0F 33)
            if (CONF_ENABLE_PENTIUM_EXT && pd.opcode == 8'h33)
                return OP_SYS_CALL;

            // System: WRMSR/RDMSR/RDTSC, INVD/WBINVD, CLTS, CPUID
            case (pd.opcode)
                8'h30, 8'h31, 8'h32,              // WRMSR, RDTSC, RDMSR
                8'h08, 8'h09,                      // INVD, WBINVD
                8'h06:                              // CLTS
                    return OP_SYS_CALL;
                8'hA2:                              // CPUID
                    return OP_MICROCODE;            // Multi-cycle: EAX→EAX/EBX/ECX/EDX

                // Grp6: SLDT/STR/LLDT/LTR
                8'h00:
                    return OP_SYS_CALL;
                // Grp7: SGDT/SIDT/LGDT/LIDT/SMSW/LMSW/INVLPG
                8'h01: begin
                    if (pd.reg_field == 3'd2 || pd.reg_field == 3'd3)
                        return OP_MICROCODE;  // LGDT/LIDT → microcode
                    else
                        return OP_SYS_CALL;   // SGDT/SIDT/SMSW/LMSW/INVLPG
                end

                // Grp15 (0F AE): FXSAVE/FXRSTOR/CLFLUSH fallback
                // Fence forms (mod=11, reg>=5) caught above when P3 enabled
                8'hAE:
                    return OP_SYS_CALL;

                // MOV CR — routed through microcode (UCMD_LOAD_CR / UCMD_STORE_CR)
                8'h20, 8'h22:
                    return OP_MICROCODE;
                // MOV DR — system call (DR access, deferred)
                8'h21, 8'h23:
                    return OP_SYS_CALL;

                // SETcc (0F 90-9F) — simple ALU producing 0/1
                8'h90, 8'h91, 8'h92, 8'h93,
                8'h94, 8'h95, 8'h96, 8'h97,
                8'h98, 8'h99, 8'h9A, 8'h9B,
                8'h9C, 8'h9D, 8'h9E, 8'h9F:
                    return (pd.mod != 2'b11) ? OP_STORE : OP_ALU_REG;

                // CMPXCHG/XADD (486) — read-modify-write
                8'hB0, 8'hB1, 8'hC0, 8'hC1:
                    return (pd.mod != 2'b11) ? OP_LOAD : OP_ALU_REG;

                // MOVZX/MOVSX — loads when memory source
                8'hB6, 8'hB7, 8'hBE, 8'hBF:
                    return (pd.mod != 2'b11) ? OP_LOAD : OP_ALU_REG;

                // BSWAP — register-only ALU
                8'hC8, 8'hC9, 8'hCA, 8'hCB,
                8'hCC, 8'hCD, 8'hCE, 8'hCF:
                    return OP_ALU_REG;

                // Bit test/scan/set (BT/BTS/BTR/BTC/BSF/BSR) — may access memory
                8'hA3, 8'hAB, 8'hB3, 8'hBB,
                8'hBA, 8'hBC, 8'hBD:
                    return (pd.has_modrm && pd.mod != 2'b11) ? OP_LOAD : OP_ALU_REG;

                // SHLD/SHRD — shift with register source
                8'hA4, 8'hA5, 8'hAC, 8'hAD:
                    return (pd.mod != 2'b11) ? OP_LOAD : OP_ALU_REG;

                // IMUL r, r/m
                8'hAF:
                    return (pd.mod != 2'b11) ? OP_LOAD : OP_ALU_REG;

                // Segment register loads (LSS/LFS/LGS) — memory load
                8'hB2, 8'hB4, 8'hB5:
                    return OP_LOAD;

                // LAR/LSL — protected mode
                8'h02, 8'h03:
                    return OP_SYS_CALL;

                // PUSH/POP FS/GS
                8'hA0, 8'hA8:                      // PUSH FS/GS
                    return OP_STORE;
                8'hA1, 8'hA9:                      // POP FS/GS
                    return OP_LOAD;

                default:
                    return OP_ALU_REG;
            endcase
        end

        // ----- One-byte opcodes -----

        // x87 FPU (0xD8-0xDF)
        if (pd.opcode[7:3] == 5'b11011)
            return OP_FLOAT;

        // Branches: Jcc short, CALL, JMP, RET, RETF, IRET, LOOPx/JCXZ
        case (pd.opcode)
            8'h70, 8'h71, 8'h72, 8'h73,
            8'h74, 8'h75, 8'h76, 8'h77,
            8'h78, 8'h79, 8'h7A, 8'h7B,
            8'h7C, 8'h7D, 8'h7E, 8'h7F,           // Jcc short
            8'hE8, 8'hE9, 8'hEB,                    // CALL/JMP near
            8'hC2, 8'hC3,                            // RET near
            8'hCA, 8'hCB:                            // RETF
                return OP_BRANCH;
            default: ;
        endcase

        // Far CALL/JMP, IRET — microcode branches
        case (pd.opcode)
            8'h9A, 8'hEA:                            // Far CALL/JMP
                return OP_MICROCODE;
            8'hCF:                                    // IRET
                return OP_MICROCODE;
            default: ;
        endcase

        // LOOPx/JCXZ (E0-E3)
        if (pd.opcode[7:2] == 6'b111000)
            return OP_BRANCH;

        // LEA — pure address calculation, no memory access
        if (pd.opcode == 8'h8D)
            return OP_ALU_REG;

        // MOV moffs/reg — pure loads and stores
        case (pd.opcode)
            8'hA0, 8'hA1:                            // MOV AL/eAX, moffs
                return OP_LOAD;
            8'hA2, 8'hA3:                            // MOV moffs, AL/eAX
                return OP_STORE;
            8'h8A, 8'h8B:                            // MOV reg, r/m
                return (pd.mod != 2'b11) ? OP_LOAD : OP_ALU_REG;
            8'h88, 8'h89:                            // MOV r/m, reg
                return (pd.mod != 2'b11) ? OP_STORE : OP_ALU_REG;
            8'hC6, 8'hC7:                            // MOV r/m, imm
                return (pd.mod != 2'b11) ? OP_STORE : OP_ALU_IMM;
            8'h8C:                                    // MOV r/m, Sreg
                return (pd.mod != 2'b11) ? OP_STORE : OP_ALU_REG;
            8'h8E:                                    // MOV Sreg, r/m
                return (pd.mod != 2'b11) ? OP_LOAD : OP_ALU_REG;
            default: ;
        endcase

        // PUSH/POP register — stack store/load
        if (pd.opcode[7:3] == 5'b01010)              // PUSH reg (50-57)
            return OP_STORE;
        if (pd.opcode[7:3] == 5'b01011)              // POP reg (58-5F)
            return OP_LOAD;

        // PUSH/POP segment registers
        case (pd.opcode)
            8'h06, 8'h0E, 8'h16, 8'h1E:             // PUSH ES/CS/SS/DS
                return OP_STORE;
            8'h07, 8'h17, 8'h1F:                     // POP ES/SS/DS
                return OP_LOAD;
            default: ;
        endcase

        // PUSH imm
        if (pd.opcode == 8'h68 || pd.opcode == 8'h6A)
            return OP_STORE;

        // POP r/m (8F)
        if (pd.opcode == 8'h8F)
            return OP_LOAD;

        // PUSHF/POPF — routed through microcode (UCMD_PUSH_FLAGS / UCMD_POP_FLAGS)
        if (pd.opcode == 8'h9C) return OP_MICROCODE;
        if (pd.opcode == 8'h9D) return OP_MICROCODE;

        // String operations — microcode (REP prefix makes them multi-cycle)
        case (pd.opcode)
            8'hA4, 8'hA5:                            // MOVSB/MOVSD
                return OP_MICROCODE;
            8'hA6, 8'hA7:                            // CMPSB/CMPSD
                return OP_MICROCODE;
            8'hAA, 8'hAB:                            // STOSB/STOSD
                return OP_MICROCODE;
            8'hAC, 8'hAD:                            // LODSB/LODSD
                return OP_MICROCODE;
            8'hAE, 8'hAF:                            // SCASB/SCASD
                return OP_MICROCODE;
            8'h6C, 8'h6D:                            // INSB/INSD
                return OP_IO_READ;
            8'h6E, 8'h6F:                            // OUTSB/OUTSD
                return OP_IO_WRITE;
            default: ;
        endcase

        // I/O port access
        case (pd.opcode)
            8'hE4, 8'hE5, 8'hEC, 8'hED:             // IN
                return OP_IO_READ;
            8'hE6, 8'hE7, 8'hEE, 8'hEF:             // OUT
                return OP_IO_WRITE;
            default: ;
        endcase

        `ifdef VERILATOR
        // Test opcode 0xD6: microcode mem bring-up (PUSH EAX → POP EBX)
        if (pd.opcode == 8'hD6) return OP_MICROCODE;
        `endif

        // Microcode (complex multi-cycle)
        case (pd.opcode)
            8'h60, 8'h61:                            // PUSHA/POPA
                return OP_MICROCODE;
            8'hC8:                                    // ENTER
                return OP_MICROCODE;
            8'hCC, 8'hCD, 8'hCE:                     // INT 3, INT n, INTO
                return OP_MICROCODE;
            8'h62:                                    // BOUND
                return OP_MICROCODE;
            8'hD7:                                    // XLAT
                return OP_LOAD;
            8'h63:                                    // ARPL
                return OP_SYS_CALL;
            default: ;
        endcase

        // HLT, WAIT
        if (pd.opcode == 8'hF4) return OP_SYS_CALL;
        if (pd.opcode == 8'h9B) return OP_SYS_CALL; // FWAIT

        // Grp3 (F6/F7): TEST/NOT/NEG/MUL/IMUL/DIV/IDIV — sub-decode by reg_field
        if (pd.opcode == 8'hF6 || pd.opcode == 8'hF7) begin
            case (pd.reg_field)
                3'b000, 3'b001: // TEST — ALU with immediate
                    return (pd.mod != 2'b11) ? OP_LOAD : OP_ALU_IMM;
                3'b010, 3'b011: // NOT/NEG — unary ALU
                    return (pd.mod != 2'b11) ? OP_LOAD : OP_ALU_REG;
                3'b100, 3'b101, 3'b110, 3'b111: // MUL/IMUL/DIV/IDIV — microcode
                    return OP_MICROCODE;
            endcase
        end

        // Grp4 (FE): INC/DEC r/m8
        if (pd.opcode == 8'hFE)
            return (pd.mod != 2'b11) ? OP_LOAD : OP_ALU_REG;

        // Grp5 (FF): sub-decode by reg_field
        if (pd.opcode == 8'hFF) begin
            case (pd.reg_field)
                3'b000, 3'b001: // INC/DEC r/m
                    return (pd.mod != 2'b11) ? OP_LOAD : OP_ALU_REG;
                3'b010:         // CALL r/m (near indirect)
                    return OP_BRANCH;
                3'b011:         // CALL m (far indirect)
                    return OP_MICROCODE;
                3'b100:         // JMP r/m (near indirect)
                    return OP_BRANCH;
                3'b101:         // JMP m (far indirect)
                    return OP_MICROCODE;
                3'b110:         // PUSH r/m
                    return (pd.mod != 2'b11) ? OP_LOAD : OP_STORE;
                default:
                    return OP_ALU_REG;
            endcase
        end

        // Shift/Rotate Grp2 (C0/C1/D0/D1/D2/D3)
        case (pd.opcode)
            8'hC0, 8'hC1, 8'hD0, 8'hD1, 8'hD2, 8'hD3:
                return (pd.mod != 2'b11) ? OP_LOAD : OP_ALU_REG;
            default: ;
        endcase

        // INC/DEC register (40-4F) — simple ALU
        if (pd.opcode[7:4] == 4'h4)
            return OP_ALU_REG;

        // XCHG EAX,reg (91-97)
        if (pd.opcode[7:3] == 5'b10010 && pd.opcode[2:0] != 3'b000)
            return OP_ALU_REG;

        // LES/LDS (C4/C5) — load segment:offset
        if (pd.opcode == 8'hC4 || pd.opcode == 8'hC5)
            return OP_LOAD;

        // LEAVE (C9) — simple stack frame teardown
        if (pd.opcode == 8'hC9)
            return OP_ALU_REG;

        // ALU r/m, r / r, r/m (00-3F, even bytes are ModRM)
        // Grp1 (80-83): ALU r/m, imm
        if (pd.has_modrm && pd.mod != 2'b11) begin
            // Memory operand present — this is a load-op or store-op
            // Direction bit (bit 1): 1 = reg is dest (load from mem), 0 = r/m is dest (RMW)
            if (pd.opcode[7:6] == 2'b00 && pd.opcode[5:3] != 3'b111) begin
                // Standard ALU (00-3F minus CMP which is read-only)
                return pd.opcode[1] ? OP_LOAD : OP_LOAD; // Both need memory read
            end
            if (pd.opcode[7:2] == 6'b100000)         // Grp1 (80-83)
                return OP_LOAD;
            if (pd.opcode == 8'h84 || pd.opcode == 8'h85) // TEST r/m, r
                return OP_LOAD;
            if (pd.opcode == 8'h86 || pd.opcode == 8'h87) // XCHG r/m, r
                return OP_LOAD;
            return OP_LOAD; // Conservative: memory-referencing instructions need load
        end

        // Accumulator-immediate (04/05, 0C/0D, 14/15, 1C/1D, 24/25, 2C/2D, 34/35, 3C/3D)
        if (pd.opcode[7:6] == 2'b00 && (pd.opcode[2:0] == 3'b100 || pd.opcode[2:0] == 3'b101))
            return OP_ALU_IMM;

        // IMUL r,r/m,imm (69/6B)
        if (pd.opcode == 8'h69 || pd.opcode == 8'h6B)
            return OP_ALU_IMM;

        // MOV reg, imm (B0-BF)
        if (pd.opcode[7:4] == 4'hB)
            return OP_ALU_IMM;

        // TEST AL/eAX, imm (A8/A9)
        if (pd.opcode == 8'hA8 || pd.opcode == 8'hA9)
            return OP_ALU_IMM;

        // NOP
        if (pd.opcode == 8'h90)
            return OP_ALU_REG;

        // CBW/CWDE, CWD/CDQ, SAHF, LAHF, DAA, DAS, AAA, AAS, AAM, AAD
        return OP_ALU_REG;
    endfunction


    // =========================================================================
    // Architectural Register Extraction
    // =========================================================================
    //
    // For the renamer: identify which x86 registers are read/written.
    // Uses 3-bit encoding: 000=EAX, 001=ECX, 010=EDX, 011=EBX,
    //                       100=ESP, 101=EBP, 110=ESI, 111=EDI

    // Register encoding constants
    localparam [2:0] REG_EAX = 3'b000, REG_ECX = 3'b001, REG_EDX = 3'b010,
                     REG_EBX = 3'b011, REG_ESP = 3'b100, REG_EBP = 3'b101,
                     REG_ESI = 3'b110, REG_EDI = 3'b111;

    // Reg usage result: which architectural registers are read/written
    typedef struct packed {
        logic [2:0] dest;        // Primary destination register
        logic       dest_valid;  // This instruction writes dest
        logic [2:0] src_a;       // Primary source register
        logic       src_a_valid; // This instruction reads src_a
        logic [2:0] src_b;       // Secondary source (r/m or implicit)
        logic       src_b_valid; // This instruction reads src_b
        logic       writes_esp;  // Implicit ESP modification (PUSH/POP/CALL/RET)
        logic       reads_flags; // Reads EFLAGS (Jcc, SETcc, ADC, SBB, etc.)
        logic       writes_flags;// Writes EFLAGS

        // Address Generation (for memory-referencing instructions)
        logic [2:0] addr_base;       // Base register for AGU
        logic       addr_base_valid; // Instruction has a base register
        logic [2:0] addr_index;      // Index register for AGU
        logic       addr_index_valid;// Instruction has an index register
        logic [1:0] addr_scale;      // Scale factor: 00=x1, 01=x2, 10=x4, 11=x8
        logic [2:0] addr_seg;        // Effective segment: 0=DS, 1=ES, 2=CS, 3=SS, 4=FS, 5=GS
    } reg_usage_t;

    // Packed struct for address register extraction (return type)
    typedef struct packed {
        logic [2:0] addr_base;
        logic       addr_base_valid;
        logic [2:0] addr_index;
        logic       addr_index_valid;
        logic [1:0] addr_scale;
        logic [2:0] addr_seg;
    } addr_info_t;

    // =========================================================================
    // Address Register Extraction Helper
    // =========================================================================
    //
    // Parses the ModRM + SIB addressing mode to determine which registers
    // are used for address generation (base, index, scale). Also resolves
    // the effective segment register (default DS/SS with prefix override).
    //
    // In 32-bit mode with SIB:
    //   [base + index*scale + disp]
    //   Special: index == 100 (ESP) means no index
    //   Special: mod==00 && base==101 means disp32 only (no base)
    //
    // In 32-bit mode without SIB:
    //   [reg + disp]     where reg = rm field
    //   Special: mod==00 && rm==101 means disp32 only
    //
    // In 16-bit mode (no SIB ever):
    //   Combination of BX, BP, SI, DI per the 16-bit addressing table
    //   Special: mod==00 && rm==110 means disp16 only

    function automatic addr_info_t extract_addr_regs(
        input  predecode_t pd
    );
        addr_info_t ai;
        ai.addr_base       = 3'b000;
        ai.addr_base_valid = 0;
        ai.addr_index       = 3'b000;
        ai.addr_index_valid = 0;
        ai.addr_scale       = 2'b00;

        // Default segment: DS for most, SS for EBP/ESP-based addressing
        // (overridden below if segment prefix present)
        ai.addr_seg = 3'd0; // DS default

        if (!pd.has_modrm || pd.mod == 2'b11)
            return ai; // Register-direct, no memory address

        if (pd.addr_32) begin
            // ---- 32-bit addressing ----
            if (pd.has_sib) begin
                // SIB byte present: base from SIB.base, index from SIB.index
                ai.addr_scale = pd.sib_scale;

                // Index register (SIB.index == 100 means no index / "none")
                if (pd.sib_index != 3'b100) begin
                    ai.addr_index = pd.sib_index;
                    ai.addr_index_valid = 1;
                end

                // Base register
                if (pd.mod == 2'b00 && pd.sib_base == 3'b101) begin
                    // mod==00, base==101: disp32 only, no base register
                    ai.addr_base_valid = 0;
                end else begin
                    ai.addr_base = pd.sib_base;
                    ai.addr_base_valid = 1;
                end

                // SS segment default when base is ESP or EBP
                if (ai.addr_base_valid && (pd.sib_base == REG_ESP || pd.sib_base == REG_EBP))
                    ai.addr_seg = 3'd3; // SS
            end else begin
                // No SIB: rm field is the base register
                if (pd.mod == 2'b00 && pd.rm == 3'b101) begin
                    // mod==00, rm==101: disp32 only, no base
                    ai.addr_base_valid = 0;
                end else begin
                    ai.addr_base = pd.rm;
                    ai.addr_base_valid = 1;
                end

                // SS segment default when base is EBP or ESP
                if (ai.addr_base_valid && (pd.rm == REG_EBP || pd.rm == REG_ESP))
                    ai.addr_seg = 3'd3; // SS
            end
        end else begin
            // ---- 16-bit addressing ----
            // 16-bit mode uses a fixed table based on rm field:
            //   rm=000: [BX+SI]     rm=100: [SI]
            //   rm=001: [BX+DI]     rm=101: [DI]
            //   rm=010: [BP+SI]     rm=110: [BP] or disp16 if mod==00
            //   rm=011: [BP+DI]     rm=111: [BX]
            case (pd.rm)
                3'b000: begin
                    ai.addr_base = REG_EBX; ai.addr_base_valid = 1;
                    ai.addr_index = REG_ESI; ai.addr_index_valid = 1;
                end
                3'b001: begin
                    ai.addr_base = REG_EBX; ai.addr_base_valid = 1;
                    ai.addr_index = REG_EDI; ai.addr_index_valid = 1;
                end
                3'b010: begin
                    ai.addr_base = REG_EBP; ai.addr_base_valid = 1;
                    ai.addr_index = REG_ESI; ai.addr_index_valid = 1;
                    ai.addr_seg = 3'd3; // SS for BP-based
                end
                3'b011: begin
                    ai.addr_base = REG_EBP; ai.addr_base_valid = 1;
                    ai.addr_index = REG_EDI; ai.addr_index_valid = 1;
                    ai.addr_seg = 3'd3; // SS for BP-based
                end
                3'b100: begin
                    ai.addr_base = REG_ESI; ai.addr_base_valid = 1;
                end
                3'b101: begin
                    ai.addr_base = REG_EDI; ai.addr_base_valid = 1;
                end
                3'b110: begin
                    if (pd.mod != 2'b00) begin
                        ai.addr_base = REG_EBP; ai.addr_base_valid = 1;
                        ai.addr_seg = 3'd3; // SS for BP-based
                    end
                    // mod==00, rm==110: disp16 only, no base
                end
                3'b111: begin
                    ai.addr_base = REG_EBX; ai.addr_base_valid = 1;
                end
            endcase
        end

        // Segment prefix override (if present, overrides default)
        if (pd.pref_seg != 3'd0)
            ai.addr_seg = pd.pref_seg;

        return ai;
    endfunction


    function automatic reg_usage_t get_reg_usage(predecode_t pd);
        reg_usage_t ru;
        addr_info_t ai;
        logic is_cmp;      // For ALU ops: CMP doesn't write dest
        logic is_cmp_g1;   // For Grp1 ops: CMP sub-function
        ru = '0;
        is_cmp = 0;
        is_cmp_g1 = 0;

        // ---- Extract address registers for all memory-referencing instructions ----
        ai = extract_addr_regs(pd);
        ru.addr_base       = ai.addr_base;
        ru.addr_base_valid = ai.addr_base_valid;
        ru.addr_index      = ai.addr_index;
        ru.addr_index_valid = ai.addr_index_valid;
        ru.addr_scale      = ai.addr_scale;
        ru.addr_seg        = ai.addr_seg;

        if (pd.invalid || pd.is_prefix) return ru;

        // ---- Two-byte opcodes (0x0F) ----
        if (pd.is_0f) begin
            case (pd.opcode)
                // Jcc near — reads flags, no register write
                8'h80, 8'h81, 8'h82, 8'h83,
                8'h84, 8'h85, 8'h86, 8'h87,
                8'h88, 8'h89, 8'h8A, 8'h8B,
                8'h8C, 8'h8D, 8'h8E, 8'h8F: begin
                    ru.reads_flags = 1;
                end

                // SETcc — reads flags, writes r/m8
                8'h90, 8'h91, 8'h92, 8'h93,
                8'h94, 8'h95, 8'h96, 8'h97,
                8'h98, 8'h99, 8'h9A, 8'h9B,
                8'h9C, 8'h9D, 8'h9E, 8'h9F: begin
                    ru.reads_flags = 1;
                    ru.dest = pd.rm;
                    ru.dest_valid = (pd.mod == 2'b11);
                end

                // BSWAP reg (encoded in low 3 bits of second opcode byte)
                8'hC8, 8'hC9, 8'hCA, 8'hCB,
                8'hCC, 8'hCD, 8'hCE, 8'hCF: begin
                    ru.dest = pd.opcode[2:0];
                    ru.dest_valid = 1;
                    ru.src_a = pd.opcode[2:0];
                    ru.src_a_valid = 1;
                end

                // MOVZX/MOVSX — dest is reg_field, src is r/m
                8'hB6, 8'hB7, 8'hBE, 8'hBF: begin
                    ru.dest = pd.reg_field;
                    ru.dest_valid = 1;
                    ru.src_a = pd.rm;
                    ru.src_a_valid = (pd.mod == 2'b11);
                end

                // IMUL r, r/m (AF)
                8'hAF: begin
                    ru.dest = pd.reg_field;
                    ru.dest_valid = 1;
                    ru.src_a = pd.reg_field;
                    ru.src_a_valid = 1;
                    ru.src_b = pd.rm;
                    ru.src_b_valid = (pd.mod == 2'b11);
                    ru.writes_flags = 1;
                end

                // BT/BTS/BTR/BTC — reads/writes r/m and flags
                8'hA3, 8'hAB, 8'hB3, 8'hBB, 8'hBA: begin
                    ru.src_a = pd.rm;
                    ru.src_a_valid = (pd.mod == 2'b11);
                    ru.src_b = pd.reg_field;
                    ru.src_b_valid = (pd.opcode != 8'hBA); // Grp8 uses imm
                    ru.writes_flags = 1;
                    // BTS/BTR/BTC also write dest
                    if (pd.opcode != 8'hA3) begin // Not plain BT
                        ru.dest = pd.rm;
                        ru.dest_valid = (pd.mod == 2'b11);
                    end
                end

                // BSF/BSR
                8'hBC, 8'hBD: begin
                    ru.dest = pd.reg_field;
                    ru.dest_valid = 1;
                    ru.src_a = pd.rm;
                    ru.src_a_valid = (pd.mod == 2'b11);
                    ru.writes_flags = 1;
                end

                // SHLD/SHRD (A4/A5/AC/AD)
                8'hA4, 8'hA5, 8'hAC, 8'hAD: begin
                    ru.dest = pd.rm;
                    ru.dest_valid = (pd.mod == 2'b11);
                    ru.src_a = pd.rm;
                    ru.src_a_valid = (pd.mod == 2'b11);
                    ru.src_b = pd.reg_field;
                    ru.src_b_valid = 1;
                    ru.writes_flags = 1;
                end

                // CMPXCHG (B0/B1) — implicit EAX, reads r/m and reg
                8'hB0, 8'hB1: begin
                    ru.dest = REG_EAX;
                    ru.dest_valid = 1;
                    ru.src_a = REG_EAX;
                    ru.src_a_valid = 1;
                    ru.src_b = pd.reg_field;
                    ru.src_b_valid = 1;
                    ru.writes_flags = 1;
                end

                // XADD (C0/C1) — swap and add
                8'hC0, 8'hC1: begin
                    ru.dest = pd.rm;
                    ru.dest_valid = (pd.mod == 2'b11);
                    ru.src_a = pd.rm;
                    ru.src_a_valid = (pd.mod == 2'b11);
                    ru.src_b = pd.reg_field;
                    ru.src_b_valid = 1;
                    ru.writes_flags = 1;
                end

                // PUSH/POP FS/GS — implicit ESP
                8'hA0, 8'hA8: begin // PUSH FS/GS
                    ru.writes_esp = 1;
                    ru.src_a = REG_ESP;
                    ru.src_a_valid = 1;
                end
                8'hA1, 8'hA9: begin // POP FS/GS
                    ru.writes_esp = 1;
                    ru.src_a = REG_ESP;
                    ru.src_a_valid = 1;
                end

                // RDMSR/WRMSR — implicit ECX, EDX:EAX
                8'h32: begin // RDMSR
                    ru.dest = REG_EAX;
                    ru.dest_valid = 1;
                    ru.src_a = REG_ECX;
                    ru.src_a_valid = 1;
                end
                8'h30: begin // WRMSR
                    ru.src_a = REG_ECX;
                    ru.src_a_valid = 1;
                    ru.src_b = REG_EAX;
                    ru.src_b_valid = 1;
                end

                // RDTSC — writes EDX:EAX
                8'h31: begin
                    ru.dest = REG_EAX;
                    ru.dest_valid = 1;
                end

                // CPUID — reads EAX, writes EAX/EBX/ECX/EDX
                8'hA2: begin
                    ru.dest = REG_EAX;
                    ru.dest_valid = 1;
                    ru.src_a = REG_EAX;
                    ru.src_a_valid = 1;
                end

                // Grp15 (0F AE): CLFLUSH /7 — reads address, no register dest
                // Other sub-functions (FXSAVE/FXRSTOR if ever supported) also use memory
                8'hAE: begin
                    // Address registers handled by extract_addr_regs
                    // No general-purpose register written or read (beyond address)
                end

                // MOV CR/DR (0F 20-23) — reg_field is CR/DR number, rm is GPR
                8'h20: begin // MOV r32, CRn — reads CRn, writes GPR
                    ru.dest = pd.rm;
                    ru.dest_valid = 1;
                end
                8'h21: begin // MOV r32, DRn — reads DRn, writes GPR
                    ru.dest = pd.rm;
                    ru.dest_valid = 1;
                end
                8'h22: begin // MOV CRn, r32 — reads GPR, writes CRn
                    ru.src_a = pd.rm;
                    ru.src_a_valid = 1;
                end
                8'h23: begin // MOV DRn, r32 — reads GPR, writes DRn
                    ru.src_a = pd.rm;
                    ru.src_a_valid = 1;
                end

                // CMOVcc (0F 40-4F) — reads flags + source, writes dest
                8'h40, 8'h41, 8'h42, 8'h43,
                8'h44, 8'h45, 8'h46, 8'h47,
                8'h48, 8'h49, 8'h4A, 8'h4B,
                8'h4C, 8'h4D, 8'h4E, 8'h4F: begin
                    ru.reads_flags = 1;
                    ru.dest = pd.reg_field;
                    ru.dest_valid = 1;
                    ru.src_a = pd.reg_field;  // Original dest value (pass-through if cond false)
                    ru.src_a_valid = 1;
                    ru.src_b = pd.rm;
                    ru.src_b_valid = (pd.mod == 2'b11);
                end

                // POPCNT (0F B8) — reads source, writes dest, writes flags
                8'hB8: begin
                    ru.dest = pd.reg_field;
                    ru.dest_valid = 1;
                    ru.src_a = pd.rm;
                    ru.src_a_valid = (pd.mod == 2'b11);
                    ru.writes_flags = 1;
                end

                // PREFETCH (0F 18) — reads address only, no register dest
                8'h18: begin
                    // Address registers handled by extract_addr_regs
                end

                // RDPMC (0F 33) — reads ECX, writes EAX (low 32 of counter)
                8'h33: begin
                    ru.dest = REG_EAX;
                    ru.dest_valid = 1;
                    ru.src_a = REG_ECX;
                    ru.src_a_valid = 1;
                end

                default: begin
                    // Generic ModRM fallback
                    if (pd.has_modrm) begin
                        ru.dest = pd.reg_field;
                        ru.dest_valid = 1;
                        ru.src_a = pd.rm;
                        ru.src_a_valid = (pd.mod == 2'b11);
                    end
                end
            endcase
            return ru;
        end

        // ---- One-byte opcodes ----

        // Standard ALU: ADD/OR/ADC/SBB/AND/SUB/XOR/CMP (00-3F, ModRM forms)
        if (pd.opcode[7:6] == 2'b00 && pd.has_modrm) begin
            is_cmp = (pd.opcode[5:3] == 3'b111); // CMP doesn't write dest

            ru.writes_flags = 1;
            if (pd.opcode[1]) begin
                // Direction = 1: reg is dest, r/m is source
                ru.dest = pd.reg_field;
                ru.dest_valid = !is_cmp;
                ru.src_a = pd.reg_field;
                ru.src_a_valid = 1;
                ru.src_b = pd.rm;
                ru.src_b_valid = (pd.mod == 2'b11);
            end else begin
                // Direction = 0: r/m is dest, reg is source
                ru.dest = pd.rm;
                ru.dest_valid = !is_cmp && (pd.mod == 2'b11);
                ru.src_a = pd.rm;
                ru.src_a_valid = (pd.mod == 2'b11);
                ru.src_b = pd.reg_field;
                ru.src_b_valid = 1;
            end
            // ADC/SBB read flags too
            if (pd.opcode[5:3] == 3'b010 || pd.opcode[5:3] == 3'b011)
                ru.reads_flags = 1;
            return ru;
        end

        // Accumulator-immediate ALU (04/05, 0C/0D, ..., 3C/3D)
        if (pd.opcode[7:6] == 2'b00 && !pd.has_modrm &&
            (pd.opcode[2:0] == 3'b100 || pd.opcode[2:0] == 3'b101)) begin
            ru.dest = REG_EAX;
            ru.dest_valid = (pd.opcode[5:3] != 3'b111); // CMP doesn't write
            ru.src_a = REG_EAX;
            ru.src_a_valid = 1;
            ru.writes_flags = 1;
            if (pd.opcode[5:3] == 3'b010 || pd.opcode[5:3] == 3'b011)
                ru.reads_flags = 1;
            return ru;
        end

        // INC/DEC register (40-4F)
        if (pd.opcode[7:4] == 4'h4) begin
            ru.dest = pd.opcode[2:0];
            ru.dest_valid = 1;
            ru.src_a = pd.opcode[2:0];
            ru.src_a_valid = 1;
            ru.writes_flags = 1; // All except CF
            return ru;
        end

        // PUSH register (50-57) — reads reg, writes [ESP], decrements ESP
        if (pd.opcode[7:3] == 5'b01010) begin
            ru.src_a = pd.opcode[2:0];
            ru.src_a_valid = 1;
            ru.writes_esp = 1;
            return ru;
        end

        // POP register (58-5F) — reads [ESP], writes reg, increments ESP
        if (pd.opcode[7:3] == 5'b01011) begin
            ru.dest = pd.opcode[2:0];
            ru.dest_valid = 1;
            ru.writes_esp = 1;
            return ru;
        end

        // PUSH/POP segment (06/0E/16/1E and 07/17/1F)
        case (pd.opcode)
            8'h06, 8'h0E, 8'h16, 8'h1E: begin // PUSH seg
                ru.writes_esp = 1;
            end
            8'h07, 8'h17, 8'h1F: begin         // POP seg
                ru.writes_esp = 1;
            end
            default: ;
        endcase

        // Jcc short (70-7F) — reads flags only
        if (pd.opcode[7:4] == 4'h7) begin
            ru.reads_flags = 1;
            return ru;
        end

        // Grp1 (80-83): ALU r/m, imm
        if (pd.opcode[7:2] == 6'b100000) begin
            is_cmp_g1 = (pd.reg_field == 3'b111);
            ru.dest = pd.rm;
            ru.dest_valid = !is_cmp_g1 && (pd.mod == 2'b11);
            ru.src_a = pd.rm;
            ru.src_a_valid = (pd.mod == 2'b11);
            ru.writes_flags = 1;
            if (pd.reg_field == 3'b010 || pd.reg_field == 3'b011) // ADC/SBB
                ru.reads_flags = 1;
            return ru;
        end

        // TEST r/m, r (84/85)
        if (pd.opcode == 8'h84 || pd.opcode == 8'h85) begin
            ru.src_a = pd.rm;
            ru.src_a_valid = (pd.mod == 2'b11);
            ru.src_b = pd.reg_field;
            ru.src_b_valid = 1;
            ru.writes_flags = 1;
            return ru;
        end

        // XCHG r/m, r (86/87) — reads and writes both
        if (pd.opcode == 8'h86 || pd.opcode == 8'h87) begin
            ru.dest = pd.reg_field;
            ru.dest_valid = 1;
            ru.src_a = pd.reg_field;
            ru.src_a_valid = 1;
            ru.src_b = pd.rm;
            ru.src_b_valid = (pd.mod == 2'b11);
            return ru;
        end

        // MOV r/m, r (88/89) and MOV r, r/m (8A/8B)
        case (pd.opcode)
            8'h88, 8'h89: begin // MOV r/m, r — source is reg_field
                ru.dest = pd.rm;
                ru.dest_valid = (pd.mod == 2'b11);
                ru.src_a = pd.reg_field;
                ru.src_a_valid = 1;
            end
            8'h8A, 8'h8B: begin // MOV r, r/m — dest is reg_field
                ru.dest = pd.reg_field;
                ru.dest_valid = 1;
                ru.src_a = pd.rm;
                ru.src_a_valid = (pd.mod == 2'b11);
            end
            default: ;
        endcase
        if (pd.opcode[7:2] == 6'b100010) return ru; // 88-8B handled

        // LEA (8D) — dest is reg_field, no register source (address calc only)
        if (pd.opcode == 8'h8D) begin
            ru.dest = pd.reg_field;
            ru.dest_valid = 1;
            // Base/index from ModRM/SIB are address sources, not data sources
            return ru;
        end

        // POP r/m (8F), MOV Sreg (8C/8E)
        if (pd.opcode == 8'h8F) begin
            ru.dest = pd.rm;
            ru.dest_valid = (pd.mod == 2'b11);
            ru.writes_esp = 1;
            return ru;
        end

        // NOP (90)
        if (pd.opcode == 8'h90) return ru;

        // XCHG EAX, reg (91-97)
        if (pd.opcode[7:3] == 5'b10010 && pd.opcode[2:0] != 3'b000) begin
            ru.dest = pd.opcode[2:0];
            ru.dest_valid = 1;
            ru.src_a = pd.opcode[2:0];
            ru.src_a_valid = 1;
            ru.src_b = REG_EAX;
            ru.src_b_valid = 1;
            return ru;
        end

        // CBW/CWDE (98), CWD/CDQ (99) — implicit EAX / EDX:EAX
        if (pd.opcode == 8'h98) begin
            ru.dest = REG_EAX;
            ru.dest_valid = 1;
            ru.src_a = REG_EAX;
            ru.src_a_valid = 1;
            return ru;
        end
        if (pd.opcode == 8'h99) begin
            ru.dest = REG_EDX;
            ru.dest_valid = 1;
            ru.src_a = REG_EAX;
            ru.src_a_valid = 1;
            return ru;
        end

        // CALL near (E8) / CALL far (9A) — implicit ESP
        if (pd.opcode == 8'hE8 || pd.opcode == 8'h9A) begin
            ru.writes_esp = 1;
            return ru;
        end

        // RET near (C3) / RET near imm16 (C2) — reads ESP
        if (pd.opcode == 8'hC2 || pd.opcode == 8'hC3) begin
            ru.writes_esp = 1;
            return ru;
        end

        // RETF (CA/CB), IRET (CF)
        if (pd.opcode == 8'hCA || pd.opcode == 8'hCB || pd.opcode == 8'hCF) begin
            ru.writes_esp = 1;
            return ru;
        end

        // PUSHF (9C) / POPF (9D)
        if (pd.opcode == 8'h9C) begin
            ru.writes_esp = 1;
            ru.reads_flags = 1;
            return ru;
        end
        if (pd.opcode == 8'h9D) begin
            ru.writes_esp = 1;
            ru.writes_flags = 1;
            return ru;
        end

        // MOV moffs (A0-A3) — implicit EAX
        case (pd.opcode)
            8'hA0, 8'hA1: begin
                ru.dest = REG_EAX;
                ru.dest_valid = 1;
            end
            8'hA2, 8'hA3: begin
                ru.src_a = REG_EAX;
                ru.src_a_valid = 1;
            end
            default: ;
        endcase
        if (pd.opcode[7:2] == 6'b101000) return ru;

        // String ops — implicit ESI, EDI, (ECX for REP)
        case (pd.opcode)
            8'hA4, 8'hA5: begin // MOVS — reads ESI, writes EDI
                ru.src_a = REG_ESI;
                ru.src_a_valid = 1;
                ru.src_b = REG_EDI;
                ru.src_b_valid = 1;
            end
            8'hA6, 8'hA7: begin // CMPS — reads ESI and EDI
                ru.src_a = REG_ESI;
                ru.src_a_valid = 1;
                ru.src_b = REG_EDI;
                ru.src_b_valid = 1;
                ru.writes_flags = 1;
            end
            8'hAA, 8'hAB: begin // STOS — writes [EDI], reads EAX
                ru.src_a = REG_EAX;
                ru.src_a_valid = 1;
                ru.src_b = REG_EDI;
                ru.src_b_valid = 1;
            end
            8'hAC, 8'hAD: begin // LODS — reads [ESI], writes EAX
                ru.dest = REG_EAX;
                ru.dest_valid = 1;
                ru.src_a = REG_ESI;
                ru.src_a_valid = 1;
            end
            8'hAE, 8'hAF: begin // SCAS — reads EAX and [EDI]
                ru.src_a = REG_EAX;
                ru.src_a_valid = 1;
                ru.src_b = REG_EDI;
                ru.src_b_valid = 1;
                ru.writes_flags = 1;
            end
            default: ;
        endcase
        if (pd.opcode[7:1] == 7'b1010010 || pd.opcode[7:1] == 7'b1010011 ||
            pd.opcode[7:1] == 7'b1010101 || pd.opcode[7:1] == 7'b1010110 ||
            pd.opcode[7:1] == 7'b1010111) return ru;

        // TEST AL/eAX, imm (A8/A9)
        if (pd.opcode == 8'hA8 || pd.opcode == 8'hA9) begin
            ru.src_a = REG_EAX;
            ru.src_a_valid = 1;
            ru.writes_flags = 1;
            return ru;
        end

        // MOV reg, imm (B0-BF)
        if (pd.opcode[7:4] == 4'hB) begin
            ru.dest = pd.opcode[2:0];
            ru.dest_valid = 1;
            return ru;
        end

        // Shift/rotate Grp2 (C0/C1/D0-D3)
        case (pd.opcode)
            8'hC0, 8'hC1: begin // Shift r/m, imm8
                ru.dest = pd.rm;
                ru.dest_valid = (pd.mod == 2'b11);
                ru.src_a = pd.rm;
                ru.src_a_valid = (pd.mod == 2'b11);
                ru.writes_flags = 1;
            end
            8'hD0, 8'hD1: begin // Shift r/m, 1
                ru.dest = pd.rm;
                ru.dest_valid = (pd.mod == 2'b11);
                ru.src_a = pd.rm;
                ru.src_a_valid = (pd.mod == 2'b11);
                ru.writes_flags = 1;
            end
            8'hD2, 8'hD3: begin // Shift r/m, CL
                ru.dest = pd.rm;
                ru.dest_valid = (pd.mod == 2'b11);
                ru.src_a = pd.rm;
                ru.src_a_valid = (pd.mod == 2'b11);
                ru.src_b = REG_ECX;
                ru.src_b_valid = 1;
                ru.writes_flags = 1;
            end
            default: ;
        endcase
        if (pd.opcode == 8'hC0 || pd.opcode == 8'hC1 ||
            pd.opcode[7:2] == 6'b110100) return ru;

        // MOV r/m, imm (C6/C7)
        if (pd.opcode == 8'hC6 || pd.opcode == 8'hC7) begin
            ru.dest = pd.rm;
            ru.dest_valid = (pd.mod == 2'b11);
            return ru;
        end

        // ENTER (C8) — ESP, EBP
        if (pd.opcode == 8'hC8) begin
            ru.src_a = REG_EBP;
            ru.src_a_valid = 1;
            ru.dest = REG_EBP;
            ru.dest_valid = 1;
            ru.writes_esp = 1;
            return ru;
        end

        // LEAVE (C9) — ESP = EBP, POP EBP
        if (pd.opcode == 8'hC9) begin
            ru.src_a = REG_EBP;
            ru.src_a_valid = 1;
            ru.dest = REG_EBP;
            ru.dest_valid = 1;
            ru.writes_esp = 1;
            return ru;
        end

        // INT (CC/CD/CE) — implicit ESP
        if (pd.opcode == 8'hCC || pd.opcode == 8'hCD || pd.opcode == 8'hCE) begin
            ru.writes_esp = 1;
            return ru;
        end

        // PUSHA/POPA (60/61) — all registers
        if (pd.opcode == 8'h60 || pd.opcode == 8'h61) begin
            ru.writes_esp = 1;
            return ru;
        end

        `ifdef VERILATOR
        // Test opcode 0xD6: PUSH+POP (microcode mem bring-up)
        if (pd.opcode == 8'hD6) begin
            ru.writes_esp = 1;
            return ru;
        end
        `endif

        // PUSH imm (68/6A)
        if (pd.opcode == 8'h68 || pd.opcode == 8'h6A) begin
            ru.writes_esp = 1;
            return ru;
        end

        // IMUL r, r/m, imm (69/6B)
        if (pd.opcode == 8'h69 || pd.opcode == 8'h6B) begin
            ru.dest = pd.reg_field;
            ru.dest_valid = 1;
            ru.src_a = pd.rm;
            ru.src_a_valid = (pd.mod == 2'b11);
            ru.writes_flags = 1;
            return ru;
        end

        // LOOPx/JCXZ (E0-E3) — implicit ECX
        if (pd.opcode[7:2] == 6'b111000) begin
            ru.src_a = REG_ECX;
            ru.src_a_valid = 1;
            ru.dest = REG_ECX;
            ru.dest_valid = (pd.opcode != 8'hE3); // JCXZ doesn't modify ECX
            return ru;
        end

        // Grp3 (F6/F7): TEST/NOT/NEG/MUL/IMUL/DIV/IDIV
        if (pd.opcode == 8'hF6 || pd.opcode == 8'hF7) begin
            case (pd.reg_field)
                3'b000, 3'b001: begin // TEST r/m, imm — read only
                    ru.src_a = pd.rm;
                    ru.src_a_valid = (pd.mod == 2'b11);
                    ru.writes_flags = 1;
                end
                3'b010, 3'b011: begin // NOT/NEG
                    ru.dest = pd.rm;
                    ru.dest_valid = (pd.mod == 2'b11);
                    ru.src_a = pd.rm;
                    ru.src_a_valid = (pd.mod == 2'b11);
                    ru.writes_flags = (pd.reg_field == 3'b011); // NEG writes flags, NOT doesn't
                end
                3'b100, 3'b101: begin // MUL/IMUL — implicit EAX/EDX
                    ru.dest = REG_EAX;
                    ru.dest_valid = 1;
                    ru.src_a = REG_EAX;
                    ru.src_a_valid = 1;
                    ru.src_b = pd.rm;
                    ru.src_b_valid = (pd.mod == 2'b11);
                    ru.writes_flags = 1;
                end
                3'b110, 3'b111: begin // DIV/IDIV — implicit EDX:EAX
                    ru.dest = REG_EAX;
                    ru.dest_valid = 1;
                    ru.src_a = REG_EAX;
                    ru.src_a_valid = 1;
                    ru.src_b = pd.rm;
                    ru.src_b_valid = (pd.mod == 2'b11);
                    ru.writes_flags = 1;
                end
            endcase
            return ru;
        end

        // Grp4 (FE): INC/DEC r/m8
        if (pd.opcode == 8'hFE) begin
            ru.dest = pd.rm;
            ru.dest_valid = (pd.mod == 2'b11);
            ru.src_a = pd.rm;
            ru.src_a_valid = (pd.mod == 2'b11);
            ru.writes_flags = 1;
            return ru;
        end

        // Grp5 (FF): INC/DEC/CALL/JMP/PUSH r/m
        if (pd.opcode == 8'hFF) begin
            case (pd.reg_field)
                3'b000, 3'b001: begin // INC/DEC
                    ru.dest = pd.rm;
                    ru.dest_valid = (pd.mod == 2'b11);
                    ru.src_a = pd.rm;
                    ru.src_a_valid = (pd.mod == 2'b11);
                    ru.writes_flags = 1;
                end
                3'b010, 3'b011: begin // CALL near/far indirect
                    ru.src_a = pd.rm;
                    ru.src_a_valid = (pd.mod == 2'b11);
                    ru.writes_esp = 1;
                end
                3'b100, 3'b101: begin // JMP near/far indirect
                    ru.src_a = pd.rm;
                    ru.src_a_valid = (pd.mod == 2'b11);
                end
                3'b110: begin         // PUSH r/m
                    ru.src_a = pd.rm;
                    ru.src_a_valid = (pd.mod == 2'b11);
                    ru.writes_esp = 1;
                end
                default: ;
            endcase
            return ru;
        end

        // SAHF (9E) — loads flags from AH
        if (pd.opcode == 8'h9E) begin
            ru.src_a = REG_EAX;
            ru.src_a_valid = 1;
            ru.writes_flags = 1;
            return ru;
        end
        // LAHF (9F) — stores flags to AH
        if (pd.opcode == 8'h9F) begin
            ru.dest = REG_EAX;
            ru.dest_valid = 1;
            ru.reads_flags = 1;
            return ru;
        end

        // CMC/CLC/STC/CLI/STI/CLD/STD — flag manipulation
        case (pd.opcode)
            8'hF5: begin ru.reads_flags = 1; ru.writes_flags = 1; end // CMC
            8'hF8, 8'hF9, 8'hFA, 8'hFB, 8'hFC, 8'hFD:
                ru.writes_flags = 1;
            default: ;
        endcase

        // DAA/DAS/AAA/AAS/AAM/AAD — implicit EAX + flags
        case (pd.opcode)
            8'h27, 8'h2F, 8'h37, 8'h3F, 8'hD4, 8'hD5: begin
                ru.dest = REG_EAX;
                ru.dest_valid = 1;
                ru.src_a = REG_EAX;
                ru.src_a_valid = 1;
                ru.writes_flags = 1;
                ru.reads_flags = 1;
            end
            default: ;
        endcase

        return ru;
    endfunction


    // =========================================================================
    // V-Pipe Pairing Eligibility
    // =========================================================================
    //
    // Pentium-style pairing rules: V-pipe can only execute simple ALU
    // instructions that don't access memory, use microcode, or modify
    // flags in complex ways.

    function automatic logic can_pair_v(predecode_t pd);
        if (pd.invalid || pd.is_prefix)
            return 0;

        // Pentium V-pipe pairing rules:
        // V-pipe can execute simple ALU, MOV, PUSH/POP reg, LEA,
        // short Jcc, and shifts by 1 or immediate.
        // NO memory-referencing ops (except PUSH/POP reg which use ESP implicitly),
        // NO microcode, NO FPU, NO system instructions.

        if (!pd.is_0f) begin
            case (pd.opcode)
                // --- ALU reg,reg (all 6 standard ALU ops, both directions) ---
                // ADD/OR/ADC/SBB/AND/SUB/XOR/CMP r/m32,r32 and r32,r/m32
                8'h00, 8'h01, 8'h02, 8'h03,   // ADD
                8'h08, 8'h09, 8'h0A, 8'h0B,   // OR
                8'h10, 8'h11, 8'h12, 8'h13,   // ADC
                8'h18, 8'h19, 8'h1A, 8'h1B,   // SBB
                8'h20, 8'h21, 8'h22, 8'h23,   // AND
                8'h28, 8'h29, 8'h2A, 8'h2B,   // SUB
                8'h30, 8'h31, 8'h32, 8'h33,   // XOR
                8'h38, 8'h39, 8'h3A, 8'h3B:   // CMP
                    return (pd.mod == 2'b11);   // Only reg-reg forms

                // --- ALU accumulator, imm ---
                8'h04, 8'h05,                   // ADD AL/eAX, imm
                8'h0C, 8'h0D,                   // OR AL/eAX, imm
                8'h14, 8'h15,                   // ADC AL/eAX, imm
                8'h1C, 8'h1D,                   // SBB AL/eAX, imm
                8'h24, 8'h25,                   // AND AL/eAX, imm
                8'h2C, 8'h2D,                   // SUB AL/eAX, imm
                8'h34, 8'h35,                   // XOR AL/eAX, imm
                8'h3C, 8'h3D:                   // CMP AL/eAX, imm
                    return 1;

                // --- INC/DEC register ---
                8'h40, 8'h41, 8'h42, 8'h43,
                8'h44, 8'h45, 8'h46, 8'h47,
                8'h48, 8'h49, 8'h4A, 8'h4B,
                8'h4C, 8'h4D, 8'h4E, 8'h4F:
                    return 1;

                // --- PUSH/POP register ---
                8'h50, 8'h51, 8'h52, 8'h53,
                8'h54, 8'h55, 8'h56, 8'h57:    // PUSH reg
                    return 1;
                8'h58, 8'h59, 8'h5A, 8'h5B,
                8'h5C, 8'h5D, 8'h5E, 8'h5F:    // POP reg
                    return 1;

                // --- PUSH imm ---
                8'h6A:                           // PUSH imm8
                    return 1;

                // --- Jcc short (most critical for dual-issue throughput) ---
                8'h70, 8'h71, 8'h72, 8'h73,
                8'h74, 8'h75, 8'h76, 8'h77,
                8'h78, 8'h79, 8'h7A, 8'h7B,
                8'h7C, 8'h7D, 8'h7E, 8'h7F:
                    return 1;

                // --- Grp1 r/m, imm (reg-reg forms only) ---
                8'h80, 8'h81, 8'h83:
                    return (pd.mod == 2'b11);

                // --- TEST reg,reg ---
                8'h84, 8'h85:
                    return (pd.mod == 2'b11);

                // --- MOV reg,reg ---
                8'h88, 8'h89, 8'h8A, 8'h8B:
                    return (pd.mod == 2'b11);

                // --- LEA (V-pipe pairable on Pentium) ---
                8'h8D:
                    return 1;

                // --- NOP ---
                8'h90:
                    return 1;

                // --- XCHG EAX,reg ---
                8'h91, 8'h92, 8'h93,
                8'h94, 8'h95, 8'h96, 8'h97:
                    return 1;

                // --- TEST AL/eAX, imm ---
                8'hA8, 8'hA9:
                    return 1;

                // --- MOV reg, imm ---
                8'hB0, 8'hB1, 8'hB2, 8'hB3,
                8'hB4, 8'hB5, 8'hB6, 8'hB7,
                8'hB8, 8'hB9, 8'hBA, 8'hBB,
                8'hBC, 8'hBD, 8'hBE, 8'hBF:
                    return 1;

                // --- Shift/rotate by 1 (D0/D1) and by imm8 (C0/C1) ---
                8'hC0, 8'hC1, 8'hD0, 8'hD1:
                    return (pd.mod == 2'b11);

                // --- RET near ---
                8'hC3:
                    return 1;

                // --- JMP short ---
                8'hEB:
                    return 1;

                // --- CALL near rel ---
                8'hE8:
                    return 1;

                default:
                    return 0;
            endcase
        end

        return 0; // Two-byte opcodes not pairable in V-pipe (Pentium rule)
    endfunction


    // =========================================================================
    // Branch Target Pre-Calculation
    // =========================================================================
    //
    // For REL8 and RELV branches, compute target_pc = pc + instr_len + offset
    // in the decoder. This lets the branch predictor act one cycle earlier
    // than waiting for the execute stage, saving a cycle on taken predictions.

    // All signals below use registered stage 1 values (pd_u = pd_u_r, u_pc_r, v_pc_r)
    logic [31:0] u_branch_tgt, v_branch_tgt;
    logic        u_is_branch, v_is_branch;
    logic        u_is_indirect, v_is_indirect;

    always_comb begin
        // U-pipe branch target (valid for relative branches only)
        u_branch_tgt  = u_pc_r + {28'h0, pd_u.insn_len} + pd_u.imm_value;
        u_is_branch   = pd_u.imm_is_rel && !pd_u.invalid;
        u_is_indirect = pd_u.is_indirect && !pd_u.invalid;

        // V-pipe branch target
        v_branch_tgt  = v_pc_r + {28'h0, pd_v.insn_len} + pd_v.imm_value;
        v_is_branch   = pd_v.imm_is_rel && !pd_v.invalid;
        v_is_indirect = pd_v.is_indirect && !pd_v.invalid;
    end


    // =========================================================================
    // Raw Instruction Byte Capture
    // =========================================================================
    //
    // U-pipe raw bytes come from the stage 1 pipeline register.
    // V-pipe raw bytes come from the registered v_stream.

    logic [31:0] v_raw;

    always_comb begin
        v_raw = v_stream_r[31:0];
    end


    // =========================================================================
    // Output Assembly — Build ooo_instr_t Packets
    // =========================================================================

    logic v_eligible;
    reg_usage_t ru_u, ru_v;

    always_comb begin
        v_eligible = can_pair_v(pd_v) && !pd_u.invalid && !pd_u.is_prefix;
        ru_u = get_reg_usage(pd_u);
        ru_v = get_reg_usage(pd_v);
    end

    // --- Pentium Extension Opcode Re-encoding ---
    // For OP_BITCOUNT: encode {opsz[1:0], bitcount_op[1:0]} into opcode field
    // so the execute stage can directly index the bitcount unit.
    logic [7:0] u_encoded_opcode;
    always_comb begin
        u_encoded_opcode = pd_u.opcode;
        if (CONF_ENABLE_NEHALEM_EXT && pd_u.is_0f) begin
            // POPCNT (0F B8 with F3): bitcount_op=00, opsz from prefix
            if (pd_u.opcode == 8'hB8 && pd_u.pref_rep == 2'b10)
                u_encoded_opcode = {4'd0, pd_u.pref_66 ? 2'b01 : 2'b10, 2'b00};
            // LZCNT (0F BD with F3): bitcount_op=01
            else if (pd_u.opcode == 8'hBD && pd_u.pref_rep == 2'b10)
                u_encoded_opcode = {4'd0, pd_u.pref_66 ? 2'b01 : 2'b10, 2'b01};
            // TZCNT (0F BC with F3): bitcount_op=10
            else if (pd_u.opcode == 8'hBC && pd_u.pref_rep == 2'b10)
                u_encoded_opcode = {4'd0, pd_u.pref_66 ? 2'b01 : 2'b10, 2'b10};
        end
    end

    // --- Stage 2 Output Register ---
    // Both U and V pipe results are registered on the same clock edge.
    // s1_valid indicates the pipeline register has valid data for stage 2.

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            instr_u              <= '0;
            instr_v              <= '0;
            instr_u_valid        <= 0;
            instr_v_valid        <= 0;
            branch_target_u       <= 32'h0;
            branch_target_u_valid <= 0;
            branch_indirect_u     <= 0;
            branch_target_v       <= 32'h0;
            branch_target_v_valid <= 0;
            branch_indirect_v     <= 0;
            u_reads_flags         <= 0;
            u_writes_flags        <= 0;
            v_reads_flags         <= 0;
            v_writes_flags        <= 0;
            u_addr_base           <= 3'h0;
            u_addr_base_valid     <= 0;
            u_addr_index          <= 3'h0;
            u_addr_index_valid    <= 0;
            u_addr_scale          <= 2'b00;
            v_addr_base           <= 3'h0;
            v_addr_base_valid     <= 0;
            v_addr_index          <= 3'h0;
            v_addr_index_valid    <= 0;
            v_addr_scale          <= 2'b00;
            u_mem_size            <= 2'b00;
            v_mem_size            <= 2'b00;
            u_far_selector        <= 16'h0;
        end else if (s1_valid && rename_ready) begin

            // --- U-Pipe Instruction ---
            instr_u.valid       <= !pd_u.is_prefix && !pd_u.invalid;
            instr_u.pc          <= u_pc_r;
            instr_u.raw_instr   <= u_raw_r;
            instr_u.opcode      <= u_encoded_opcode;
            instr_u.op_cat      <= classify_op(pd_u);
            instr_u.p_dest      <= {2'b0, ru_u.dest};
            instr_u.dest_valid  <= ru_u.dest_valid;

            // --- Source operand mapping (P2: memory-op aware) ---
            // For OP_LOAD: val_a=base, val_b=index (for AGU)
            // For OP_STORE: val_a=base (for EA), val_b=store data
            // For others: default reg_usage mapping
            if (classify_op(pd_u) == OP_LOAD && pd_u.has_mem) begin
                // Load: src_a = addr_base (dependency tracked), src_b = addr_index
                instr_u.p_src_a     <= {2'b0, ru_u.addr_base};
                instr_u.src_a_ready <= !ru_u.addr_base_valid;
                instr_u.p_src_b     <= {2'b0, ru_u.addr_index};
                instr_u.src_b_ready <= !ru_u.addr_index_valid;
            end else if (classify_op(pd_u) == OP_STORE && pd_u.has_mem) begin
                // Store: src_a = addr_base, src_b = data register (from reg_usage src_a)
                instr_u.p_src_a     <= {2'b0, ru_u.addr_base};
                instr_u.src_a_ready <= !ru_u.addr_base_valid;
                instr_u.p_src_b     <= {2'b0, ru_u.src_a};
                instr_u.src_b_ready <= !ru_u.src_a_valid;
            end else begin
                instr_u.p_src_a     <= {2'b0, ru_u.src_a};
                instr_u.p_src_b     <= {2'b0, ru_u.src_b};
                instr_u.src_a_ready <= !ru_u.src_a_valid;
                instr_u.src_b_ready <= !ru_u.src_b_valid;
            end

            instr_u.val_a       <= 32'h0;
            instr_u.val_b       <= 32'h0;
            instr_u.rob_tag     <= 4'h0; // Assigned by ROB allocator
            instr_u.br_tag      <= '0;  // Assigned at dispatch in ooo_core_top
            instr_u.imm_value   <= pd_u.imm_value;
            instr_u.lq_idx      <= '0;
            instr_u.sq_idx      <= '0;
            instr_u.addr_base_valid  <= ru_u.addr_base_valid;
            instr_u.addr_index_valid <= ru_u.addr_index_valid;
            instr_u.addr_scale  <= ru_u.addr_scale;
            instr_u.mem_size    <= derive_mem_size(pd_u);
            // P3: microcode sequencer fields
            instr_u.is_0f       <= pd_u.is_0f;
            instr_u.modrm_reg   <= pd_u.reg_field;
            instr_u.is_rep      <= (pd_u.pref_rep != 2'b00);
            instr_u.is_repne    <= (pd_u.pref_rep == 2'b01);
            instr_u.is_32bit    <= pd_u.eff_op32;
            instr_u_valid       <= !pd_u.is_prefix && !pd_u.invalid;

            // U-pipe branch target + indirect flag
            branch_target_u       <= u_branch_tgt;
            branch_target_u_valid <= u_is_branch;
            branch_indirect_u     <= u_is_indirect;

            // U-pipe flags dependency
            u_reads_flags         <= ru_u.reads_flags;
            u_writes_flags        <= ru_u.writes_flags;

            // U-pipe address registers (for AGU / LSU)
            u_addr_base           <= ru_u.addr_base;
            u_addr_base_valid     <= ru_u.addr_base_valid;
            u_addr_index          <= ru_u.addr_index;
            u_addr_index_valid    <= ru_u.addr_index_valid;
            u_addr_scale          <= ru_u.addr_scale;
            u_mem_size            <= derive_mem_size(pd_u);
            u_far_selector        <= pd_u.far_selector;

            // --- V-Pipe Instruction ---
            instr_v.valid       <= v_eligible;
            instr_v.pc          <= v_pc_r;
            instr_v.raw_instr   <= v_raw;
            instr_v.opcode      <= pd_v.opcode;
            instr_v.op_cat      <= classify_op(pd_v);
            instr_v.p_dest      <= {2'b0, ru_v.dest};
            instr_v.dest_valid  <= ru_v.dest_valid;
            // V-pipe memory-op source override (mirrors U-pipe logic)
            if (classify_op(pd_v) == OP_LOAD && pd_v.has_mem) begin
                instr_v.p_src_a     <= {2'b0, ru_v.addr_base};
                instr_v.src_a_ready <= !ru_v.addr_base_valid;
                instr_v.p_src_b     <= {2'b0, ru_v.addr_index};
                instr_v.src_b_ready <= !ru_v.addr_index_valid;
            end else if (classify_op(pd_v) == OP_STORE && pd_v.has_mem) begin
                instr_v.p_src_a     <= {2'b0, ru_v.addr_base};
                instr_v.src_a_ready <= !ru_v.addr_base_valid;
                instr_v.p_src_b     <= {2'b0, ru_v.src_a};
                instr_v.src_b_ready <= !ru_v.src_a_valid;
            end else begin
                instr_v.p_src_a     <= {2'b0, ru_v.src_a};
                instr_v.p_src_b     <= {2'b0, ru_v.src_b};
                instr_v.src_a_ready <= !ru_v.src_a_valid;
                instr_v.src_b_ready <= !ru_v.src_b_valid;
            end
            instr_v.val_a       <= 32'h0;
            instr_v.val_b       <= 32'h0;
            instr_v.rob_tag     <= 4'h0;
            instr_v.br_tag      <= '0;
            instr_v.imm_value   <= pd_v.imm_value;
            instr_v.lq_idx      <= '0;
            instr_v.sq_idx      <= '0;
            instr_v.addr_base_valid  <= ru_v.addr_base_valid;
            instr_v.addr_index_valid <= ru_v.addr_index_valid;
            instr_v.addr_scale  <= ru_v.addr_scale;
            instr_v.mem_size    <= derive_mem_size(pd_v);
            // P3: microcode sequencer fields
            instr_v.is_0f       <= pd_v.is_0f;
            instr_v.modrm_reg   <= pd_v.reg_field;
            instr_v.is_rep      <= (pd_v.pref_rep != 2'b00);
            instr_v.is_repne    <= (pd_v.pref_rep == 2'b01);
            instr_v.is_32bit    <= pd_v.eff_op32;
            instr_v_valid       <= v_eligible;

            // V-pipe branch target + indirect flag
            branch_target_v       <= v_branch_tgt;
            branch_target_v_valid <= v_is_branch;
            branch_indirect_v     <= v_is_indirect;

            // V-pipe flags dependency
            v_reads_flags         <= ru_v.reads_flags;
            v_writes_flags        <= ru_v.writes_flags;

            // V-pipe address registers
            v_addr_base           <= ru_v.addr_base;
            v_addr_base_valid     <= ru_v.addr_base_valid;
            v_addr_index          <= ru_v.addr_index;
            v_addr_index_valid    <= ru_v.addr_index_valid;
            v_addr_scale          <= ru_v.addr_scale;
            v_mem_size            <= derive_mem_size(pd_v);

        end else if (!s1_valid) begin
            // Pipeline bubble: no valid data upstream, clear outputs.
            // When s1_valid=1 && rename_ready=0: HOLD (stall retention).
            instr_u_valid         <= 0;
            instr_v_valid         <= 0;
            branch_target_u_valid <= 0;
            branch_target_v_valid <= 0;
            branch_indirect_u     <= 0;
            branch_indirect_v     <= 0;
            u_reads_flags         <= 0;
            u_writes_flags        <= 0;
            v_reads_flags         <= 0;
            v_writes_flags        <= 0;
            u_addr_base_valid     <= 0;
            u_addr_index_valid    <= 0;
            v_addr_base_valid     <= 0;
            v_addr_index_valid    <= 0;
        end
    end

endmodule
