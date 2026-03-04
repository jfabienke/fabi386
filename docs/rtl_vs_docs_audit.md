# RTL vs Documentation Audit (Current)

**Updated:** 2026-03-02

This audit tracks documentation accuracy against the present RTL state.

---

## 1. Executive Status

The repo has moved beyond the older "missing decoder / non-compilable top" state.
Current RTL elaborates/transpiles for the active module set, and most major blocks exist.

The largest remaining mismatch is now **integration depth**, not file existence:
- LSQ split-phase contract exists in RTL
- active top-level memory path still uses legacy `mem_ctrl` data handshake

---

## 2. What Is Aligned

| Area | Documentation Status | RTL Reality |
|---|---|---|
| Decoder presence | Present | `rtl/core/f386_decode.sv` exists and is wired in core top |
| OoO top presence | Present | `rtl/core/f386_ooo_core_top.sv` exists and is active in `f386_emu` |
| LSQ module | Present | `rtl/core/f386_lsq.sv` exists and has split-phase ports |
| MiSTer top-level | Present | `rtl/top/f386_emu.sv` is active integration point |
| Memory package contract | Present | `mem_req_t` / `mem_rsp_t` defined in `f386_pkg.sv` |

---

## 3. Current Documentation Drift

### A. Integration claims that are ahead of RTL

1. LSQ fully driving core data path: **not yet true** in default build.
2. Unified split-phase memory fabric: **planned**, not active path.
3. End-to-end memory exception retirement behavior: **partially stubbed/incomplete**.

### B. Legacy docs that are behind RTL

1. Any claim that decoder/top-level files are missing is obsolete.
2. Any claim that project cannot compile due to missing core files is obsolete for current tree.

### C. Performance/timing docs with non-current methodology

1. Old nextpnr/HyperRAM assumptions do not reflect current MiSTer DDRAM + Quartus flow.
2. "Final" benchmark/timing claims are not tied to the current integrated path and should be
   treated as historical/aspirational unless reproduced.

---

## 4. Evidence Pointers

- Active core legacy data stub: `rtl/core/f386_ooo_core_top.sv` (`mem_addr/mem_req/mem_wr` stub block).
- Active top-level memory routing: `rtl/top/f386_emu.sv` (`f386_mem_ctrl` instantiation).
- Split-phase contract definition: `rtl/top/f386_pkg.sv` (`mem_req_t`, `mem_rsp_t`).
- LSQ split-phase boundary: `rtl/core/f386_lsq.sv`.
- Draft adapter scaffold: `rtl/memory/f386_mem_sys_to_ddram.sv`.

---

## 5. Documentation Policy Going Forward

To keep docs synchronized:

1. Avoid "final" labels unless tied to a specific reproducible commit and test report.
2. For every major integration claim, include:
   - active default path,
   - feature-gated path,
   - known gaps.
3. Treat planning docs (`p2_memory_integration_plan.md`) and status docs
   (`implementation_tracker.md`) as the canonical integration truth.
