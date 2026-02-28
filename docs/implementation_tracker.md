# fabi386 Implementation Tracker

**Last updated:** 2026-02-28
**Total RTL:** 18,521 lines across 80 files (+11,661 since initial audit)
**Bench/Scripts:** 2,233 lines (formal, Verilator, Docker)
**Microcode System:** 1,620 lines (compiler 439, defs 181, 7 `.us` files 983, defs.svh 124)
**Overall completion:** ~82%

---

## Pipeline & Core (~92%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 1 | Superscalar decoder (dual-issue, 486DX) | `f386_decode.sv` | 2399 | DONE | 100 | — | Full 1-byte + 2-byte opcodes, ModRM/SIB, prefix, V86, 3-tier Pentium ext decode |
| 2 | Integer ALU (16 ops, 8/16/32-bit) | `f386_alu.v` | 295 | DONE | 100 | — | All EFLAGS, size-aware rotates, ADC/SBB carry-in |
| 3 | x87 FPU (IEEE 754, pipelined) | `f386_fpu_spatial.v` | 767 | DONE | 85 | LOW | Missing: denormals, double-precision, transcendentals (FSIN/FCOS/FPTAN) |
| 4 | SIMD byte-parallel unit | `f386_alu_simd.sv` | 49 | DONE | 100 | — | 4-lane saturating add/sub/min/max/blend |
| 5 | Reorder buffer (16-entry, 2-wide) | `f386_rob.sv` | 318 | DONE | 98 | LOW | Per-entry flags+mask + specbits + ftq_idx storage. SpecBits resolve/squash logic. Missing: exception vector forwarding |
| 6 | Execute stage (dual ALU, CDB, branch, MUL/DIV) | `f386_execute_stage.sv` | 471 | DONE | 98 | LOW | CDB carries flags+mask. Divider + multiplier integrated with OP_MUL_DIV routing. OP_FENCE NOP completion. Missing: zero-latency bypass for back-to-back flag deps |
| 7 | Register rename (8→32, snapshots, pre-warm) | `f386_register_rename.sv` | 266 | DONE | 95 | — | Full V-pipe rename, 4 branch snapshots, busy table, freelist w/ checkpoint, context pre-warm port |
| 7a | Rename map table (spec+com, 4 snapshots) | `f386_rename_maptable.sv` | 157 | DONE | 100 | — | Feature-gated by `CONF_ENABLE_RENAME_SNAP` |
| 7b | Rename free list (bitmap + picker) | `f386_rename_freelist.sv` | 146 | DONE | 100 | — | Checkpoint-capable, full-flush rebuild from com_map |
| 7c | Rename busy table (CDB-cleared) | `f386_rename_busytable.sv` | 86 | DONE | 100 | — | 32-bit busy vector, dual CDB clear ports |
| 8 | Issue queue (8-entry, producer matrix) | `f386_issue_queue.sv` | 321 | DONE | 95 | — | Feature-gated producer matrix wakeup or naive CDB broadcast fallback |
| 8a | Producer matrix (8×8 dependency) | `f386_producer_matrix.sv` | 117 | DONE | 100 | — | Registered CDB column-clear for Fmax |
| 8b | Ready bit table (32 phys regs) | `f386_ready_bit_table.sv` | 76 | DONE | 100 | — | Per-phys-reg readiness tracking |
| 8c | Wakeup select (priority encoder) | `f386_wakeup_select.sv` | 73 | DONE | 100 | — | Age-ordered picker |
| 9 | OoO core top-level | `f386_ooo_core_top.sv` | 905 | DONE | 95 | — | Full pipeline wired. SpecBits, FTQ, safe-trap, shadow stack, semantic logger integrated. Pre-warm port exposed. |
| 10 | Dispatch / pairing logic | `f386_dispatch.sv` | 96 | PARTIAL | 60 | MED | Scoreboard works. Uses undefined `f386_uv_pipe_if` interface |
| 11 | Pipeline top (legacy wrapper) | `f386_pipeline_top.sv` | 76 | STALE | 30 | — | Superseded by `f386_ooo_core_top.sv` |
| 12 | Microcode ROM (legacy, unused) | `f386_microcode_rom.sv` | 77 | STALE | — | — | Superseded by generated ROM (`f386_microcode_rom_gen.sv`) |
| 12a | Microcode sequencer (FSM, v2.0) | `f386_microcode_sequencer.sv` | 218 | DONE | 100 | — | Group opcode remap, REP prefix (REPE/REPNE), REP_YIELD interrupt-safe loops |
| 12b | Microcode ROM generator | `f386_microcode_rom_gen.sv` | 556 | DONE | 100 | — | 142 mnemonics, 311 micro-ops, 28 group remap entries. Auto-generated. |
| 12c | Microcode defs | `f386_microcode_defs.svh` | 124 | DONE | 100 | — | 71 `UCMD_*` special command constants |
| 13 | Package / types | `f386_pkg.sv` | 349 | DONE | 100 | — | MicroArchConf, 3-tier feature gating, all typedefs, `instr_info_t` w/ flags_mask + sem_tag, specbits_t, ftq_entry_t, micro_op_t, exc_info_t, OP_MUL_DIV/BITCOUNT/CMOV/FENCE |
| 14 | SpecBits (4-tag speculation) | `f386_specbits.sv` | 140 | DONE | 100 | — | Per-branch speculation bitmask. Feature-gated by `CONF_ENABLE_SPECBITS` |
| 15 | Fetch Target Queue (8-entry) | `f386_ftq.sv` | 181 | DONE | 100 | — | Circular buffer decoupling fetch from decode. GHR snapshot for branch repair. |
| 16 | Non-restoring divider (8/16/32-bit) | `f386_divider.sv` | 233 | DONE | 100 | — | DIV/IDIV, #DE on overflow/div-by-zero. Multi-cycle FSM. |
| 17 | DSP multiplier (2-cycle pipeline) | `f386_multiplier.sv` | 147 | DONE | 100 | — | MUL/IMUL, Cyclone V DSP inference, CF=OF overflow detection |
| 18 | Prefetch FIFO (16-entry) | `f386_fetch_fifo.sv` | 104 | DONE | 100 | — | 32-bit data + 4-bit fault codes (GP/PF). Empty-FIFO bypass. |
| 19 | Exception priority unit | `f386_exception_unit.sv` | 248 | DONE | 90 | LOW | Priority encoder, double/triple fault detection. Missing: microcode_done feedback |
| 20 | Address generation unit | `f386_agu.sv` | 73 | DONE | 100 | — | base + index×scale + disp + seg_base |

