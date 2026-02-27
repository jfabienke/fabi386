# fabi386 Instruction Frequency Analysis (99th Percentile)

The small set of mnemonics that account for ~99% of dynamic instruction executions in
"typical" 32-bit 486-era workloads (compiled C/C++ + OS/userland). **~25–40 mnemonics**
cover ~99% in most real programs.

## Core 99% Set (Userland-Heavy, Integer-Heavy)

### Data Movement / Addressing
- `MOV`
- `LEA`
- `PUSH`, `POP`
- `XCHG` (calling sequences / atomic-ish patterns)
- `MOVZX`, `MOVSX` (compiler-dependent; otherwise shifts/ands)

### Arithmetic / Pointer Math
- `ADD`, `SUB`
- `INC`, `DEC` (or ADD/SUB with immediates, compiler-dependent)
- `NEG` (occasional)
- `CMP`

### Bitwise / Masking
- `AND`, `OR`, `XOR`
- `TEST` (very common for flag-setting without changing regs)

### Shifts (Scaling, Bit Tests, Fast Divides/Multiplies by Powers of Two)
- `SHL`/`SAL`
- `SHR`
- `SAR`

### Control Flow
- `JMP`
- `Jcc` family (JE/JNE/JZ/JNZ/JL/JG/JLE/JGE/JA/JB/...)
- `CALL`
- `RET`

### Glue / Misc
- `NOP` (alignment and patch space)
- `SETcc` (compiler-dependent; some prefer branches)

## "Often in the 99%" Set (Workload-Dependent)

### Multiplication / Division
- `IMUL` (more common than expected, even on 486)
- `MUL` (less common than IMUL in C code)
- `DIV`, `IDIV` (usually rare dynamically)

### String/Rep Instructions (Dominates if Lots of Copies/Clears)
- `REP MOVSx` (REP MOVSD / REP MOVSB)
- `REP STOSx` (REP STOSD / REP STOSB)
- `CLD` (once per routine before REP sequences)

### Flag/Carry Aware Arithmetic (Bignum/Crypto/Checksums)
- `ADC`, `SBB`

## OS/Kernel Path Add-ons
Hot in kernel and interrupt-heavy traces:
- `INT` (syscalls, software interrupts)
- `IRET`
- `CLI`, `STI`
- `IN`, `OUT` (drivers; very hot in I/O-heavy scenarios)
- `HLT` (idle loop)

## x87 FPU Hot Set
When x87-heavy code is present:
- `FLD`, `FSTP`
- `FADD`, `FMUL`, `FSUB`, `FDIV` (and `FADDP`, `FMULP`, etc.)
- `FCOM`/`FUCOM` + `FSTSW`/`FNSTSW` sequences
- `FRNDINT` (sometimes), `FSQRT` (sometimes)

## Compact Reference: The "Boiled Down" 99% Set

**Core (~25 mnemonics — hardwired fast-path candidates):**
`MOV`, `LEA`, `PUSH`, `POP`, `ADD`, `SUB`, `INC`, `DEC`, `AND`, `OR`, `XOR`,
`TEST`, `CMP`, `SHL`, `SHR`, `SAR`, `JMP`, `Jcc`, `CALL`, `RET`, `NOP`,
`MOVZX`, `MOVSX`, `IMUL`, `SETcc`

**Kernel/I-O add-ons (optional):**
`INT`, `IRET`, `CLI`, `STI`, `IN`, `OUT`, `REP MOVSx`, `REP STOSx`, `CLD`

## Execution Path Mapping (ISA Audit v10.0)

The ~35–40 "Critical Set" mnemonics map directly to execution paths as follows:

| Path | Coverage | Latency | IPC Impact |
|------|----------|---------|------------|
| **Fast Path (Hardwired)** | Core 25–40 mnemonics (MOV, ADD, Jcc, MOVZX, MOVSX, SETcc, etc.) | Single-cycle | Drives the 1.78 IPC target |
| **Complex Path (Microcode)** | ISA "Tail" (string ops, system calls, transcendentals) | Multi-cycle | Dynamically rare; minimal IPC drag |

**Key conclusion:** The 1.78 IPC target is achievable because the vast majority of
real-world instructions never touch the microcode sequencer. The Fast Path covers
~99% of dynamic execution.
