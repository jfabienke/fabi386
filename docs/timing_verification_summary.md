# fabi386 Timing & Verification Summary (Current)

**Updated:** 2026-03-02  
**Reference commit:** `f919624`

This file tracks the current verification/timing posture of the active codebase.
It replaces older "final"/aspirational claims.

---

## 1. Synthesis Snapshot

Most recent documented Quartus analysis/synthesis snapshot is tracked in
`docs/fpga_resource_budget.md` (Cyclone V / DE10-Nano).

Key reported utilization baseline (from that document):
- ALMs: 11,206 / 41,910
- ALUTs: 14,764 / 83,820
- Registers: 5,517 / 166,036
- DSP: 9 / 112

Important context:
- This snapshot does not imply full end-to-end P2 memory integration closure.
- Some blocks are feature-gated or not on the active execution path.

---

## 2. Verification Status

### Available and active

- Verilator testbench suite under `bench/verilator/`
- Formal properties under `bench/formal/` for ALU/ROB/SegCache/LSQ/TLB
- sv2v full-tree transpile checks used as regression sanity gate

### Not yet signoff-complete

- End-to-end LSQ-in-core memory integration (P2)
- Split-phase shim/fabric deadlock stress coverage
- Full memory-fault retirement/exception delivery integration checks
- Post-fit timing signoff for final integrated configuration

---

## 3. Timing Position

Current status should be treated as:

- **Synthesis-validated for current build configurations**
- **Not a final timing-closure signoff for all planned P2/P3 features**

Any MHz/WNS claim must be tied to:
1. exact commit,
2. exact Quartus flow/settings,
3. exact enabled feature gates,
4. generated report artifact.

---

## 4. Next Required Evidence (P2)

1. Build with `CONF_ENABLE_LSQ_MEMIF` path and collect synthesis/timing reports.
2. Add memory-handshake stress regressions (flush + retry + backpressure).
3. Re-run resource/timing snapshots after shim/FIFO/ID milestones.
4. Publish per-milestone artifacts in `docs/fpga_resource_budget.md` or a dedicated report file.