## Branch Prediction (~96%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 21 | Bimodal predictor (256-entry) | `f386_branch_predict.sv` | 51 | DONE | 100 | — | 2-bit saturating counters |
| 22 | Gshare predictor (8-bit GHR) | `f386_branch_predict_gshare.sv` | 59 | DONE | 100 | — | XOR-indexed 256-entry PHT |
| 23 | Return address stack (16-entry) | `f386_ras_unit.sv` | 49 | DONE | 100 | — | Push/pop with sp_ptr recovery |
| 24 | Hybrid selector (Gshare + RAS) | `f386_branch_predict_hybrid.sv` | 67 | DONE | 85 | LOW | Target calc falls back to PC+4; real targets from decode |

## Memory Subsystem (~75%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 25 | L2 cache (128KB, 2-way) | `f386_l2_cache.sv` | 58 | DONE | 100 | — | Tag/data/FSM, BRAM-backed |
| 26 | MMU remap gates (8 programmable) | `f386_mmu_remap_gates.sv` | 45 | DONE | 100 | — | Priority encoder, zero-wait-state |
| 27 | MMU remap (legacy) | `f386_mmu_remap.sv` | 34 | STALE | — | — | Superseded by `_gates` variant |
| 28 | L1 D-Cache (16KB, 4-way set-associative) | `f386_dcache.sv` | 570 | DONE | 95 | — | Write-back, PLRU, 3-cycle pipeline, M10K BRAM. Feature-gated by `CONF_ENABLE_DCACHE`. |
| 28a | MSHR (2-entry non-blocking) | `f386_dcache_mshr.sv` | 140 | DONE | 100 | — | First-free allocation, fill-address matching |
| 29 | Load-Store Queue (8+8, byte-granular) | `f386_lsq.sv` | 451 | DONE | 95 | — | Byte-enable CAM forwarding, D-cache interface (feature-gated), TSO ordering |
| 29a | Memory dependency predictor | `f386_mem_dep_predictor.sv` | 61 | DONE | 100 | — | 128-entry PC-indexed 1-bit MDT |
| 30 | TLB (32-entry fully-associative) | `f386_tlb.sv` | 268 | DONE | 95 | — | CODE/READ/WRITE paths, PLRU, 4KB pages |
| 30a | Hardware page walker | `f386_page_walker.sv` | 230 | DONE | 90 | LOW | 2-level walk FSM (PDE→PTE), A/D bit RMW |
| 30b | TLB flush (INVLPG + full) | `f386_tlb_flush.sv` | 38 | DONE | 100 | — | INVLPG + full flush on CR3 write |
| 31 | HyperRAM controller | *not created* | — | MISSING | 0 | HIGH | MiSTer DE10-Nano main memory interface |

## FPGA Primitives (~100%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 32 | Block RAM wrapper | `f386_block_ram.sv` | 64 | DONE | 100 | — | M10K `no_rw_check` + `DONT_CARE` globally |
| 33 | Distributed RAM (LUT-based) | `f386_distributed_ram.sv` | 71 | DONE | 100 | — | Multi-read via replication |
| 34 | Priority picker | `f386_picker.sv` | 67 | DONE | 100 | — | Configurable width priority encoder |
| 35 | Freelist multi-width | `f386_freelist_multiwidth.sv` | 90 | DONE | 100 | — | N-allocate/free per cycle for rename free list |

