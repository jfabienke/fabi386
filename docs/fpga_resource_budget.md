# fabi386 FPGA Resource Budget — Cyclone V 5CSEBA6U23I7N (DE10-Nano)

**Last updated:** 2026-03-09
**Commit:** `d903e8f` — Quartus synthesis with full memory stack (LSQ + L2 SP + TLB)
**Build pipeline:** Quartus Prime 17.0.2 (NAS) via `scripts/quartus_synth_check.sh --backend nas`

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

Source: `quartus_map` Analysis & Synthesis — 0 errors.

### Summary

| Resource | Used | Max | Utilization |
|----------|------|-----|-------------|
| ALMs (estimated) | 26,164 | 41,910 | 62.4% |
| Combinational ALUTs | 32,943 | 83,820 | 39.3% |
| Dedicated Registers | 17,380 | 166,036 | 10.5% |
| Block Memory (M10K) | 1,122,944 bits | 5,662,720 bits | 19.8% |
| MLAB Memory | 0 | 480,960 bits | 0.0% |
| DSP Blocks | 9 | 112 | 8.0% |

### Per-Module Breakdown

| Module | ALUTs | Regs | M10K bits | DSPs |
|--------|------:|-----:|----------:|-----:|
| **L2 Cache (Split-Phase)** | | | | |
| f386_l2_cache_sp (logic) | 16,058 | 10,613 | - | - |
| &emsp; 4-way × 4-word data SRAM | - | - | 1,048,576 | - |
| &emsp; 4-way tag SRAM | - | - | 73,728 | - |
| &emsp; evict_buf + mh_wdata | - | - | 512 | - |
| **OoO CPU Core** | | | | |
| f386_ooo_core_top (glue) | 657 | 238 | - | - |
| f386_decode | 2,701 | 341 | - | - |
| f386_execute_stage (routing) | 317 | - | - | - |
| &emsp; f386_alu (U-pipe) | 1,081 | - | - | - |
| &emsp; f386_alu (V-pipe) | 1,348 | - | - | - |
| &emsp; f386_alu_simd | 208 | - | - | - |
| &emsp; f386_fpu_spatial | 2,262 | 549 | - | 1 |
| &emsp; f386_divider | 495 | 173 | - | - |
| &emsp; f386_multiplier | 168 | 188 | - | 7 |
| f386_branch_predict_hybrid | 1,616 | 1,036 | - | - |
| &emsp; f386_branch_predict_gshare | 1,364 | 520 | - | - |
| &emsp; f386_ras_unit | 28 | 516 | - | - |
| f386_issue_queue | 1,718 | 1,384 | - | - |
| f386_register_rename | 1,089 | 141 | - | - |
| &emsp; f386_rename_freelist (+picker) | 652 | 32 | - | - |
| &emsp; f386_rename_busytable | 210 | 32 | - | - |
| &emsp; f386_rename_maptable | 227 | 77 | - | - |
| f386_phys_regfile | 1,443 | 1,024 | - | - |
| f386_rob | 535 | 493 | - | - |
| **Memory Subsystem (in core)** | | | | |
| f386_lsq | 838 | 871 | - | - |
| f386_agu | 96 | - | - | - |
| f386_mem_req_arbiter | 74 | - | - | - |
| f386_mmio_io_path | 35 | 110 | - | - |
| f386_dtlb_frontend | 35 | 34 | - | - |
| f386_lsq_to_memctrl_shim | (in glue) | | - | - |
| **SoC Peripherals** | | | | |
| f386_vga | 94 | 101 | 128 | 1 |
| f386_sys_regs | 14 | 5 | - | - |
| f386_ftq | 56 | 74 | - | - |
| **Trimmed by Quartus (0 ALUTs)** | | | | |
| f386_specbits | 0† | 0 | - | - |
| f386_seg_cache | 0† | 0 | - | - |
| f386_v86_safe_trap | 0† | 0 | - | - |
| f386_shadow_stack | 0† | 0 | - | - |
| f386_semantic_logger | 0† | 0 | - | - |
| f386_pic | 0† | 0 | - | - |
| f386_pit | 0† | 0 | - | - |
| f386_ps2 | 0† | 0 | - | - |
| f386_iobus | 0† | 0 | - | - |
| **MEASURED TOTAL** | **32,943** | **17,380** | **~110 M10K** | **9** |

† Quartus optimized to 0: inputs tied to constants (microcode sequencer, segment load
logic not yet connected). See "Quartus-Trimmed Modules" below for Yosys estimates.

---

## Excluded Blocks (Feature-Gated Off — Estimated)

Estimates derived from RTL parameter analysis and Yosys `cells/5` heuristic.
Yosys overcounts ~10–15% vs Quartus due to lack of cross-module optimization.

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

These modules are instantiated but Quartus optimized them to 0 ALUTs because their
inputs are tied to constants. Once connected, they will consume resources below.

Estimates use Yosys `cells/5` heuristic (overcounts ~10–15% vs Quartus).

