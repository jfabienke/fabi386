#!/usr/bin/env python3
"""
fabi386: Microcode Compiler
----------------------------
Reads structured .us microcode text files and generates SystemVerilog ROM.

Input format (boot_ops.us):
    @MNEMONIC opcode [flags]
      step: operation [operands...]
      step: operation [operands...]
      ...

Output: SystemVerilog indexed ROM as f386_microcode_rom_gen.sv

Usage:
    python3 microcode_compiler.py boot_ops.us [more_files.us...] -o output.sv

Reference: 80x86/rtl/microcode/ (58 .us files)
"""

import sys
import os
import re
import argparse
from dataclasses import dataclass, field
from typing import List, Dict, Optional
from micro_op_defs import *


@dataclass
class MicrocodeEntry:
    """A single microcode sequence (one x86 instruction)."""
    mnemonic: str
    opcode: int
    is_0f: bool = False
    is_atomic: bool = False
    group_ext: int = -1  # ModRM.reg extension (-1 = not a group opcode)
    steps: List[MicroOp] = field(default_factory=list)


def parse_register(name: str) -> int:
    """Parse register name to encoding."""
    reg_map = {
        'eax': 0, 'ecx': 1, 'edx': 2, 'ebx': 3,
        'esp': 4, 'ebp': 5, 'esi': 6, 'edi': 7,
        'ax': 0, 'cx': 1, 'dx': 2, 'bx': 3,
        'sp': 4, 'bp': 5, 'si': 6, 'di': 7,
        'al': 0, 'cl': 1, 'dl': 2, 'bl': 3,
    }
    return reg_map.get(name.lower(), 0)


def parse_seg_register(name: str) -> int:
    """Parse segment register name to encoding."""
    seg_map = {
        'es': 0, 'cs': 1, 'ss': 2, 'ds': 3, 'fs': 4, 'gs': 5
    }
    return seg_map.get(name.lower(), 0)