## SoC / Peripherals (~65%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 36 | PIC (8259A, dual master/slave) | `f386_pic.sv` | 366 | DONE | 100 | — | Cascaded PIC1+PIC2, ICW/OCW, IRQ priority |
| 37 | PIT (8254, 3 channels) | `f386_pit.sv` | 569 | DONE | 100 | — | IRQ0 for INT 08h, speaker |
| 38 | PS/2 (keyboard + mouse) | `f386_ps2.sv` | 966 | DONE | 100 | — | Keyboard controller + mouse port |
| 39 | VGA (text mode only) | `f386_vga.sv` | 1305 | DONE | 85 | MED | Text mode + attribute decode. Missing: graphics modes |
| 40 | I/O bus address decoder | `f386_iobus.sv` | 257 | DONE | 100 | — | Port address decode + arbiter |
| 41 | RTC stub | `f386_rtc_stub.sv` | 73 | PARTIAL | 20 | LOW | Dummy values. Full MC146818 deferred. |
| 42 | DMA stub | `f386_dma_stub.sv` | 49 | PARTIAL | 10 | LOW | PIO for disk. Full 8237 DMA deferred. |
| 43 | SVGA BitBlt accelerator | `f386_vbe_accel.sv` | 117 | DONE | 100 | — | ROP engine: Copy/XOR/AND/SolidFill |
| 44 | MSR register file | `f386_msr_file.sv` | 98 | DONE | 100 | — | RDMSR/WRMSR, guard config, breakpoints |
| 45 | IDE/DMA storage bridge | `f386_ide_dma.sv` | 109 | PARTIAL | 60 | MED | State machine exists. Missing: SPI master, byte packing |
| 46 | Debug unit (4 BP + 4 WP) | `f386_debug_unit.sv` | 75 | PARTIAL | 50 | LOW | PC breakpoints work. Data watchpoints stubbed |

## MiSTer Integration (~80%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 47 | MiSTer top-level `emu` module | `f386_emu.sv` | 595 | DONE | 90 | — | HPS I/O, OSD, DDRAM bridge, PLL |
| 48 | PLL (CPU + video + memory) | `f386_pll.sv` | 84 | DONE | 100 | — | 50 MHz → CPU/video/memory clocks |
| 49 | Memory controller (DDRAM bridge) | `f386_mem_ctrl.sv` | 224 | DONE | 85 | LOW | Cache line fills, A20 gate. Missing: burst mode |
| 50 | OSD configuration string | `f386_conf_str.sv` | 26 | DONE | 100 | — | MiSTer OSD menu |

## Instrumentation / HARE Suite (~100%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 51 | Execution guard (sandboxing) | `f386_guard_unit.sv` | 47 | DONE | 100 | — | Address range enforcement |
| 52 | Bus snoop engine (DMA coherency) | `f386_snoop_engine.sv` | 50 | DONE | 100 | — | External write detection + L1 invalidation |
| 53 | PASC memory classifier | `f386_pasc_classifier.sv` | 85 | DONE | 100 | — | ISA bus latency measurement |
| 54 | Address classifier | `f386_address_classifier.sv` | 68 | DONE | 100 | — | Memory type identification by latency |
| 55 | V86 mode monitor | `f386_v86_monitor.sv` | 49 | DONE | 100 | — | VM flag tracking + semantic tagging |
| 56 | Stride prefetcher | `f386_prefetch_unit.sv` | 74 | DONE | 100 | — | Confidence-tracked stride detection |
| 57 | AAR telemetry engine | `f386_aar_engine.sv` | 160 | DONE | 100 | — | Wrapper: tagger + shadow stack + stride + DMA |
| 58 | Semantic tagger | `f386_semantic_tagger.sv` | 61 | DONE | 100 | — | 9-pattern prologue/epilogue/syscall/mode-switch |
| 59 | Shadow stack (soc, 512-entry) | `f386_shadow_stack.sv` (soc) | 86 | DONE | 100 | — | CALL/RET tracking, stack_fault on mismatch |
| 60 | Stride detector | `f386_stride_detector.sv` | 69 | DONE | 100 | — | Array/struct inference from bus address patterns |
| 61 | Telemetry DMA | `f386_telemetry_dma.sv` | 152 | DONE | 100 | — | 4-word async packet writes to HyperRAM trace buffer |

