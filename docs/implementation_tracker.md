# fabi386 Implementation Tracker

**Last updated:** 2026-02-27
**Total RTL:** 5,938 lines across 30 files
**Overall completion:** ~65%

---

## Pipeline & Core (~82%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 1 | Superscalar decoder (dual-issue, 486DX) | `f386_decode.sv` | 2304 | DONE | 100 | — | Full 1-byte + 2-byte opcodes, ModRM/SIB, prefix, V86 |
| 2 | Integer ALU (16 ops, 8/16/32-bit) | `f386_alu.v` | 295 | DONE | 100 | — | All EFLAGS, size-aware rotates, ADC/SBB carry-in |
| 3 | x87 FPU (IEEE 754, pipelined) | `f386_fpu_spatial.v` | 767 | DONE | 85 | LOW | Missing: denormals, double-precision, transcendentals (FSIN/FCOS/FPTAN) |
| 4 | SIMD byte-parallel unit | `f386_alu_simd.sv` | 49 | DONE | 100 | — | 4-lane saturating add/sub/min/max/blend |
| 5 | Reorder buffer (16-entry, 2-wide) | `f386_rob.sv` | 224 | DONE | 95 | LOW | Missing: exception vector forwarding to trap handler |
| 6 | Execute stage (dual ALU, CDB, branch) | `f386_execute_stage.sv` | 300 | DONE | 95 | LOW | Missing: EFLAGS forwarding bypass (zero-latency) |
| 7 | Register rename (8->32 physical) | `f386_register_rename.sv` | 49 | DONE | 80 | MED | Missing: V-pipe rename, checkpoint/rollback on flush |
| 8 | Issue queue / reservation station | `f386_issue_queue.sv` | 47 | DONE | 70 | MED | Missing: CDB broadcast wakeup, age-priority select, V-pipe |
| 9 | OoO core top-level | `f386_ooo_core_top.sv` | 410 | DONE | 90 | LOW | Full pipeline wired. Missing: EFLAGS fwd, LSU hookup |
| 10 | Dispatch / pairing logic | `f386_dispatch.sv` | 96 | PARTIAL | 60 | MED | Scoreboard works. Uses undefined `f386_uv_pipe_if` interface |
| 11 | Pipeline top (legacy wrapper) | `f386_pipeline_top.sv` | 76 | STALE | 30 | — | Superseded by `f386_ooo_core_top.sv` |
| 12 | Microcode ROM | `f386_microcode_rom.sv` | 77 | PARTIAL | 5 | HIGH | 5 of ~207 mnemonics. Blocks complex ops (MUL/DIV/string/PUSHA) |
| 13 | Package / types | `f386_pkg.sv` | 113 | DONE | 100 | — | `instr_info_t`, `ooo_instr_t`, `rob_entry_t`, `telemetry_pkt_t` |

## Branch Prediction (~96%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 14 | Bimodal predictor (256-entry) | `f386_branch_predict.sv` | 51 | DONE | 100 | — | 2-bit saturating counters |
| 15 | Gshare predictor (8-bit GHR) | `f386_branch_predict_gshare.sv` | 55 | DONE | 100 | — | XOR-indexed 256-entry PHT |
| 16 | Return address stack (16-entry) | `f386_ras_unit.sv` | 49 | DONE | 100 | — | Push/pop with sp_ptr recovery |
| 17 | Hybrid selector (Gshare + RAS) | `f386_branch_predict_hybrid.sv` | 67 | DONE | 85 | LOW | Target calc falls back to PC+4; real targets from decode |

## Memory Subsystem (~40%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 18 | L2 cache (128KB, 2-way) | `f386_l2_cache.sv` | 58 | DONE | 100 | — | Tag/data/FSM, BRAM-backed |
| 19 | MMU remap gates (8 programmable) | `f386_mmu_remap_gates.sv` | 45 | DONE | 100 | — | Priority encoder, zero-wait-state |
| 20 | MMU remap (legacy) | `f386_mmu_remap.sv` | 34 | STALE | — | — | Superseded by `_gates` variant |
| 21 | L1 I/D cache (32KB) | *not created* | — | MISSING | 0 | **CRIT** | Required for any real workload performance |
| 22 | TLB (256-entry) | *not created* | — | MISSING | 0 | **CRIT** | Required for protected mode paging |
| 23 | HyperRAM controller | *not created* | — | MISSING | 0 | **CRIT** | MiSTer DE10-Nano main memory interface |

