# fabi386 FPGA Resource Budget — Cyclone V 5CSEBA6U23I7N (DE10-Nano)

**Last updated:** 2026-03-02
**Commit:** `a4843cb` — Fix maptable bypass, dest_valid gating, br_tag propagation
**Tool:** Quartus Prime 21.1 Lite (Analysis & Synthesis, `--parallel=1`, Rosetta VM)

## Device Capacity

| Resource | Available | Notes |
|----------|-----------|-------|
| **ALMs** | 41,910 | Adaptive Logic Modules |
| **Combinational ALUTs** | 83,820 | 2 per ALM |
| **Registers** | 166,036 | Dedicated logic registers |
| **M10K Blocks** | 553 | 10,240 bits each (5,662,720 total) |
| **MLAB Bits** | 480,960 | Distributed RAM (subset of ALMs) |
| **DSP 18×18** | 112 | Variable-precision multipliers |
| **PLLs** | 6 | Fractional PLLs |

---

## Measured Resources (Quartus Synthesis)

Source: `quartus_map` Analysis & Synthesis — 0 errors, 234 warnings.

### Summary

| Resource | Used | Max | Utilization |
|----------|------|-----|-------------|
| ALMs (estimated) | 11,206 | 41,910 | 26.7% |
| Combinational ALUTs | 14,764 | 83,820 | 17.6% |
| Dedicated Registers | 5,517 | 166,036 | 3.3% |
| Block Memory (M10K) | 128 bits | 5,662,720 bits | <0.1% |
| MLAB Memory | 0 | 480,960 bits | 0.0% |
| DSP Blocks | 9 | 112 | 8.0% |

### Per-Module Breakdown

| Module | ALUTs | Regs | M10K | DSPs |
|--------|------:|-----:|-----:|-----:|
| **OoO CPU Core** | | | | |
| f386_ooo_core_top (glue) | 131 | 32 | - | - |
| f386_decode | 2,223 | 338 | - | - |
| f386_execute_stage (routing) | 501 | - | - | - |
| &emsp; f386_alu (U-pipe) | 1,079 | - | - | - |
| &emsp; f386_alu (V-pipe) | 1,114 | - | - | - |
| &emsp; f386_alu_simd | 231 | - | - | - |
| &emsp; f386_fpu_spatial | 2,313 | 549 | - | 1 |
| &emsp; f386_divider | 542 | 173 | - | - |
| &emsp; f386_multiplier | 169 | 188 | - | 7 |
| f386_branch_predict_hybrid | 1,618 | 1,036 | - | - |
| &emsp; f386_branch_predict_gshare | 1,364 | 520 | - | - |
| &emsp; f386_ras_unit | 30 | 516 | - | - |
| f386_issue_queue | 1,670 | 1,288 | - | - |
| f386_register_rename | 1,095 | 141 | - | - |
| &emsp; f386_rename_freelist (+picker) | 650 | 32 | - | - |
| &emsp; f386_rename_busytable | 210 | 32 | - | - |
| f386_phys_regfile | 1,446 | 1,024 | - | - |
| **SoC Peripherals** | | | | |
| f386_vga | 92 | 101 | 1 | - |
| f386_mem_ctrl | 53 | 255 | - | - |
| f386_sys_regs | 14 | 5 | - | - |
| **Trimmed by Quartus (0 ALUTs)** | | | | |
| f386_specbits | 0† | 0 | - | - |
| f386_ftq | 0† | 0 | - | - |
| f386_seg_cache | 0† | 0 | - | - |
| f386_v86_safe_trap | 0† | 0 | - | - |
| f386_shadow_stack | 0† | 0 | - | - |
| f386_semantic_logger | 0† | 0 | - | - |
| f386_pic | 0† | 0 | - | - |
| f386_pit | 0† | 0 | - | - |
| f386_ps2 | 0† | 0 | - | - |
| f386_iobus | 0† | 0 | - | - |
| **MEASURED TOTAL** | **14,764** | **5,517** | **1** | **9** |

† Quartus optimized to 0: inputs tied to constants (microcode sequencer, LSU, segment
load logic not yet connected). See "Quartus-Trimmed Modules" below for Yosys estimates.

---

## Excluded Blocks (Feature-Gated Off — Estimated)

Estimates derived from RTL parameter analysis and Yosys `cells/5` heuristic.
Yosys overcounts ~10–15% vs Quartus due to lack of cross-module optimization.

### Memory Subsystem

| Module | ALUTs | Regs | M10K | Notes |
|--------|------:|-----:|-----:|-------|
| f386_dcache (16KB 4-way WB) | ~950 | - | 18 | Data 16×M10K + Tags 2×M10K |
| f386_dcache_mshr (2-entry) | ~50 | ~130 | - | FF-based miss buffers |
| f386_tlb (32-entry fully-assoc) | ~1,350 | ~200 | - | 32-way CAM, tree-PLRU |
| f386_page_walker (2-level) | ~150 | ~100 | - | PDE→PTE FSM, A/D RMW |
| f386_tlb_flush | ~0 | - | - | Pure wiring |
| f386_mmu_remap | ~20 | - | - | 2 range comparators |
| f386_l2_cache (32KB stub) | ~300 | ~50 | 42 | Data 26×M10K + Tags 16×M10K |

### Execution / Dispatch

| Module | ALUTs | Regs | M10K | Notes |
|--------|------:|-----:|-----:|-------|
| f386_lsq (8LQ + 8SQ) | ~1,200 | ~300 | - | SQ→LQ byte-granular CAM |
| f386_dispatch (scoreboard) | ~200 | ~10 | - | SV interface, Pentium U+V rules |