## Neo-386 Pro Features (~85%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 62 | Dual-mode hardware shadow stack | `f386_shadow_stack.sv` (core) | 180 | DONE | 90 | — | Host+Guest 32-entry M10K LIFOs, speculative push/pop, retirement validation, mismatch telemetry. Wired in ooo_core_top. |
| 63 | V86 safe-trap fast path | `f386_v86_safe_trap.sv` | 188 | DONE | 85 | — | 16-entry I/O + 8-entry INT safe-lists. Combinational CAM. Pre-loaded defaults (VGA, PIT, keyboard, PIC, DOS). Software-reconfigurable. |
| 64 | Semantic transition logger | `f386_semantic_logger.sv` | 194 | DONE | 90 | — | Zero-cycle transition detector, 8-deep 128-bit FIFO, detects PE/V86/CPL/exception/shadow-mismatch events. |
| 65 | Register rename pre-warm | In `f386_register_rename.sv` | +23 | DONE | 70 | LOW | Port exposed, acceptance logic done. Awaiting scheduler integration. |

## Protected Mode & V86 (~40%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 66 | System register file (CR0-4, EFLAGS, DTRs, CPL) | `f386_sys_regs.sv` | 293 | DONE | 100 | — | All CRs, EFLAGS w/ per-flag masked scatter/gather (BOOM/80x86 pattern), DTRs. CPL from CS.RPL. |
| 67 | Segment shadow registers (6×{sel,cache,valid}) | `f386_seg_cache.sv` | 219 | DONE | 100 | — | 6 segments, ao486-format descriptor caches, extracted bases + limits (G-adjusted), per-segment validity, **write-read bypass on all ports** |
| 68 | Interrupt/exception entry hardware | `f386_exception_unit.sv` | 248 | DONE | 90 | MED | Priority encoder, double/triple fault FSM. Missing: full microcode delivery integration |
| 69 | IRET (ring 0→3, ring 0→V86) | *microcode* | — | PARTIAL | 20 | HIGH | Boot microcode has IRET skeleton. Full ring transitions need microcode expansion |
| 70 | V86-sensitive instruction trapping | `f386_v86_safe_trap.sv` | — | PARTIAL | 40 | HIGH | Safe-trap fast path done. Full IOPL-based #GP trapping for CLI/STI/PUSHF/POPF still needed in decoder |
| 71 | Segment register load validation | *in seg_cache + microcode* | — | MISSING | 0 | HIGH | GDT/LDT descriptor read, DPL check (ring 0/3 fast, ring 1/2 microcode) |
| 72 | VIF/VME acceleration | *in sys_regs + decode* | — | MISSING | 0 | MED | Virtual interrupt flag — CLI/STI/PUSHF/POPF avoid #GP trap in V86 |

## Microcode System (~95%)

| # | Feature | Module/File | Lines | Status | % | Priority | Notes |
|---|---------|-------------|-------|--------|---|----------|-------|
| 73 | Microcode compiler (Python) | `scripts/microcode/microcode_compiler.py` | 439 | DONE | 100 | — | `.us` text → ROM generator. Group opcode remap, 71 special cmds |
| 74 | Micro-op definitions | `scripts/microcode/micro_op_defs.py` | 181 | DONE | 100 | — | 48-bit encoding, 71 `SpecialCmd` entries (0x00–0x45) |
| 75 | Boot-critical microcode (17 mnemonics) | `scripts/microcode/boot_ops.us` | 128 | DONE | 100 | — | MOV CRn, LGDT, LIDT, INT, IRET, PUSHA, POPA, CLI, STI, HLT, far CALL/RET |
| 76 | String operations (14 mnemonics) | `scripts/microcode/string_ops.us` | 131 | DONE | 100 | — | MOVS/STOS/LODS/CMPS/SCAS (byte+dword), INS/OUTS with REP support |
| 77 | Arithmetic MUL/DIV (15 mnemonics) | `scripts/microcode/arith_ops.us` | 131 | DONE | 100 | — | MUL/IMUL/DIV/IDIV (8/16/32), IMUL 2-op+imm, CBW/CWD, NOT/NEG mem |
| 78 | BCD operations (6 mnemonics) | `scripts/microcode/bcd_ops.us` | 50 | DONE | 100 | — | DAA/DAS/AAA/AAS/AAM/AAD |
| 79 | Bit manipulation (14 mnemonics) | `scripts/microcode/bit_ops.us` | 107 | DONE | 100 | — | BT/BTS/BTR/BTC (reg+imm), BSF/BSR, SHLD/SHRD |
| 80 | Segment operations (18 mnemonics) | `scripts/microcode/seg_ops.us` | 135 | DONE | 100 | — | MOV seg, LES/LDS/LFS/LGS/LSS, ARPL, LAR, LSL, VERR/VERW, SGDT/SIDT/SLDT/STR/SMSW/LMSW |
| 81 | Misc operations (58 mnemonics) | `scripts/microcode/misc_ops.us` | 301 | DONE | 100 | — | ENTER/LEAVE, BOUND, XLAT, BSWAP, CMPXCHG/XADD/XCHG, LOOP×3, LAHF/SAHF, MOVZX/MOVSX, SETcc×16, IN/OUT×8, flags×5, FF group (CALL/JMP/PUSH indirect), FE group (INC/DEC mem) |