## SoC / Peripherals (~35%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 24 | SVGA BitBlt accelerator | `f386_vbe_accel.sv` | 117 | DONE | 100 | — | ROP engine: Copy/XOR/AND/SolidFill |
| 25 | MSR register file | `f386_msr_file.sv` | 98 | DONE | 100 | — | RDMSR/WRMSR, guard config, breakpoints |
| 26 | IDE/DMA storage bridge | `f386_ide_dma.sv` | 109 | PARTIAL | 60 | MED | State machine exists. Missing: SPI master, byte packing |
| 27 | Debug unit (4 BP + 4 WP) | `f386_debug_unit.sv` | 75 | PARTIAL | 50 | LOW | PC breakpoints work. Data watchpoints stubbed |
| 28 | SVGA top-level engine | *not created* | — | MISSING | 0 | HIGH | VGA timing, framebuffer, CRTC, mode control |
| 29 | Audio DSP (OPL3) | *not created* | — | MISSING | 0 | LOW | Planned for 48 DSP slices |
| 30 | FPGA top-level (`fabi386_top.sv`) | *not created* | — | MISSING | 0 | HIGH | Clock/reset, pin mux, bus arbitration |

## Instrumentation / HARE Suite (~90%)

| # | Feature | Module | Lines | Status | % | Priority | Notes |
|---|---------|--------|-------|--------|---|----------|-------|
| 31 | Execution guard (sandboxing) | `f386_guard_unit.sv` | 47 | DONE | 100 | — | Address range enforcement |
| 32 | Bus snoop engine (DMA coherency) | `f386_snoop_engine.sv` | 50 | DONE | 100 | — | External write detection + L1 invalidation |
| 33 | PASC memory classifier | `f386_pasc_classifier.sv` | 85 | DONE | 100 | — | ISA bus latency measurement |
| 34 | Address classifier | `f386_address_classifier.sv` | 68 | DONE | 100 | — | Memory type identification by latency |
| 35 | V86 mode monitor | `f386_v86_monitor.sv` | 49 | DONE | 100 | — | VM flag tracking + semantic tagging |
| 36 | Stride prefetcher | `f386_prefetch_unit.sv` | 74 | DONE | 100 | — | Confidence-tracked stride detection |
| 37 | AAR telemetry engine | *not created* | — | MISSING | 0 | MED | Shadow stack, thermal map, trace DMA |

## Verification & Infrastructure (~25%)

| # | Feature | Files | Status | % | Priority | Notes |
|---|---------|-------|--------|---|----------|-------|
| 38 | Package / types | `f386_pkg.sv` | DONE | 100 | — | Single source of truth |
| 39 | Testbenches | *none* | MISSING | 0 | **CRIT** | No `_tb.sv`, no cocotb, no Verilator harness |
| 40 | Synthesis scripts | *none* | MISSING | 0 | HIGH | `build_bitstream.sh` referenced but absent |
| 41 | Pin constraints (MiSTer) | *none* | MISSING | 0 | HIGH | `pins.lpf` / `.qsf` for DE10-Nano |

---

## Category Summary

| Category | Items | Done | Partial | Missing | Completion |
|----------|-------|------|---------|---------|------------|
| Pipeline & Core | 13 | 9 | 2 | 1 | **82%** |
| Branch Prediction | 4 | 4 | 0 | 0 | **96%** |
| Memory Subsystem | 6 | 2 | 0 | 3 | **40%** |
| SoC / Peripherals | 7 | 2 | 2 | 3 | **35%** |
| Instrumentation | 7 | 6 | 0 | 1 | **90%** |
| Verification | 4 | 1 | 0 | 3 | **25%** |
| **Overall** | **41** | **24** | **4** | **11** | **~65%** |

---

## Critical Path to First Boot

The minimum set of work required to boot real DOS software on MiSTer:

