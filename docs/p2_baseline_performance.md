# P2 Baseline Performance Template

**Created:** 2026-03-05
**Commit:** _TBD_

---

## Counter Accessibility

**Shim counters** (`f386_lsq_to_memctrl_shim.sv`): Exposed as `output` ports —
directly readable from any testbench instantiating the shim or the top-level.

**L2_SP counters** (`f386_l2_cache_sp.sv`): **Internal `logic` registers** — not
currently exported as module ports. To collect these values:
- **(a)** Add `output` ports to L2_SP in a future commit (preferred for HW), or
- **(b)** Use `$display` / VPI / DPI-C in simulation to sample them each cycle.

Rows marked *"requires port export"* below cannot be filled until option (a) or (b)
is implemented.

---

## Counter Inventory

### Shim Counters (5 output ports)

| Counter | Signal | Width | Description |
|---------|--------|-------|-------------|
| Request total | `ctr_req_total` | 32-bit sat. | Requests issued to mem_ctrl |
| Response total | `ctr_rsp_total` | 32-bit sat. | Responses delivered upstream |
| Stall cycles | `ctr_stall_cycles` | 32-bit sat. | Cycles `req_valid && !req_ready` |
| Drain events | `ctr_drain_events` | 32-bit sat. | Flush-during-wait events |
| FIFO full cycles | `ctr_fifo_full_cyc` | 32-bit sat. | Cycles FIFO at capacity |

### L2_SP Counters (5 internal regs — requires port export)

| Counter | Signal | Width | Description |
|---------|--------|-------|-------------|
| MSHR allocations | `ctr_mshr_alloc` | 32-bit sat. | Miss-initiated MSHR allocations |
| MSHR stall cycles | `ctr_mshr_stall_cyc` | 32-bit sat. | Cycles stalled on full MSHRs |
| Hit-during-miss | `ctr_hit_during_miss` | 32-bit sat. | Hits serviced while MSHR active |
| DDRAM WB bursts | `ctr_ddram_wb_bursts` | 32-bit sat. | Dirty eviction writeback bursts |
| DDRAM fill bursts | `ctr_ddram_fill_bursts` | 32-bit sat. | Cache line fill bursts from DDRAM |

---

## Latency Targets

| Operation | Design Target (cycles) | Measured | Notes |
|-----------|----------------------|----------|-------|
| Data load (hit) | 4 | _TBD_ | TAG_RD→TAG_CMP→HIT_RD→RESPOND |
| Data store (hit) | 3 | _TBD_ | TAG_RD→TAG_CMP→HIT_WR |
| Ifetch (hit) | 5 | _TBD_ | +1 for cross-line check |
| Page table walk (hit) | 4 | _TBD_ | Same as data load path |
| Miss (clean) | ~20 | _TBD_ | +FILL_BURST (4 beats) |
| Miss (dirty evict) | ~30 | _TBD_ | +EVICT_RD + WB_BURST + FILL_BURST |

---

## Per-Test Counter Snapshots

One row per Verilator L2_SP test. Shim columns fillable now; L2_SP columns
pending port export.

| Test | req_total | rsp_total | stall_cyc | drain_evt | fifo_full | mshr_alloc | mshr_stall | hit_miss | wb_burst | fill_burst |
|------|-----------|-----------|-----------|-----------|-----------|------------|------------|----------|----------|------------|
| Basic hit | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_* | _TBD_* | _TBD_* | _TBD_* | _TBD_* |
| Read miss + fill | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_* | _TBD_* | _TBD_* | _TBD_* | _TBD_* |
| Write-allocate merge | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_* | _TBD_* | _TBD_* | _TBD_* | _TBD_* |
| Dirty eviction | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_* | _TBD_* | _TBD_* | _TBD_* | _TBD_* |
| OoO delivery | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_* | _TBD_* | _TBD_* | _TBD_* | _TBD_* |
| Multi-miss drain | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_* | _TBD_* | _TBD_* | _TBD_* | _TBD_* |
| MMIO under load | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_* | _TBD_* | _TBD_* | _TBD_* | _TBD_* |
| MSHR exhaustion | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_* | _TBD_* | _TBD_* | _TBD_* | _TBD_* |
| Secondary miss stall | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_* | _TBD_* | _TBD_* | _TBD_* | _TBD_* |
| Sub-dword sizes | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_ | _TBD_* | _TBD_* | _TBD_* | _TBD_* | _TBD_* |

\* Requires L2_SP counter port export.

---

## Derived Metrics

| Metric | Formula | Value |
|--------|---------|-------|
| Store drain throughput | `drain_events / total_cycles` | _TBD_ |
| MSHR utilization % | `mshr_stall_cyc / total_cycles * 100` | _TBD_ |
| Hit-under-miss rate | `hit_during_miss / (req_total - mshr_alloc)` | _TBD_ |
| FIFO backpressure rate | `fifo_full_cyc / total_cycles * 100` | _TBD_ |
| Effective bandwidth | `rsp_total * line_size / total_cycles` | _TBD_ |

---

## Legacy Comparison

Direct comparison with `f386_mem_ctrl` (blocking, single-outstanding) is not
measurable yet — the shim counters did not exist in the legacy path. Defer
side-by-side benchmarking to P3 when both paths can run the same workload with
instrumentation.
