# fabi386 ISA Coverage Analysis: 80486DX Mnemonic & Form Count

## Mnemonic Count Summary

| Scope                              | Count         |
|------------------------------------|---------------|
| Integer + System (386 + 486 adds)  | ~115–125      |
| x87 FPU (80387-compatible)         | ~75–85        |
| **Combined (assembler-visible)**   | **~200 (±10)**|
| Strict architectural (Intel PRM)   | **~207**      |

### 486-Specific Additions (vs 386)
- `BSWAP`
- `CMPXCHG`
- `XADD`
- `INVD`
- `WBINVD`
- `INVLPG`

## Fully Expanded Instruction Forms (~900)

### Integer Core Breakdown (~450–550 forms)

| Category                        | Forms   | Notes                                          |
|---------------------------------|---------|-------------------------------------------------|
| Data movement (MOV family)      | ~35–45  | Includes Sreg, CRx, DRx, TRx variants         |
| Arithmetic & logic (8 instrs)   | ~80     | 10 forms × 8 (ADD/SUB/AND/OR/XOR/CMP/ADC/SBB) |
| INC/DEC/NOT/NEG/MUL/IMUL/DIV   | ~35–40  | Group opcodes + IMUL 2-/3-operand              |
| Shifts & rotates (7 instrs)     | ~63     | 9 forms × 7 (ROL/ROR/RCL/RCR/SHL/SHR/SAR)    |
| Control transfer                | ~55     | 16 Jcc short + 16 Jcc near + CALL/RET/etc.    |
| String instructions             | ~15     | MOVS/CMPS/SCAS/LODS/STOS × byte/word/dword    |
| System / 486 additions          | ~50     | LGDT/LIDT/INVD/WBINVD/CMPXCHG/XADD/BSWAP     |
| Bit operations                  | ~16     | BT/BTS/BTR/BTC × r/m,r and r/m,imm × 16/32   |
| I/O                             | ~12     | IN/OUT × AL/AX/EAX × imm8/DX                  |

### x87 FPU Breakdown (~350–450 forms)
- Arithmetic: ST(0),ST(i) / ST(i),ST(0) / m32real / m64real / FADDP forms
- Comparisons, loads/stores, environment control, transcendentals

### Grand Totals

| Metric                          | Count       |
|---------------------------------|-------------|
| Assembler-visible forms         | **~900 (±100)** |
| Distinct binary encodings       | **~650–750**    |

## Mnemonic Count Ambiguity Sources

1. **Aliases:** JE/JZ and JNE/JNZ are same opcode, different mnemonics
2. **Operand forms:** IMUL has 1-, 2-, and 3-operand forms (same mnemonic)
3. **Inclusion scope:** Undocumented opcodes, system instructions, FPU