def parse_step(line: str, is_last: bool, is_atomic: bool) -> MicroOp:
    """Parse a single micro-op step line."""
    parts = line.strip().split()
    if not parts:
        return MicroOp(is_last=is_last, is_atomic=is_atomic)

    op_name = parts[0].upper()
    uop = MicroOp(is_last=is_last, is_atomic=is_atomic)

    # Special commands
    special_cmds = {
        'NOP': SpecialCmd.NOP,
        'LOAD_SEG': SpecialCmd.LOAD_SEG,
        'STORE_SEG': SpecialCmd.STORE_SEG,
        'LOAD_CR': SpecialCmd.LOAD_CR,
        'STORE_CR': SpecialCmd.STORE_CR,
        'LOAD_DTR': SpecialCmd.LOAD_DTR,
        'STORE_DTR': SpecialCmd.STORE_DTR,
        'INT_ENTER': SpecialCmd.INT_ENTER,
        'INT_EXIT': SpecialCmd.INT_EXIT,
        'HALT': SpecialCmd.HALT,
        'CLI': SpecialCmd.CLI,
        'STI': SpecialCmd.STI,
        'PUSH_FLAGS': SpecialCmd.PUSH_FLAGS,
        'POP_FLAGS': SpecialCmd.POP_FLAGS,
        'FAR_CALL': SpecialCmd.FAR_CALL,
        'FAR_RET': SpecialCmd.FAR_RET,
        'TASK_SW': SpecialCmd.TASK_SW,
        # String operations
        'STRING_LOAD': SpecialCmd.STRING_LOAD,
        'STRING_STORE': SpecialCmd.STRING_STORE,
        'REP_SETUP': SpecialCmd.REP_SETUP,
        'REP_STEP': SpecialCmd.REP_STEP,
        'REP_YIELD': SpecialCmd.REP_YIELD,
        # Multiply / Divide
        'MUL_EXEC': SpecialCmd.MUL_EXEC,
        'DIV_EXEC': SpecialCmd.DIV_EXEC,
        'MUL_READ_HI': SpecialCmd.MUL_READ_HI,
        'DIV_READ_Q': SpecialCmd.DIV_READ_Q,
        'DIV_READ_R': SpecialCmd.DIV_READ_R,
        # BCD
        'BCD_DAA': SpecialCmd.BCD_DAA,
        'BCD_DAS': SpecialCmd.BCD_DAS,
        'BCD_AAA': SpecialCmd.BCD_AAA,
        'BCD_AAS': SpecialCmd.BCD_AAS,
        'BCD_AAM': SpecialCmd.BCD_AAM,
        'BCD_AAD': SpecialCmd.BCD_AAD,
        # Bit manipulation
        'BIT_TEST': SpecialCmd.BIT_TEST,
        'BIT_SET': SpecialCmd.BIT_SET,
        'BIT_RESET': SpecialCmd.BIT_RESET,
        'BIT_COMP': SpecialCmd.BIT_COMP,
        'BIT_SCAN_FWD': SpecialCmd.BIT_SCAN_FWD,
        'BIT_SCAN_REV': SpecialCmd.BIT_SCAN_REV,
        'SHLD_OP': SpecialCmd.SHLD_OP,
        'SHRD_OP': SpecialCmd.SHRD_OP,
        # Byte / Extension
        'BSWAP_OP': SpecialCmd.BSWAP_OP,
        'MOVZX_OP': SpecialCmd.MOVZX_OP,
        'MOVSX_OP': SpecialCmd.MOVSX_OP,
        'CBW_CWDE': SpecialCmd.CBW_CWDE,
        'CWD_CDQ': SpecialCmd.CWD_CDQ,
        # Atomic read-modify-write
        'XCHG_OP': SpecialCmd.XCHG_OP,
        'CMPXCHG_OP': SpecialCmd.CMPXCHG_OP,
        'XADD_OP': SpecialCmd.XADD_OP,
        # Control / Misc
        'ENTER_FRAME': SpecialCmd.ENTER_FRAME,
        'LEAVE_FRAME': SpecialCmd.LEAVE_FRAME,
        'BOUND_CHK': SpecialCmd.BOUND_CHK,
        'XLAT_OP': SpecialCmd.XLAT_OP,
        'LOOP_DEC': SpecialCmd.LOOP_DEC,
        'LAHF_OP': SpecialCmd.LAHF_OP,
        'SAHF_OP': SpecialCmd.SAHF_OP,
        'SETCC_OP': SpecialCmd.SETcc_OP,
        'IO_IN': SpecialCmd.IO_IN,
        'IO_OUT': SpecialCmd.IO_OUT,
        # Segment operations
        'LOAD_FAR_PTR': SpecialCmd.LOAD_FAR_PTR,
        'ARPL_CHK': SpecialCmd.ARPL_CHK,
        'LAR_CHK': SpecialCmd.LAR_CHK,
        'LSL_CHK': SpecialCmd.LSL_CHK,
        'VERR_CHK': SpecialCmd.VERR_CHK,
        'VERW_CHK': SpecialCmd.VERW_CHK,
        # Flag manipulation
        'CLC_OP': SpecialCmd.CLC_OP,
        'STC_OP': SpecialCmd.STC_OP,
        'CMC_OP': SpecialCmd.CMC_OP,
        'CLD_OP': SpecialCmd.CLD_OP,
        'STD_OP': SpecialCmd.STD_OP,
    }

    if op_name in special_cmds:
        uop.op_type = int(MicroOpType.SYS_CALL)
        uop.special_cmd = int(special_cmds[op_name])
        # Parse optional register operands
        for p in parts[1:]:
            if p.lower() in ('es', 'cs', 'ss', 'ds', 'fs', 'gs'):
                uop.seg_reg = parse_seg_register(p)
            elif p.lower() in ('eax', 'ecx', 'edx', 'ebx', 'esp', 'ebp', 'esi', 'edi'):
                uop.dest_reg = parse_register(p)
        return uop

    # ALU operations
    alu_ops = {
        'ADD': AluOp.ADD, 'SUB': AluOp.SUB, 'AND': AluOp.AND, 'OR': AluOp.OR,
        'XOR': AluOp.XOR, 'SHL': AluOp.SHL, 'SHR': AluOp.SHR, 'SAR': AluOp.SAR,
        'ADC': AluOp.ADC, 'SBB': AluOp.SBB, 'NOT': AluOp.NOT, 'NEG': AluOp.NEG,
        'INC': AluOp.INC, 'DEC': AluOp.DEC,
    }

    if op_name in alu_ops:
        uop.op_type = int(MicroOpType.ALU_REG)
        uop.alu_op = int(alu_ops[op_name])
        if len(parts) >= 2:
            uop.dest_reg = parse_register(parts[1].rstrip(','))
        if len(parts) >= 3:
            uop.src_a_reg = parse_register(parts[2].rstrip(','))
        if len(parts) >= 4:
            uop.src_b_reg = parse_register(parts[3])
        return uop

    # LOAD / STORE
    if op_name == 'LOAD':
        uop.op_type = int(MicroOpType.LOAD)
        if len(parts) >= 2:
            uop.dest_reg = parse_register(parts[1].rstrip(','))
        return uop

    if op_name == 'STORE':
        uop.op_type = int(MicroOpType.STORE)
        if len(parts) >= 2:
            uop.src_a_reg = parse_register(parts[1].rstrip(','))
        return uop

    # PUSH (syntactic sugar: store to [ESP-4], then ESP -= 4)
    if op_name == 'PUSH':
        uop.op_type = int(MicroOpType.STORE)
        if len(parts) >= 2:
            uop.src_a_reg = parse_register(parts[1])
        uop.dest_reg = int(Reg.ESP)
        uop.special_cmd = 0x80  # Flag: pre-decrement ESP
        return uop

    # POP (syntactic sugar: load from [ESP], then ESP += 4)
    if op_name == 'POP':
        uop.op_type = int(MicroOpType.LOAD)
        if len(parts) >= 2:
            uop.dest_reg = parse_register(parts[1])
        uop.src_a_reg = int(Reg.ESP)
        uop.special_cmd = 0x81  # Flag: post-increment ESP
        return uop

    # MOV (register-to-register)
    if op_name == 'MOV':
        uop.op_type = int(MicroOpType.ALU_REG)
        uop.alu_op = int(AluOp.OR)  # MOV implemented as OR with 0
        if len(parts) >= 2:
            uop.dest_reg = parse_register(parts[1].rstrip(','))
        if len(parts) >= 3:
            uop.src_a_reg = parse_register(parts[2])
        return uop

    # Default: NOP
    print(f"Warning: Unknown micro-op '{op_name}', treating as NOP", file=sys.stderr)
    return uop