| Module | ALMs (est) | Regs | Notes |
|--------|----------:|-----:|-------|
| f386_shadow_stack | ~1,417 | 2,076 | 16-deep shadow stack + mismatch detector |
| f386_semantic_logger | ~623 | 988 | AAR telemetry DMA engine |
| f386_ps2 | ~396 | 608 | PS/2 keyboard controller + scan-code FSM |
| f386_pit | ~355 | 334 | 8254-compatible 3-channel timer |
| f386_pic | ~274 | 16 | 8259A-compatible interrupt controller |
| f386_v86_safe_trap | ~239 | 360 | V86 mode IOPL-sensitive trap handler |
| f386_seg_cache | ~238 | 486 | 6-entry segment descriptor cache |
| f386_iobus | ~134 | 85 | I/O port address decoder + bus mux |
| f386_specbits | ~32 | 8 | 4-entry branch speculation bit manager |
| **Trimmed Subtotal** | **~3,708** | **~4,961** | |

Note: f386_ftq (56 ALUTs) and f386_sys_regs (14 ALUTs) are no longer fully trimmed
in this build — they appear in the measured table above.

### Excluded Subtotal (no TAGE, no trimmed)

| Resource | Estimated |
|----------|-----------|
| ALUTs | ~430 |

### Excluded + Trimmed Subtotal (no TAGE)

| Resource | Estimated |
|----------|-----------|
| ALUTs | ~4,140 |
| Registers | ~4,960 |

---

## Projected Full Design

Measured (32,943 ALUTs) + excluded ISA extensions (~430) + trimmed modules (~3,710).

### Without TAGE

| Resource | Projected | Max | Utilization |
|----------|-----------|-----|-------------|
| ALMs | ~29,900 | 41,910 | ~71.3% |
| Combinational ALUTs | ~37,100 | 83,820 | ~44.3% |
| Dedicated Registers | ~22,300 | 166,036 | ~13.4% |
| M10K Blocks | ~110 | 553 | ~19.9% |
| DSP Blocks | 9 | 112 | 8.0% |

### With TAGE (Phase P2)

| Resource | Projected | Max | Utilization |
|----------|-----------|-----|-------------|
| ALMs | ~32,400 | 41,910 | ~77.3% |

### Headroom

- **ALMs:** ~15,700 remaining (~37.6%) without TAGE
- **M10K:** ~443 remaining (~80%) — cache/TLB already included in measured total
- **DSP:** 103 remaining (~92%) — available for Audio DSP (OPL3) or FPU improvements
- **Registers:** ~148K remaining (~89%)

---

## Notes

- This is the first build with the full memory stack enabled: LSQ + L2 SP + TLB + shim + arbiter.
  Previous builds (≤ 03-07) were core-only at ~11,870 ALMs.
- L2 cache uses 16 M10K blocks for data (4 ways × 4 words × 64-bit), 4 M10K for tags,
  plus small BRAMs for evict buffer and MSHR write-data — totaling ~110 M10K blocks.
- Block memory is dominated by L2 cache (1,122,816 bits) + VGA font ROM (128 bits).
- V-pipe ALU at 1,348 ALUTs (44 more than U-pipe at 1,081 due to V-pipe routing).
- f386_ftq partially alive (56 ALUTs vs ~623 Yosys estimate) — most logic still trimmed.
- f386_sys_regs shows 14 ALUTs — most CR/MSR logic eliminated (no consumer yet).
- 9 modules still optimized to 0 by Quartus due to constant-folded inputs.

---

## Synthesis History

| Date | Commit | ALMs | ALUTs | Regs | M10K | DSPs | Notes |
|------|--------|-----:|------:|-----:|-----:|-----:|-------|
| 2026-03-02 | `a4843cb` | 11,206 | 14,764 | 5,517 | 1 | 9 | Core-only baseline (no LSQ/L2/TLB) |
| 2026-03-06 | `e990b2a` | 11,871 | ~15,400 | 5,633 | 1 | 9 | Quartus 17 async reset fixes |
| 2026-03-08 | `1e7a239` | 25,970 | 32,850 | 17,380 | ~110 | 9 | First full stack (LSQ+L2 SP+TLB) |
| 2026-03-09 | `d903e8f` | 26,164 | 32,943 | 17,380 | ~110 | 9 | P3.1b microcode mem + decoder fix |

## Verification Procedure

After each feature implementation:

```bash
# 1. sv2v smoke test (fast, runs on dev machine)
sv2v -DSYNTHESIS -I rtl/core rtl/top/f386_pkg.sv rtl/top/f386_conf_str.sv \
     rtl/primitives/*.sv rtl/core/*.sv rtl/memory/*.sv rtl/soc/*.sv rtl/top/f386_emu.sv \
     > /dev/null

# 2. Quartus synthesis (preferred: NAS backend)
make quartus QUARTUS_HOST=192.168.50.100

# 3. Update this document with real numbers from the report
```