## Verification & Infrastructure (~40%)

| # | Feature | Files | Lines | Status | % | Priority | Notes |
|---|---------|-------|-------|--------|---|----------|-------|
| 82 | Formal: ALU | `bench/formal/f386_alu.sby` + `_props.sv` | 243 | DONE | 100 | — | All flags, all ops, all operand sizes |
| 83 | Formal: ROB | `bench/formal/f386_rob.sby` + `_props.sv` | 191 | DONE | 100 | — | Ordering/count/flush assertions |
| 84 | Formal: Seg Cache | `bench/formal/f386_seg_cache.sby` + `_props.sv` | 147 | DONE | 100 | — | Bypass correctness assertions |
| 85 | Formal: LSQ | `bench/formal/f386_lsq.sby` + `_props.sv` | 170 | DONE | 100 | — | TSO ordering invariants, forwarding correctness |
| 86 | Formal: TLB | `bench/formal/f386_tlb.sby` + `_props.sv` | 160 | DONE | 100 | — | Translation correctness, flush completeness, PLRU invariants |
| 87 | Verilator: OoO core TB | `bench/verilator/tb_ooo_core.cpp` | 180 | DONE | 80 | MED | Clock driver, memory model, trace compare |
| 88 | Verilator: ALU tests | `bench/verilator/test_alu_basic.cpp` | 199 | DONE | 100 | — | ALU instruction sequences |
| 89 | Verilator: Branch tests | `bench/verilator/test_branch.cpp` | 170 | DONE | 100 | — | Branch prediction/recovery |
| 90 | Memory model | `bench/verilator/memory_model.h` | 132 | DONE | 100 | — | Flat 4GB memory model with binary image loading |
| 91 | Docker (Verilator + Yosys + SymbiYosys) | `docker/Dockerfile` | 78 | DONE | 100 | — | Reproducible verification environment |
| 92 | Quartus project / constraints | `f386.qpf`, `f386.qsf` | 134 | PARTIAL | 70 | MED | QSF complete (91 source files, pin/synth settings). Missing: `f386.sdc` timing constraints |

---

## Category Summary

| Category | Items | Done | Partial | Missing | Completion |
|----------|-------|------|---------|---------|------------|
| Pipeline & Core | 28 | 25 | 2 | 1 | **92%** |
| Branch Prediction | 4 | 4 | 0 | 0 | **96%** |
| Memory Subsystem | 11 | 9 | 0 | 1 | **89%** |
| FPGA Primitives | 4 | 4 | 0 | 0 | **100%** |
| SoC / Peripherals | 11 | 7 | 4 | 0 | **72%** |
| MiSTer Integration | 4 | 4 | 0 | 0 | **92%** |
| Instrumentation (HARE) | 11 | 11 | 0 | 0 | **100%** |
| Neo-386 Pro | 4 | 4 | 0 | 0 | **87%** |
| Protected Mode & V86 | 7 | 3 | 2 | 2 | **45%** |
| Microcode System | 9 | 9 | 0 | 0 | **95%** |
| Verification | 11 | 9 | 0 | 2 | **85%** |
| **Overall** | **104** | **93** | **8** | **6** | **~87%** |

---

## FPGA Resource Budget (Estimated)

| Domain | ALMs | BRAM (M10K) | DSP | Status |
|--------|------|-------------|-----|--------|
| OoO Core (pipeline, IQ, ROB, rename, specbits, FTQ) | ~11,700 | 2 | 0 | Implemented |
| LSQ (8+8, byte-CAM) | ~1,200 | 0 | 0 | Implemented |
| TLB + Page Walker | ~1,350 | 0 | 0 | Implemented |
| D-Cache (16KB, 4-way) + MSHR | ~950 | 5 | 0 | Implemented |
| Divider + Multiplier | ~500 | 0 | 4 | Implemented |
| Microcode (sequencer + ROM, 142 mnemonics) | ~850 | 5 | 0 | Implemented |
| Exception Unit | ~550 | 0 | 0 | Implemented |
| Neo-386 Pro (shadow stack, safe-trap, logger) | ~350 | 2 | 0 | Implemented |
| Branch Prediction (gshare + RAS + hybrid) | ~250 | 1 | 0 | Implemented |
| Peripherals (PIC, PIT, PS2, VGA text, I/O bus) | ~3,200 | 8 | 0 | Implemented |
| MiSTer Integration (emu, PLL, mem ctrl) | ~650 | 2 | 0 | Implemented |
| L2 Cache (128KB) | ~300 | 64 | 0 | Implemented |
| FPGA Primitives (RAM, picker, freelist) | ~280 | 0 | 0 | Implemented |
| Instrumentation (HARE, 11 modules) | ~1,500 | 4 | 0 | Implemented |
| Pentium Extensions (CMOVcc, bitcount, MMX, fences) | ~320 | 0 | 0 | 3-tier feature-gated (all off by default) |
| **Estimated Total** | **~25,050** | **~95** | **4** | |
| **Cyclone V Budget** | **41,910** | **553** | **112** | |
| **Utilization** | **~60%** | **~17%** | **~4%** | Comfortable headroom |