def parse_us_file(filename: str) -> List[MicrocodeEntry]:
    """Parse a .us microcode source file."""
    entries = []
    current_entry: Optional[MicrocodeEntry] = None
    current_steps: List[str] = []

    with open(filename, 'r') as f:
        for line_num, line in enumerate(f, 1):
            # Strip comments
            line = re.sub(r'#.*$', '', line)
            stripped = line.strip()

            if not stripped:
                continue

            # New mnemonic: @NAME opcode [atomic]
            if stripped.startswith('@'):
                # Finalize previous entry
                if current_entry and current_steps:
                    for i, step_line in enumerate(current_steps):
                        is_last = (i == len(current_steps) - 1)
                        uop = parse_step(step_line, is_last, current_entry.is_atomic)
                        current_entry.steps.append(uop)
                    entries.append(current_entry)

                parts = stripped[1:].split()
                mnemonic = parts[0]
                opcode = int(parts[1], 0) if len(parts) > 1 else 0
                is_0f = 'prefix_0f' in stripped.lower() or opcode > 0xFF
                is_atomic = 'atomic' in stripped.lower()
                group_ext = -1

                # Parse group N (ModRM.reg extension for group opcodes)
                group_match = re.search(r'group\s+(\d+)', stripped, re.IGNORECASE)
                if group_match:
                    group_ext = int(group_match.group(1))

                if is_0f and opcode > 0xFF:
                    opcode = opcode & 0xFF  # Strip 0F prefix from opcode

                current_entry = MicrocodeEntry(
                    mnemonic=mnemonic,
                    opcode=opcode,
                    is_0f=is_0f,
                    is_atomic=is_atomic,
                    group_ext=group_ext,
                )
                current_steps = []

            elif current_entry is not None:
                # Step line (may have leading step number like "0:" or "1:")
                step_line = re.sub(r'^\d+\s*:\s*', '', stripped)
                current_steps.append(step_line)

    # Finalize last entry
    if current_entry and current_steps:
        for i, step_line in enumerate(current_steps):
            is_last = (i == len(current_steps) - 1)
            uop = parse_step(step_line, is_last, current_entry.is_atomic)
            current_entry.steps.append(uop)
        entries.append(current_entry)

    return entries


