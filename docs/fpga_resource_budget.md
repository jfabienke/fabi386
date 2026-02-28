# fabi386 FPGA Resource Budget — Cyclone V 5CSEBA6U23I7N (DE10-Nano)

**Last updated:** 2026-02-28 (Phase P1.8b)
**Source of truth:** Quartus Prime synthesis reports (`quartus_map` / Analysis & Synthesis)
**Status:** Estimates pending first Quartus run (see `scripts/quartus_synth_check.sh`)

## Device Limits

| Resource | Available | Notes |
|----------|-----------|-------|
| **ALMs** | 41,910 | Adaptive Logic Modules (each = 2 ALUTs + carry + registers) |
| **M10K** | 553 | 10 Kbit memory blocks |
| **MLABs** | ~2,900 | 640-bit distributed RAM (subset of ALMs) |
| **DSP 18x18** | 112 | Variable-precision multipliers |
| **PLLs** | 6 | Fractional PLLs |

## Estimated Resource Budget (Pre-Quartus)

These are estimates based on RTL line counts, structural analysis, and comparison with
ao486_MiSTer/VexRiscv/NaxRiscv synthesis on the same device. Real numbers come from
`quartus_map` — run `scripts/quartus_synth_check.sh` after each feature implementation.

| Domain | ALMs (est.) | M10K | DSP | Notes |
|--------|-------------|------|-----|-------|
| OoO Core (decode, rename, IQ, ROB, specbits, FTQ, execute) | ~11,800 | 4 | 0 | Dual-issue, 16-entry ROB, 8-entry IQ |
| Divider + Multiplier | ~500 | 0 | 4 | DSP-inferred multiplier, non-restoring divider |
| LSQ (8+8, byte-CAM) + MDT | ~1,200 | 0 | 0 | CAM-based forwarding is the ALM-heavy part |
| TLB (32-entry) + Page Walker | ~1,350 | 0 | 0 | Fully-associative CAM |
| D-Cache (16KB, 4-way) + MSHR | ~950 | 5 | 0 | Tag + data in M10K, PLRU logic |
| L2 Cache (128KB, 2-way) | ~300 | 64 | 0 | BRAM-heavy |
| Microcode (sequencer + ROM, 142 mnemonics) | ~850 | 5 | 0 | ROM gen in M10K |
| Exception Unit | ~550 | 0 | 0 | Priority encoder + double-fault FSM |
| Branch Prediction (gshare + RAS + hybrid) | ~250 | 1 | 0 | 256-entry PHT in M10K |
| Neo-386 Pro (shadow stack, safe-trap, logger) | ~350 | 2 | 0 | M10K LIFOs + CAM safe-lists |
| Pentium Extensions (CMOVcc, bitcount, basic MMX) | ~320 | 0 | 0 | Feature-gated (all disabled by default) |
| Peripherals (PIC, PIT, PS2, VGA text, I/O bus) | ~3,200 | 8 | 0 | VGA is the heaviest |
| VBE Accel + IDE/DMA + Debug + Stubs | ~400 | 0 | 0 | |
| MiSTer Integration (emu, PLL, mem_ctrl) | ~650 | 2 | 0 | |
| FPGA Primitives (RAM, picker, freelist) | ~280 | 0 | 0 | Structural wrappers |
| Instrumentation (HARE, 11 modules) | ~1,500 | 4 | 0 | AAR engine, telemetry DMA |
| System Registers + Segment Cache | ~600 | 0 | 0 | |
| **Estimated Total** | **~25,050** | **~95** | **4** | |
| **Remaining Headroom** | **~16,860 (~40%)** | **~458 (~83%)** | **~108 (~96%)** | |

## Key Observations

- **ALMs are the primary constraint** but we have ~40% headroom — plenty for Phase P2
- **M10K usage is modest** at ~17%; future L2 expansion and BTB will consume most growth
- **DSP blocks are nearly untouched**; available for future Audio DSP (OPL3) or FPU improvements
- **Feature gates** (all `CONF_ENABLE_*` at 0) mean the Pentium/P3/Nehalem extensions add 0 ALMs until enabled

## Post-Feature Verification Procedure

After each feature implementation:

```bash
# 1. sv2v smoke test (fast, runs on dev machine)
sv2v rtl/top/f386_pkg.sv rtl/primitives/*.sv rtl/core/*.sv rtl/memory/*.sv

# 2. Quartus synthesis-only (on Quartus machine, ~2-4 min)
./scripts/quartus_synth_check.sh

# 3. Update this table with real numbers from the report
```

## Synthesis History

| Date | Phase | ALMs | M10K | DSP | Fmax (est.) | Notes |
|------|-------|------|------|-----|-------------|-------|
| — | — | — | — | — | — | Awaiting first Quartus run |