| Step | Work Required | Depends On | Est. Lines |
|------|---------------|------------|------------|
| 1 | L1 I-cache + D-cache | — | ~400 |
| 2 | TLB (256-entry, 486 paging) | L1 cache | ~250 |
| 3 | HyperRAM controller | — | ~300 |
| 4 | Microcode ROM expansion (~50 key ops) | — | ~500 |
| 5 | FPGA top-level + clock/reset | L1, TLB, HyperRAM | ~250 |
| 6 | Verilator testbench (Dhrystone) | Top-level | ~300 |
| 7 | SVGA top-level (basic VGA timing) | — | ~350 |
| **Total** | | | **~2,350** |

After these 7 items, the design can synthesize for DE10-Nano and boot a DOS binary.

---

## FPGA Resource Budget (Planned)

| Domain | LUTs | BRAM (18Kb) | DSP (18x18) | Status |
|--------|------|-------------|-------------|--------|
| OoO Core & Pipeline | 32,700 | 24 | 4 | Mostly implemented |
| L2 Cache (128KB) | 1,400 | 64 | 0 | Implemented |
| BTB (4096-entry) | 600 | 12 | 0 | Not started |
| Audio DSP (OPL3) | 850 | 4 | 48 | Not started |
| Instrumentation (HARE) | 10,450 | 60 | 0 | Mostly implemented |
| SVGA & Accelerator | 11,550 | 6 | 8 | Partial (accel done, SVGA missing) |
| PnR Buffer | ~5,500 | — | — | Headroom |
| **Total** | **~63,000** | **170** | **60** | |

Target: Cyclone V 5CSEBA6U23I7 (DE10-Nano) — 41,910 ALMs / 166,036 LE equivalent

---

## ISA Coverage

| Category | Planned | Decoder | ALU/FPU | Microcode | Effective |
|----------|---------|---------|---------|-----------|-----------|
| Integer arithmetic (ADD/SUB/ADC/SBB/INC/DEC/NEG) | ~80 forms | Yes | Yes | — | **100%** |
| Logic (AND/OR/XOR/NOT/TEST) | ~50 forms | Yes | Yes | — | **100%** |
| Shifts/rotates (SHL/SHR/SAR/ROL/ROR/RCL/RCR) | ~63 forms | Yes | Partial | — | **85%** (RCL/RCR missing) |
| Data movement (MOV/PUSH/POP/XCHG/LEA) | ~45 forms | Yes | — | Partial | **60%** |
| Control flow (Jcc/CALL/RET/JMP/LOOP) | ~55 forms | Yes | Branch unit | — | **90%** |
| String ops (MOVS/CMPS/SCAS/LODS/STOS) | ~15 forms | Yes | — | No | **10%** (decode only) |
| x87 FPU (FADD-FIST, FINIT) | ~350 forms | Yes | 13 ops | — | **40%** (single-precision) |
| System (LGDT/MOV CRx/INVD/WBINVD) | ~50 forms | Yes | — | 3 ops | **15%** |
| 486 additions (BSWAP/CMPXCHG/XADD) | 6 mnemonics | Yes | — | No | **10%** (decode only) |
| Bit operations (BT/BTS/BTR/BTC) | ~16 forms | Yes | — | No | **10%** (decode only) |
| I/O (IN/OUT) | ~12 forms | Yes | — | No | **10%** (decode only) |
| **Total** | **~207 mnemonics / ~900 forms** | **207** | **~50** | **5** | **~55%** |

---

## Revision History

| Date | Changes |
|------|---------|
| 2026-02-27 | Initial tracker created from RTL audit |
| 2026-02-27 | ROB rewritten: 42->224 lines, CDB writeback, precise exceptions |
| 2026-02-27 | ALU rewritten: 34->295 lines, all 6 EFLAGS, 16 ops, 8/16/32-bit |
| 2026-02-27 | FPU rewritten: 29->767 lines, IEEE 754, x87 stack, 13 ops |
| 2026-02-27 | Execute stage rewritten: 120->300 lines, dual ALU, CDB, branch resolution |
| 2026-02-27 | OoO core top rewritten: 74->410 lines, full pipeline integration |
| 2026-02-27 | Package: added `instr_info_t` struct, resolved compile errors |
| 2026-02-27 | Expert review fixes: LZC priority encoders, DIV normalization, rotate size-awareness |