def generate_sv(entries: List[MicrocodeEntry], output_file: str):
    """Generate SystemVerilog ROM from parsed microcode entries."""

    # Build ROM: {is_0f, opcode[7:0], step[5:0]} → 48-bit micro-op
    # Group opcodes (F6/F7/FE/FF, 0F 00/01/BA) use virtual opcodes in
    # the 0F address space (0xD0-0xFF) to avoid collision.
    rom: Dict[int, int] = {}  # address → encoded micro-op
    # Metadata: (is_0f, effective_opcode) → (max_step, is_0f, is_atomic)
    meta: Dict[int, tuple] = {}
    # Group remap: (is_0f, base_opcode, modrm_reg) → effective virtual opcode
    group_remap: Dict[tuple, int] = {}
    next_virtual = 0xD0  # Virtual opcode allocation starts at 0xD0 in 0F space

    for entry in entries:
        base_opcode = entry.opcode & 0xFF

        if entry.group_ext >= 0:
            # Group opcode: allocate virtual opcode in 0F space
            remap_key = (1 if entry.is_0f else 0, base_opcode, entry.group_ext)
            if remap_key not in group_remap:
                group_remap[remap_key] = next_virtual
                next_virtual += 1
            eff_opcode = group_remap[remap_key]
            is_0f_eff = True  # All virtual opcodes live in 0F space
        else:
            eff_opcode = base_opcode
            is_0f_eff = entry.is_0f

        key = (1 if is_0f_eff else 0, eff_opcode)

        for step_idx, uop in enumerate(entry.steps):
            addr = (eff_opcode << 6) | (step_idx & 0x3F)
            if is_0f_eff:
                addr |= (1 << 14)  # Bit 14 = 0F prefix flag
            rom[addr] = uop.encode()

        meta[key] = (len(entry.steps), is_0f_eff, entry.is_atomic)

    with open(output_file, 'w') as f:
        f.write("/*\n")
        f.write(" * fabi386: Generated Microcode ROM\n")
        f.write(f" * Auto-generated by microcode_compiler.py — DO NOT EDIT\n")
        f.write(f" * {len(entries)} mnemonics, {len(rom)} micro-ops\n")
        f.write(" */\n\n")

        f.write("`ifndef F386_MICROCODE_ROM_GEN_SV\n")
        f.write("`define F386_MICROCODE_ROM_GEN_SV\n\n")

        # ROM lookup function
        f.write("function automatic logic [47:0] microcode_rom_lookup(\n")
        f.write("    input logic [14:0] addr  // {is_0f, opcode[7:0], step[5:0]}\n")
        f.write(");\n")
        f.write("    case (addr)\n")

        for addr in sorted(rom.keys()):
            f.write(f"        15'h{addr:04X}: microcode_rom_lookup = 48'h{rom[addr]:012X};\n")

        f.write(f"        default:    microcode_rom_lookup = 48'h000000000000;\n")
        f.write("    endcase\n")
        f.write("endfunction\n\n")

        # Max step count lookup
        f.write("function automatic logic [5:0] microcode_max_step(\n")
        f.write("    input logic [7:0] opcode,\n")
        f.write("    input logic       is_0f\n")
        f.write(");\n")
        f.write("    case ({is_0f, opcode})\n")

        for key in sorted(meta.keys()):
            is_0f_bit, opcode = key
            max_steps, _, _ = meta[key]
            f.write(f"        9'h{(is_0f_bit << 8) | opcode:03X}: "
                    f"microcode_max_step = 6'd{max_steps};\n")

        f.write(f"        default: microcode_max_step = 6'd1;\n")
        f.write("    endcase\n")
        f.write("endfunction\n\n")

        # Atomic flag lookup
        f.write("function automatic logic microcode_is_atomic(\n")
        f.write("    input logic [7:0] opcode,\n")
        f.write("    input logic       is_0f\n")
        f.write(");\n")
        f.write("    case ({is_0f, opcode})\n")

        for key in sorted(meta.keys()):
            is_0f_bit, opcode = key
            _, _, is_atomic = meta[key]
            if is_atomic:
                f.write(f"        9'h{(is_0f_bit << 8) | opcode:03X}: "
                        f"microcode_is_atomic = 1'b1;\n")

        f.write(f"        default: microcode_is_atomic = 1'b0;\n")
        f.write("    endcase\n")
        f.write("endfunction\n\n")

        # Group opcode remap function
        f.write("// Group opcode remap: {is_0f, opcode, modrm_reg} → virtual opcode in 0F space\n")
        f.write("// Returns {remap_is_0f, remap_opcode} — 9 bits\n")
        f.write("function automatic logic [8:0] microcode_group_remap(\n")
        f.write("    input logic [7:0] opcode,\n")
        f.write("    input logic       is_0f,\n")
        f.write("    input logic [2:0] modrm_reg\n")
        f.write(");\n")

        if group_remap:
            f.write("    case ({is_0f, opcode, modrm_reg})\n")
            for remap_key in sorted(group_remap.keys()):
                is_0f_bit, base_op, modrm = remap_key
                virt_op = group_remap[remap_key]
                case_val = (is_0f_bit << 11) | (base_op << 3) | modrm
                f.write(f"        12'h{case_val:03X}: "
                        f"microcode_group_remap = 9'h{(1 << 8) | virt_op:03X};"
                        f"  // {base_op:#04x}/{modrm} → 0F {virt_op:#04x}\n")
            f.write(f"        default: microcode_group_remap = {{is_0f, opcode}};\n")
            f.write("    endcase\n")
        else:
            f.write("    microcode_group_remap = {is_0f, opcode};\n")

        f.write("endfunction\n\n")

        f.write("`endif\n")

    print(f"Generated {output_file}: {len(entries)} mnemonics, {len(rom)} micro-ops")


def main():
    parser = argparse.ArgumentParser(description='fabi386 Microcode Compiler')
    parser.add_argument('input_files', nargs='+', help='.us microcode source files')
    parser.add_argument('-o', '--output', default='../../rtl/core/f386_microcode_rom_gen.sv',
                        help='Output SystemVerilog file')
    args = parser.parse_args()

    all_entries = []
    for filename in args.input_files:
        print(f"Parsing {filename}...")
        entries = parse_us_file(filename)
        all_entries.extend(entries)
        print(f"  Found {len(entries)} mnemonics")

    print(f"\nTotal: {len(all_entries)} mnemonics")
    generate_sv(all_entries, args.output)


if __name__ == '__main__':
    main()