---

## Phase P1 OoO Performance Track — Completed

| Sub-phase | Items | Status | Files Created/Modified | Lines Added |
|-----------|-------|--------|----------------------|-------------|
| P1.1 Rename Snapshots | Map table, free list, busy table | DONE | 3 new + 1 rewrite | ~630 |
| P1.2 Producer Matrix | Dep matrix, ready bits, wakeup, IQ rewrite | DONE | 3 new + 1 rewrite | ~590 |
| P1.3 SpecBits + FTQ | Speculation bits, fetch target queue, ROB update | DONE | 2 new + 2 modified | ~285 |
| P1.4 D-Cache + LSQ | 16KB 4-way D$, MSHR, LSQ v2.0 (8+8 byte-CAM), MDT | DONE | 3 new + 2 modified | ~1,222 |
| P1.5 Supporting | Prefetch FIFO, divider, multiplier, shadow stack, seg bypass | DONE | 4 new + 2 modified | ~860 |
| P1.6 Neo-386 Pro | V86 safe-trap, semantic logger, rename pre-warm, wiring | DONE | 2 new + 3 modified | ~560 |
| P1.7 Microcode ISA | 142 mnemonics (6 new `.us` files), compiler v2 (group remap), sequencer v2 (REP), 71 special cmds | DONE | 6 new `.us` + 4 modified | ~1,620 |
| P1.8 Pentium Ext | CMOVcc, POPCNT/LZCNT/TZCNT, basic MMX, PREFETCH, RDPMC, CPUID | DONE | 2 new + 4 modified | ~350 |
| P1.8b Gate Restructure | 3-tier gates (P5/P3/Nehalem), MFENCE/LFENCE/SFENCE, QSF sync | DONE | 1 new + 6 modified | ~305 |
| **P1 Total** | | **ALL DONE** | **26 new + 21 modified** | **~6,422** |

---

## Critical Path to First Boot (Revised)

