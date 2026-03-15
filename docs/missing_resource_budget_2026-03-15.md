# fabi386 Missing Resource Budget Estimate

**Date:** 2026-03-15  
**Scope:** Remaining RTL and subsystem work that is still missing or not end-to-end integrated  
**Baseline:** Latest Quartus synthesis result reported on 2026-03-15

## Baseline

Current measured build:

| Resource | Used | Device | Utilization |
|----------|-----:|-------:|------------:|
| ALMs | 27,236 | 41,910 | 65.0% |
| Combinational ALUTs | 34,603 | 83,820 | 41.3% |
| Registers | 17,515 | 166,036 | 10.6% |
| Block RAM bits | 1,122,944 | 5,662,720 | 19.8% |
| DSPs | 9 | 112 | 8.0% |

This note uses the 2026-03-15 Quartus result as the anchor, not the older
03-09 snapshot in [fpga_resource_budget.md](./fpga_resource_budget.md).

## What Counts As "Missing"

Included:

- RTL that is still absent
- RTL that exists but is not yet wired end-to-end
- major SoC subsystems that are still stubbed

Excluded:

- test work
- default-on promotion
- timing-closure effort
- already-implemented gated features unless their integration is still missing

## Estimation Basis

These numbers are anchored by four sources:

1. Live RTL stubs and TODOs in the current tree:
   - [rtl/core/f386_ooo_core_top.sv](../rtl/core/f386_ooo_core_top.sv)
   - [rtl/top/f386_emu.sv](../rtl/top/f386_emu.sv)
   - [rtl/core/f386_decode.sv](../rtl/core/f386_decode.sv)
2. Existing measured/estimated module budgets in [fpga_resource_budget.md](./fpga_resource_budget.md)
3. Built-in estimates in [scripts/yosys_resource_check.sh](../scripts/yosys_resource_check.sh)
4. ETX/HARE planning estimates in:
   - [semantic_detection_analysis.md](./semantic_detection_analysis.md)
   - [etx_display_engine_architecture.md](./etx_display_engine_architecture.md)

Confidence levels:

- `High`: repo already contains a concrete per-module estimate
- `Medium`: estimate derived from similar existing modules plus integration glue
- `Low`: estimate depends on design-doc sizing rather than synthesized RTL

## Itemized Missing-Scope Budget

| Missing scope | ALMs | M10K | DSP | Confidence | Basis |
|---------------|-----:|-----:|----:|------------|-------|
| Fetch paging completion: ITLB + retire-time INVLPG + PSE | 700-1,400 | 0 | 0 | Medium | DTLB/TLB already exist; PSE still gated off in `f386_pkg.sv`; INVLPG still tied off in `f386_ooo_core_top.sv` |
| Segmentation completion: AGU `seg_base`, limit enforcement, PM descriptor/gate validation | 250-850 | 0 | 0 | Medium | `f386_seg_cache` estimates at ~238 ALMs; missing work is mainly datapath wiring and validation logic |
| Load semantics + deferred system/microcode ops: signed loads, `STORE_DTR`, `STORE_SEG`, `LAHF`, `SAHF`, `HALT`, `MOV DR` | 150-350 | 0 | 0 | Medium | Small control additions; sign propagation is currently hardwired off |
| Platform completion: port `0x92`, PIC acknowledge, minimal APIC/IOAPIC stubs, full RTC, full DMA | 700-1,250 | 0-1 | 0 | Low-Medium | `f386_pic` ~274 ALMs, `f386_pit` ~355 ALMs, stubs still present in `f386_emu.sv` |
| L1D integration | 1,050-1,200 | 5 | 0 | High | Yosys script pegs `dcache` at ~950 ALMs + 5 M10K; range includes core-top integration glue |
| HARE/AAR end-to-end suite | 5,200-6,000 | ~6 | 0 | Low | `semantic_detection_analysis.md` gives 10,450 LUTs and 60 Kb BRAM for the full RE suite |
| ETX v1 text + graphics/blit path | +383 | +13 | +1 | **High** | Quartus-measured delta (2026-03-15): 648 ALUTs, 979 regs, 133K BRAM bits net; replaces VGA. Stubs with live FSMs/BRAM/cmd path. Partial pruning: cursor overlay, some BRAM widths. Production ETX with active cursors/UTF-8 will be higher. |
| ETX UTF-8 / diagnostics option | +350-1,150 | +0-2 | 0 | Low | `etx_display_engine_architecture.md` section 19.9; not included in measured stub |

## Notes By Item

### 1. Fetch Paging Completion

Remaining gaps:

- fetch-side translation is still absent
- `INVLPG` is still tied off in `f386_ooo_core_top.sv`
- `CONF_ENABLE_PSE` remains `0`

This is mostly control logic and another TLB-side integration pass, not a major
BRAM consumer.

### 2. Segmentation Completion

Remaining gaps:

- extracted segment bases/limits are still unused in core top
- AGU still operates flat
- segment-limit checking is not enforced
- PM gate/type/present validation is still incomplete

The floor is basically the existing `f386_seg_cache` estimate. The upside comes
from adding validation comparators and exception plumbing.

### 3. Load Semantics + Deferred System Ops

This is the cheapest remaining CPU-correctness bucket.

Remaining gaps:

- signed memory/MMIO load propagation
- `UCMD_STORE_DTR`
- `UCMD_STORE_SEG`
- `UCMD_LAHF`
- `UCMD_SAHF`
- `UCMD_HALT`
- `MOV DR`