### ISA Extensions (CONF_ENABLE_* = 0)

| Feature Gate | ALUTs | Notes |
|-------------|------:|-------|
| PENTIUM_EXT (CMOVcc, MMX, RDPMC) | ~150 | CMOVcc 12-case mux + decode gates |
| P3_EXT (PREFETCH, fences, CLFLUSH) | ~30 | Decode-only, NOP completion |
| NEHALEM_EXT (POPCNT, LZCNT, TZCNT) | ~250 | f386_alu_bitcount (104 lines) |

### Predictor (Phase P2)

| Module | ALUTs | Notes |
|--------|------:|-------|
| TAGE predictor (not yet coded) | ~2,000–4,000 | 8-component, 4K entries/table estimate |

### Quartus-Trimmed Modules (Yosys Estimates)

These modules are instantiated in the current build but Quartus optimized them to 0 ALUTs
because their inputs are tied to constants (microcode sequencer, LSU, and segment load
logic are not yet connected). Once connected, they will consume the resources below.

Estimates use Yosys `cells/5` heuristic (overcounts ~10–15% vs Quartus).

| Module | ALMs (est) | Regs | Notes |
|--------|----------:|-----:|-------|
| f386_ftq | ~623 | 618 | Fetch target queue, 8-entry circular buffer |
| f386_shadow_stack | ~1,417 | 2,076 | 16-deep shadow stack + mismatch detector |
| f386_semantic_logger | ~623 | 988 | AAR telemetry DMA engine |
| f386_ps2 | ~396 | 608 | PS/2 keyboard controller + scan-code FSM |
| f386_pit | ~355 | 334 | 8254-compatible 3-channel timer |
| f386_pic | ~274 | 16 | 8259A-compatible interrupt controller |
| f386_v86_safe_trap | ~239 | 360 | V86 mode IOPL-sensitive trap handler |
| f386_seg_cache | ~238 | 486 | 6-entry segment descriptor cache |
| f386_sys_regs | ~141 | 373 | CR0–CR4, EFLAGS, system MSRs |
| f386_iobus | ~134 | 85 | I/O port address decoder + bus mux |
| f386_specbits | ~32 | 8 | 4-entry branch speculation bit manager |
| **Trimmed Subtotal** | **~4,472** | **~5,952** | |

### Excluded Subtotal (no TAGE, no trimmed)

| Resource | Estimated |
|----------|-----------|
| ALUTs | ~4,650 |
| Registers | ~790 |
| M10K Blocks | 60 |

### Excluded + Trimmed Subtotal (no TAGE)

| Resource | Estimated |
|----------|-----------|
| ALUTs | ~9,120 |
| Registers | ~6,740 |
| M10K Blocks | 60 |

---

## Projected Full Design

Measured (14,764 ALUTs) + excluded blocks (~4,650) + trimmed modules (~4,470).

### Without TAGE

| Resource | Projected | Max | Utilization |
|----------|-----------|-----|-------------|
| ALMs | ~19,500 | 41,910 | ~46.5% |
| Combinational ALUTs | ~23,900 | 83,820 | ~28.5% |
| Dedicated Registers | ~12,260 | 166,036 | ~7.4% |
| M10K Blocks | 61 | 553 | ~11.0% |
| DSP Blocks | 9 | 112 | 8.0% |

### With TAGE (Phase P2)

| Resource | Projected | Max | Utilization |
|----------|-----------|-----|-------------|
| ALMs | ~22,000 | 41,910 | ~52.5% |

### Headroom

- **ALMs:** ~22,400 remaining (~53%) without TAGE
- **M10K:** ~492 remaining (~89%) — real 128KB 2-way L2 would use ~192 M10K (35%)
- **DSP:** 103 remaining (~92%) — available for Audio DSP (OPL3) or FPU improvements
- **Registers:** ~154K remaining (~93%)

---

## Notes

- L2 cache stub is 32KB direct-mapped. A real 128KB 2-way WB design would use
  ~160 M10K (data) + ~32 M10K (tags) = ~192 M10K (34.7% of device).
- Block memory in measured build is font ROM only (VGA character generator, 4K×8).
- V-pipe ALU now active at 1,114 ALUTs (was 3 ALUTs when inputs undriven).
- All feature gates (`CONF_ENABLE_*`) are at 0 except `CONF_ENABLE_V86`.
- 10 modules optimized to 0 by Quartus due to constant-folded inputs. Largest:
  shadow_stack (~1,417 ALMs), FTQ (~623), semantic_logger (~623), PS2 (~396).
  These will reappear once microcode sequencer, LSU, and segment load are connected.
- `f386_sys_regs` shows 14 ALUTs in Quartus vs ~141 ALMs from Yosys — most CR/MSR
  logic eliminated because no consumer reads the registers yet.

---

## Synthesis History

| Date | Commit | ALMs | ALUTs | Regs | M10K | DSPs | Notes |
|------|--------|-----:|------:|-----:|-----:|-----:|-------|
| 2026-03-02 | `a4843cb` | 11,206 | 14,764 | 5,517 | 1 | 9 | Fix #1/#2/#7: maptable bypass, dest_valid, br_tag |

## Verification Procedure

After each feature implementation:

```bash
# 1. sv2v smoke test (fast, runs on dev machine)
sv2v -I rtl/core rtl/top/f386_pkg.sv rtl/primitives/*.sv rtl/core/*.sv \
     rtl/memory/*.sv rtl/soc/*.sv rtl/top/*.sv > build/f386_sv2v_full.v

# 2. Quartus synthesis (on Quartus VM, ~2 min)
./scripts/quartus_synth_check.sh [VM_IP]

# 3. Update this document with real numbers from the report
```