| Step | Work Required | Depends On | Est. Lines | Status |
|------|---------------|------------|------------|--------|
| 1 | ~~LSU (Load Store Unit)~~ | — | ~~350~~ | **DONE** (P1.4: 451-line LSQ + 73-line AGU) |
| 2 | ~~System register file~~ | — | ~~372~~ | **DONE** (293 lines) |
| 3 | ~~L1 D-cache~~ | LSU | ~~400~~ | **DONE** (P1.4: 570+140 lines) |
| 4 | ~~TLB (32-entry, 386 paging)~~ | L1, sys regs (CR3) | ~~250~~ | **DONE** (B1: 268+230+38 lines) |
| 5 | ~~Exception priority unit~~ | Sys regs, LSU | ~~250~~ | **DONE** (B2: 248 lines) |
| 6 | V86-sensitive instruction trapping (CLI/STI/PUSHF/POPF/INT/IN/OUT) | Sys regs, exc unit | ~200 | **PARTIAL** (safe-trap done, IOPL-based #GP pending) |
| 7 | Segment register load validation (ring 0/3 fast, ring 1/2 microcode) | Sys regs, LSU | ~250 | MISSING |
| 8 | ~~Divider/Multiplier~~ | — | ~~280~~ | **DONE** (P1.5: 233+147 lines) |
| 9 | ~~Microcode ISA expansion~~ | LSU | ~~600~~ | **DONE** (P1.7: 142 mnemonics, 311 micro-ops, 7 `.us` files) |
| 10 | ~~HyperRAM/DDRAM controller~~ | — | ~~300~~ | **DONE** (B3: 224-line mem_ctrl) |
| 11 | ~~FPGA top-level + clock/reset~~ | All above | ~~250~~ | **DONE** (B3: 595+84+26 lines) |
| 12 | ~~Verilator testbench~~ | Top-level | ~~300~~ | **DONE** (Phase 0: 681 lines bench) |
| 13 | ~~VGA text mode~~ | — | ~~350~~ | **DONE** (B3: 1305 lines) |
| 14 | Quartus project + constraints | Synthesis | ~140 | MISSING |
| **Remaining** | | | **~590** | **2 items left** |

**Boot readiness: ~92% complete.** The two remaining items are segment register load validation (~250 lines) and Quartus project files (~140 lines).

---

## ISA Coverage

| Category | Planned | Decoder | ALU/FPU | Microcode | MUL/DIV | Effective |
|----------|---------|---------|---------|-----------|---------|-----------|
| Integer arithmetic (ADD/SUB/ADC/SBB/INC/DEC/NEG) | ~80 forms | Yes | Yes | NEG/NOT mem (F7/2,3) | — | **100%** |
| Logic (AND/OR/XOR/NOT/TEST) | ~50 forms | Yes | Yes | — | — | **100%** |
| Shifts/rotates (SHL/SHR/SAR/ROL/ROR/RCL/RCR) | ~63 forms | Yes | Partial | SHLD/SHRD | — | **90%** |
| Data movement (MOV/PUSH/POP/XCHG/LEA) | ~45 forms | Yes | — | XCHG mem, PUSH mem (FF/6), LEA, MOVZX, MOVSX | — | **90%** |
| Control flow (Jcc/CALL/RET/JMP/LOOP) | ~55 forms | Yes | Branch unit | CALL/JMP indirect (FF/2-5), LOOP×3 | — | **95%** |
| String ops (MOVS/CMPS/SCAS/LODS/STOS) | ~15 forms | Yes | — | **14 mnemonics** (byte+dword, INS/OUTS, REP) | — | **95%** |
| Multiply/Divide (MUL/IMUL/DIV/IDIV) | ~24 forms | Yes | — | **15 mnemonics** (8/16/32, signed/unsigned, 2-op, imm) | **Yes** | **95%** |
| BCD (DAA/DAS/AAA/AAS/AAM/AAD) | 6 mnemonics | Yes | — | **6 mnemonics** | — | **100%** |
| x87 FPU (FADD-FIST, FINIT) | ~350 forms | Yes | 13 ops | — | — | **40%** |
| System (LGDT/MOV CRx/SGDT/SIDT/SMSW/LMSW) | ~50 forms | Yes | — | **30+ ops** (boot + seg_ops) | — | **70%** |
| 486 additions (BSWAP/CMPXCHG/XADD) | 6 mnemonics | Yes | — | **5 mnemonics** | — | **95%** |
| Bit operations (BT/BTS/BTR/BTC/BSF/BSR) | ~16 forms | Yes | — | **14 mnemonics** (reg+imm) | — | **95%** |
| I/O (IN/OUT/INS/OUTS) | ~12 forms | Yes | — | **12 mnemonics** | — | **100%** |
| Segment (LES/LDS/LFS/LGS/LSS/ARPL/LAR/LSL/VERR/VERW) | ~18 forms | Yes | — | **18 mnemonics** | — | **95%** |
| Misc (ENTER/LEAVE/BOUND/XLAT/LAHF/SAHF/SETcc/flags) | ~30 forms | Yes | — | **28 mnemonics** (SETcc×16, flags×5) | — | **95%** |
| **Total** | **~207 mnemonics / ~900 forms** | **207** | **~50** | **142** | **MUL/DIV** | **~85%** |

---

## Architectural Decisions

- **Ring 0/3 fast path, ring 1/2 microcode only.** Hardware privilege checks handle ring 0 ↔ ring 3 and ring 0 ↔ V86 transitions in ~5 cycles. Ring 1/2 transitions (only used by OS/2) fall back to microcode (~50+ cycles).
- **99th-percentile instruction focus.** The Core 25 mnemonics are all fast-path. Microcode is only needed for the "often in 99%" tier (REP MOVS/STOS, 1-op MUL/DIV, INT/IRET).
- **Flags travel through ROB (BOOM/RSD pattern).** ALU flags + per-flag write mask stored per ROB entry. Architectural EFLAGS updated only at retirement. Dual-retire merges flags in program order (V wins on overlap).
- **CPL = CS.RPL (ao486 pattern).** No independent CPL register — privilege level derived from CS selector bits [1:0].
- **Feature gating via CONF_ENABLE_*.** Advanced OoO features (specbits, producer matrix, rename snapshots, D-cache, TAGE) are individually toggleable. Start conservative, enable progressively.
- **Neo-386 Pro dual-mode shadow stack.** Isolated Host/Guest LIFOs for CALL/RET validation. Hardware detects ROP/stack-pivot attacks at retirement with zero software overhead.
- **V86 safe-trap fast path.** Programmable lookup tables route known-safe V86 I/O and INT operations to fast microcode (~20-30 cycles) instead of full hypervisor trap (~200+ cycles).
- **Semantic transition logging.** Zero-cycle hardware event detection at retirement. Mode changes, ring transitions, exceptions, and shadow stack mismatches automatically logged to 8-deep FIFO for HARE DMA.
- **Context pre-warm via rename.** On imminent context switch, scheduler can pre-map new task's registers into free physical registers. Leverages existing rename snapshots for zero cold-start penalty.

---

## Revision History

| Date | Changes |
|------|---------|
| 2026-02-27 | Initial tracker created from RTL audit |
| 2026-02-27 | ROB rewritten: 42→224 lines, CDB writeback, precise exceptions |
| 2026-02-27 | ALU rewritten: 34→295 lines, all 6 EFLAGS, 16 ops, 8/16/32-bit |
| 2026-02-27 | FPU rewritten: 29→767 lines, IEEE 754, x87 stack, 13 ops |
| 2026-02-27 | Execute stage rewritten: 120→300 lines, dual ALU, CDB, branch resolution |
| 2026-02-27 | OoO core top rewritten: 74→410 lines, full pipeline integration |
| 2026-02-27 | Package: added `instr_info_t` struct, resolved compile errors |
| 2026-02-27 | Expert review fixes: LZC priority encoders, DIV normalization, rotate size-awareness |
| 2026-02-27 | AAR engine created: semantic tagger, shadow stack, stride detector, telemetry DMA |
| 2026-02-27 | Instrumentation suite now 100% complete (11/11 modules) |
| 2026-02-27 | Added Protected Mode & V86 category. Revised critical path for V86 boot. |
| 2026-02-27 | Architectural decisions: ring 0/3 fast path, 99th-percentile instruction focus |
| 2026-02-27 | System register file created: CR0-4, EFLAGS, DTRs, CPL, flush pulses |
| 2026-02-27 | Segment shadow register file created: 6 segments, ao486-format caches |
| 2026-02-27 | Package expanded: seg/dtr/cr enums, EFLAGS/ALU/descriptor constants |
| 2026-02-27 | OoO core top: sys_regs + seg_cache integrated, retirement flags writeback |
| 2026-02-28 | Phase 0: MicroArchConf (80 lines in pkg), FPGA RAM primitives (4 modules, 292 lines), Verilator TB (681 lines), SymbiYosys formal (911 lines) |
| 2026-02-28 | Phase B1: LSQ v1.0 (334 lines, 4+4 word-aligned), AGU (73 lines), TLB (268 lines), page walker (230 lines), TLB flush (38 lines) |
| 2026-02-28 | Phase B2: Microcode compiler (325 lines Python), boot_ops.us (128 lines), sequencer (156 lines), ROM gen (105 lines), defs (53 lines), exception unit (248 lines) |
| 2026-02-28 | Phase B3: PIC (366), PIT (569), PS2 (966), VGA text (1305), I/O bus (257), RTC stub (73), DMA stub (49), MiSTer emu (595), PLL (84), mem_ctrl (224), conf_str (26) |
| 2026-02-28 | Phase P1.1: Rename snapshots — maptable (157), freelist (146), busytable (86), register_rename rewrite (243→266) |
| 2026-02-28 | Phase P1.2: Producer matrix — producer_matrix (117), ready_bit_table (76), wakeup_select (73), issue_queue rewrite (47→321) |
| 2026-02-28 | Phase P1.3: SpecBits (140), FTQ (181), ROB updated (+35 lines specbits/ftq_idx), ooo_core_top updated (+60 lines) |
| 2026-02-28 | Phase P1.4: D-Cache (570), MSHR (140), LSQ v2.0 rewrite (334→451, 8+8 byte-CAM), MDT (61), pkg bumped LSQ sizes 4→8 |
| 2026-02-28 | Phase P1.5: Prefetch FIFO (104), divider (233), multiplier (147), shadow stack (180), seg_cache bypass (+35 lines), execute_stage MUL/DIV (+55 lines), pkg OP_MUL_DIV |
| 2026-02-28 | Phase P1.6: V86 safe-trap (188), semantic logger (194), rename pre-warm (+23 lines), ooo_core_top wiring (+155 lines, safe-trap + shadow stack + logger instantiation), pkg sem_tag field |
| 2026-02-28 | Full project sv2v clean: 78 files, 17,579 lines, zero errors, zero warnings |
| 2026-02-28 | Phase P1.7: Microcode ISA expansion — 6 new `.us` files (string_ops 131, arith_ops 131, bcd_ops 50, bit_ops 107, seg_ops 135, misc_ops 301). Compiler v2.0 (group opcode remap, 71 special cmds). Sequencer v2.0 (REP prefix, REPE/REPNE, REP_YIELD). Generated ROM: 556 lines, 142 mnemonics, 311 micro-ops, 28 group remap entries. ISA coverage 58%→85%. |
| 2026-02-28 | Full project sv2v clean: 79 files, 18,216 lines, zero errors |
| 2026-02-28 | Phase P1.8b: 3-tier feature gate restructure (PENTIUM/P3/NEHALEM). OP_FENCE for MFENCE/LFENCE/SFENCE. CPUID reports per-tier family/model + feature bits. Decode re-gated: PREFETCH→P3, POPCNT/LZCNT/TZCNT→NEHALEM. Bitcount generate block→NEHALEM. |
| 2026-02-28 | QSF updated: 91 source files (was ~45). Added all P1.1-P1.8b modules + HARE suite + memory subsystem. `quartus_synth_check.sh` script created. `fpga_resource_budget.md` rewritten for Cyclone V ALM/M10K/DSP. |
| 2026-02-28 | Full project sv2v clean: 80 files, 18,521 lines, zero errors |