This should not move BRAM or DSP usage.

### 4. Platform Completion

Remaining gaps:

- fast A20 gate via port `0x92`
- PIC interrupt acknowledge wiring
- APIC/IOAPIC minimal functional stubs
- RTC still stubbed
- DMA still stubbed

This is mostly peripheral control logic. The range is wide because a "full DMA"
implementation can vary substantially depending on compatibility target.

### 5. L1D Integration

This is the cleanest large remaining CPU block because the repo already carries
an explicit estimate:

- `dcache: ~950 ALMs + 5 M10K`

I budgeted a small extra margin for LSQ/core-top integration and bypass logic.

### 6. HARE / AAR

This is the biggest non-ETX remaining logic bucket.

The most useful anchor is the existing RE-suite estimate:

- `10,450 LUTs`
- `60 Kb BRAM`

On Cyclone V, that translates to roughly:

- `~5.2k-6.0k ALMs`
- `~6 M10K`

This is more credible than taking the standalone `f386_aar_engine` Yosys result
literally, because the Yosys aggregate includes overlapping logic and tends to
overcount versus Quartus.

### 7. ETX

**Measured 2026-03-15** via Quartus 17.0.2 on NAS (Cyclone V 5CSEBA6U23I7).

ETX resource-estimation stubs in `rtl/soc/f386_etx_*.sv` (10 modules) were synthesized
with `CONF_ENABLE_ETX=1`, replacing the legacy VGA module.

**Measured net delta:** +383 ALMs, +13 M10K, +1 DSP.

Per-module Quartus breakdown:

| Module | ALUTs | Regs | BRAM bits |
|--------|------:|-----:|----------:|
| etx_engine local (timing, stubs, staging, regs, blit, cmd, tile) | 121 | 457 | 0 |
| etx_glyph_cache (tag + data BRAM) | 386 | 264 | 34,816 |
| etx_line_buffer (2 × 1920 × 24-bit) | 27 | 1 | 98,304 |
| etx_mem_hub (dual-ch arbiter + FIFOs) | 49 | 68 | 432 |
| etx_scanout_pipe (12-stage, shift-reg inferred) | 65 | 188 | 42 |
| etx_cursor_overlay (pruned: zero-default descriptors) | 0 | 1 | 0 |
| **ETX total** | **648** | **979** | **133,594** |

Observations:
- Quartus inferred `altshift_taps` for the 12-stage pipeline (BRAM shift registers)
- Glyph cache: 32K of 131K declared data bits mapped (partial-width optimization)
- Cursor overlay: pruned to 1 reg (zero-size default descriptors → hit always false)
- DSP +1: address multiplier in scanout prefetch generator
- This is a **floor**, not a ceiling: production ETX with active cursors, full-width
  glyph cache, and UTF-8 decode will be higher

The UTF-8 sub-block is estimated separately (not included in measured stub):

- lightweight: `~350-700 ALMs`
- full diagnostics: `~700-1,150 ALMs`
- `0-2 M10K`

## Scenario Totals

### CPU / Platform Completion Only

Includes:

- fetch paging completion
- segmentation completion
- deferred load/system ops
- platform completion
- L1D integration

| Resource | Projected |
|----------|----------:|
| ALMs | 30,086-32,286 |
| ALM utilization | 71.8%-77.0% |
| M10K | ~115-116 |
| DSP | 9 |

### CPU / Platform + Full HARE / AAR

| Resource | Projected |
|----------|----------:|
| ALMs | 35,286-38,286 |
| ALM utilization | 84.2%-91.4% |
| M10K | ~121-122 |
| DSP | 9 |

### CPU / Platform + HARE / AAR + ETX Text/Graphics Path (measured)

| Resource | Projected |
|----------|----------:|
| ALMs | 35,669-38,669 |
| ALM utilization | 85.1%-92.3% |
| M10K | ~134-135 |
| DSP | 10 |

### CPU / Platform + HARE / AAR + ETX + UTF-8 Diagnostics

| Resource | Projected |
|----------|----------:|
| ALMs | 36,019-39,819 |
| ALM utilization | 86.0%-95.0% |
| M10K | ~134-137 |
| DSP | 10 |

## Planning Takeaways

1. Remaining CPU/platform correctness work still fits comfortably.
2. Full HARE/AAR also looks feasible on Cyclone V.
3. ETX is the main swing factor for ALM headroom.
4. M10K is not the limiting resource in any of these scenarios.
5. The likely hard limit for "CPU + HARE + ETX" is ALMs and timing, not BRAM or DSPs.

## Recommended Planning Reserve

If you want one practical reserve number for project planning:

- everything missing except ETX: `+8k ALMs`, `+11 M10K`, `+0 DSP`
- everything missing including measured ETX: `+8.4k to +12.6k ALMs`, `+24 to +27 M10K`, `+1 DSP`

Note: the ETX ALM budget dropped from the previous `+11k-13k` estimate to `+8.4k-12.6k`
because the measured ETX delta (+383 ALMs) is well below the prior paper estimate
(2,000-4,000 ALMs). The measured number is a floor — production ETX will be higher
once cursor/UTF-8/full-width glyph cache are exercised.

## Follow-Up

If this estimate is going to drive design decisions, the next useful step is to
replace the low-confidence ETX/HARE buckets with measured Quartus deltas from
incremental feature branches rather than relying on planning heuristics.
