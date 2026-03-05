# P3 Scope

**Created:** 2026-03-05
**Depends on:** P2 closeout (`p2-mem-fabric-stable` tag)

---

## High Priority (blocking boot / correctness)

### 1. Microcode Sequencer Instantiation

Wire `f386_microcode_rom.sv` into `f386_ooo_core_top.sv`:
- U-pipe interlock: stall dispatch while sequencer emits micro-ops.
- Micro-op dispatch loop: each uop enters AGU→LSQ as a normal memory op.
- CDB writeback: final micro-op retires the macro-op in ROB.
- Flush/rollback of partial micro-op sequences.
- Gate: extend `CONF_ENABLE_LSQ_MEMIF` or new `CONF_ENABLE_MICROCODE`.

Without this, PUSHA/POPA/REP/ENTER/LEAVE deadlock the ROB.

### 2. Precise Memory Exception Path

Remove the temporary poison-data (0xDEAD_BEEF) and blind store-drain-ack:
- Wire LSQ/IO path fault metadata (`mem_rsp_t.resp`, faulting address) into ROB exception lane.
- ROB marks instruction as faulting; exception unit handles at retirement.
- Gate: `CONF_ENABLE_PRECISE_MEM_EXC` (ensures temporary path can't coexist).

### 3. Extended MMIO Ranges

Expand `is_mmio_addr()` in `f386_pkg.sv` beyond VGA hole:
- APIC: `0xFEE00000–0xFEE00FFF`
- IOAPIC: `0xFEC00000–0xFEC003FF`
- PCI config: `0xCF8–0xCFF` (IO port, not MMIO — needs IO space handling)
- Ensure all uncacheable regions route to IO path, not LSQ.

---

## Medium Priority (performance)

### 4. Secondary Miss Coalescing

When a new request hits an in-flight MSHR for the same cache line:
- Add per-MSHR pending-requestor slot (or small queue).
- On MSHR completion, fan out responses to all coalesced requestors.
- Eliminates current stall-on-conflict behavior.

### 5. Non-Blocking Ifetch / Page-Table Path

Ifetch and page-table walk currently block on L2 miss:
- Option A: Lightweight request queues per port (1–2 deep).
- Option B: Share data-port MSHRs with port tagging.
- Tradeoff: area vs. front-end stall reduction.

### 6. MSHR Storage Optimization

Evaluate per-entry storage cost vs. count:
- Current: 4 MSHRs, each with full tag + dirty-line buffer.
- Could reduce per-MSHR storage and increase count to 6–8.
- Profile MSHR utilization from P2 baseline counters first.

---

## Lower Priority

### 7. Memory Dependency Predictor

Replace stubbed-to-0 predictor with store-set or bloom filter:
- Track load-store alias history.
- Predict and stall loads that are likely to alias an older store.
- Reduces pipeline flushes from memory-order violations.

### 8. Hardware Watchdog / NMI Path

Replace sim-only `$fatal` watchdog with synthesizable logic:
- Saturating counter triggers NMI on progress timeout.
- Wire NMI into exception unit for graceful recovery.
- Useful for debugging hangs on real hardware.

### 9. Store Buffer Optimization

Post-retirement store drain improvements:
- Coalesce adjacent stores before drain.
- Prioritize store drain during idle cycles.
- Reduces memory bus pressure from scattered writes.
