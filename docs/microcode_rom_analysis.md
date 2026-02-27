# fabi386 Silicon Area Analysis: Microcode ROM (Phase 7 Final)

This report quantifies the transistor requirements for the Microcode ROM, comparing the
"Complex Path" requirements of a standard 386 versus our "Ultra-RE" i486DX implementation.

## 1. Transistor Budget Breakdown

To handle 100% binary compatibility for 207 mnemonics and ~900 forms, the microcode storage
and sequencing logic have been expanded to a total of **~135,000 transistors**.

| Logic Component        | Transistor Est. | Purpose                                                        |
|------------------------|-----------------|----------------------------------------------------------------|
| Micro-ROM (Pointers)   | 42,000          | Stores sequence lengths and pointers to the Nano-Store.        |
| Nano-ROM (Control)     | 48,000          | Stores the unique 32-bit control words (Nano-ops).             |
| x87 FPU Sequencer      | 30,000          | Specialized iterative logic for transcendental functions.      |
| Atomic Commit Logic    | 8,500           | Hardware barriers in the ROB to ensure atomic retirement.      |
| Decomposition Logic    | 6,500           | Interface between the Unified Decoder and the Issue Queue.     |
| **TOTAL**              | **135,000**     | **~24% of the Total SoC Transistor Budget.**                   |

## 2. FPGA-Native Compression (The Hierarchical Approach)

The ~135k figure is achieved through a **Two-Level Hierarchical Control Store**, which is
significantly more efficient for FPGA synthesis:

### A. Nano-Store De-duplication

Instead of storing a full 32-bit micro-op for every step of every instruction, we identify
that many instructions share identical control signals (e.g., PUSH and CALL both perform a
"Decrement ESP + Write" sequence). The Nano-ROM stores each unique control pattern only once.
The Micro-ROM then just stores 8-bit pointers to these patterns.

### B. Operand-Agnostic Templates

The Microcode no longer stores specific register IDs. Instead, it uses **Template Placeholders**
(e.g., `SOURCE_REG`, `DEST_REG`). The hardware "Fix-up" logic injects the actual register IDs
from the instruction's ModR/M byte into the micro-op as it is dispatched. This collapses
~900 instruction forms into just ~200 mnemonic sequences.

### C. BRAM/LUTRAM Split

- **Micro-ROM (BRAM):** Large and sequential. Ideal for Block RAM primitives.
- **Nano-ROM (LUTRAM):** Shallow and wide. Ideal for Distributed RAM / LUTRAM, allowing for
  zero-latency translation from a pointer to a control word.

## 3. Density Comparison

| Architecture              | Total Mnemonics | Microcode Transistors | Logic Path                    |
|---------------------------|-----------------|-----------------------|-------------------------------|
| Original i386DX           | ~80             | ~30,000               | Standard In-Order             |
| fabi386 Standard          | ~80             | ~35,000               | Variable Latency              |
| fabi386 Pro (v10)         | 207             | ~135,000              | Hierarchical OoO Decomposer  |
