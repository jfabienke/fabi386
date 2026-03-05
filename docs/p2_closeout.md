# P2 Memory Integration — Closeout

**Date:** 2026-03-05
**Recommended tag:** `p2-mem-fabric-stable`

---

## Gates Passed

| Gate | Status | Notes |
|------|--------|-------|
| sv2v syntax (gate OFF) | PASS | Default config, all modules |
| sv2v syntax (gate ON) | PASS | LSQ_MEMIF + L2_CACHE + MEM_FABRIC enabled |
| Verilator L2_SP | PASS | 10 directed tests, 81+ checks |
| Yosys smoke (f386_mem_ctrl) | PASS | Per-module cell count |
| Regression script | PASS | `scripts/regression_l2_sp.sh` (3 gates) |

---

## Locked Decisions (D1–D8)

| ID | Decision | Summary |
|----|----------|---------|
| D1 | Shim module | `f386_lsq_to_memctrl_shim.sv` — split-phase to legacy adapter, rip-out boundary |
| D2 | Compile gate | `CONF_ENABLE_LSQ_MEMIF` (default 0), orthogonal to DCACHE |
| D3 | MMIO policy | Bypass LSQ entirely; dedicated IO path, in-order, strongly ordered |
| D4 | Microcode mem ops | Route through AGU→LSQ (deferred — sequencer not instantiated) |
| D5 | RETRY watchdog | Progress-based saturating counter, sim-only `$fatal` at 1024 cycles |
| D6 | FAULT/MISALIGN | Poison data (0xDEAD_BEEF) + blind ack — temporary, needs precise exception path |
| D7 | Address convention | `mem_req_t.addr` = byte address always; downstream adapts |
| D8 | Epoch/ID scheme | 2-bit monotonic ID, depth-4 outstanding table, epoch on flush |

---

## Modules Delivered

| Module | File | Description |
|--------|------|-------------|
| LSQ v3.0 | `rtl/core/f386_lsq.sv` | OoO pending table, split-phase, depth-4, forwarding CAM |
| L2_SP | `rtl/memory/f386_l2_cache_sp.sv` | Non-blocking L2, 4 MSHRs, 128KB 4-way, write-back |
| MMIO IO path | `rtl/core/f386_mmio_io_path.sv` | In-order strongly-ordered MMIO loads, TSO on sq_empty |
| Arbiter | `rtl/core/f386_mem_req_arbiter.sv` | Stateless combinational, IO > LSQ priority, ID routing |
| Shim | `rtl/memory/f386_lsq_to_memctrl_shim.sv` | Split-phase→legacy, depth-4 FIFO, 5 perf counters |
| AGU | `rtl/core/f386_agu.sv` | Combinational EA, flat seg_base=0 |
| Verilator TB | `bench/verilator/test_l2_sp.cpp` | 10 directed tests for L2_SP |
| Regression | `scripts/regression_l2_sp.sh` | 3-gate regression (Verilator + sv2v + Yosys) |

---

## Known Gaps

All items below are open. None have been partially fixed and left incomplete.

| Gap | Status | Priority | Notes |
|-----|--------|----------|-------|
| Microcode sequencer | **Deferred** — blocking for boot | High | Not instantiated; OP_MICROCODE deadlocks ROB |
| Secondary miss coalescing | **Deferred** — performance | Medium | Stall on MSHR conflict; no fan-out |
| Poison-data fault workaround | **Deferred** — needs precise exception path | High | Temporary 0xDEAD_BEEF + blind ack in place |
| MMIO range coverage | **Deferred** — needs expansion | High | VGA hole only; APIC/PCI/IOAPIC not covered |
| Memory dependency predictor | **Deferred** — performance | Lower | Stubbed to 0 |
| Segment bases | **Deferred** — correct for flat model | Lower | Flat only (seg_base=0) |
| Load sign-extend | **Deferred** — unsigned loads only | Medium | Not in LSQ CDB path |
| HW smoke test | **Pending** — runbook created | Medium | `docs/de10_mem_fabric_smoke.md` — not yet executed |
