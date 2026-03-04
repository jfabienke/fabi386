# fabi386 Implementation Tracker (Current)

**Updated:** 2026-03-02  
**Reference commit:** `f919624`

This tracker is intentionally concise and focuses on the current implementation state,
not aspirational architecture scope.

---

## 1. Integration Snapshot

### Current active memory path

`f386_ooo_core_top (legacy mem_* stubs) -> f386_mem_ctrl -> DDRAM_*`

### Present but not fully integrated yet

- `f386_lsq.sv` (LSQ with split-phase `mem_req_t` / `mem_rsp_t` interface)
- `f386_mem_sys_to_ddram.sv` (split-phase adapter scaffold)
- `CONF_ENABLE_LSQ_MEMIF` / `CONF_ENABLE_MEM_FABRIC` gates in `f386_pkg.sv`

### Meaning

Memory subsystem pieces exist, but end-to-end LSQ-driven memory integration is still
P2 work and is not the default execution path yet.

---

## 2. Module Status Matrix

| Domain | Module(s) | Status | Notes |
|---|---|---|---|
| Decode/front-end | `f386_decode`, branch predictor blocks, `f386_fetch_fifo` | Implemented | Decode cache block exists; feature-gated off by default |
| Rename/dispatch/issue | `f386_register_rename`, `f386_dispatch`, `f386_issue_queue` | Implemented | Recent fixes include dest-valid and br-tag propagation plumbing |
| Execute | `f386_execute_stage`, ALU/SIMD/FPU/div/mul | Implemented (partial semantics) | `OP_MICROCODE/OP_SYS_CALL` completion integration still pending |
| ROB/retire | `f386_rob` | Implemented | Exception plumbing and LSU fault handoff not fully closed |
| LSQ | `f386_lsq` | Implemented at module level | Not yet instantiated in active core-top memory path |
| Memory adapters | `f386_mem_ctrl`, `f386_mem_sys_to_ddram` | Implemented (different contracts) | `mem_ctrl` is active; split-phase adapter is draft scaffold |
| Caches/TLB | `f386_dcache`, `f386_dcache_mshr`, `f386_tlb`, `f386_page_walker` | Implemented (feature/use varies) | Integration depth varies by path and feature gate |
| SoC peripherals | `f386_pic`, `f386_pit`, `f386_ps2`, `f386_vga`, `f386_iobus` | Implemented | Active usage depends on top-level wiring/config |
| Top-level/MiSTer | `f386_emu`, `f386_pll`, `f386_conf_str` | Implemented | DDRAM path currently routed through `f386_mem_ctrl` |
| Verification | `bench/verilator`, `bench/formal` suites | Implemented | Coverage exists for ALU/ROB/LSQ/TLB/seg_cache; expand for P2 memory flow |

---

## 3. Recently Completed Work (Already Landed)

- Rename-map bypass correctness fixes
- `dest_valid` gating fixes in OoO pipeline paths
- `br_tag` propagation for branch resolve/squash consistency
- LSQ split-phase interface migration at module boundary
- LSQ hardening updates:
  - forwarded-load offset extraction for sub-dword cases
  - flush-drain backend state handling
  - store-shape assertion hardening
  - synthesis-safe handling for non-OK response cases

---

## 4. Open Integration Gaps

### High priority

1. Instantiate LSQ into `f386_ooo_core_top` and replace current data-memory stubs.
2. Bridge LSQ split-phase protocol to existing `f386_mem_ctrl` legacy data interface (P2 shim).
3. Decide and wire MMIO/uncacheable routing policy (LSQ bypass for strong-ordered IO path).
4. Close microcode execute-to-completion integration for ops that currently stall U-pipe.

### Correctness risks to track

- Flush + pending response stale-consumption hazards once multiple outstanding requests are enabled.
- Exception/fault handoff path for memory responses (`FAULT`/`MISALIGN`) into ROB retirement semantics.
- Contract drift between byte-addressed request semantics and downstream adapter alignment behavior.

---

## 5. P2 Execution Status

Tracked in `docs/p2_memory_integration_plan.md`.

- Decision set D1-D8: **locked**
- Step 1 (gates/contracts): **partially complete** (gates present in package)
- Step 2+ (integration, shim, MMIO bypass plumbing): **not started on active path**

---

## 6. Verification Baseline

Minimum baseline before each merge affecting memory path:

```bash
# LSQ syntax/transpile sanity
sv2v rtl/top/f386_pkg.sv rtl/core/f386_lsq.sv > /tmp/lsq.v

# Full design transpile sanity
sv2v rtl/top/f386_pkg.sv rtl/primitives/*.sv rtl/core/*.sv rtl/memory/*.sv > /tmp/full.v

# Formal targets
make -C bench/formal alu rob seg lsq tlb
```

Add dedicated P2 checks as each step lands (shim protocol, flush/retry stress, MMIO bypass, epoch/ID checks).
