# P2: Memory Integration Plan

**Created:** 2026-03-02
**Status:** Decisions locked, implementation not started

---

## Locked Decisions

### D1: Shim module — `f386_lsq_to_memctrl_shim.sv`

Standalone module translating LSQ split-phase (`mem_req_t`/`mem_rsp_t`) to mem_ctrl's legacy data port. Lives in `rtl/memory/`.

Shim contract:
- Never assert a mem_ctrl request while mem_ctrl is busy for that client.
- Hold address/data/size stable until mem_ctrl accepts (ack semantics).
- Never consume a response unless it has a request outstanding.
- The shim never generates RETRY. Flow control is backpressure only (`mem_req_ready=0`). RETRY originates only from downstream controllers (e.g., DDRAM) for transient conditions.

Mapping (truth table):
| Split-phase event | mem_ctrl action |
|---|---|
| `req_fire` (load) | Assert mem_ctrl data read request |
| `req_fire` (store) | Assert mem_ctrl data write request |
| mem_ctrl `ack` (read) | Generate `MEM_RESP_OK` with rdata |
| mem_ctrl `ack` (write) | Generate `MEM_RESP_OK` (no data) |
| mem_ctrl busy/not-ready | Backpressure: deassert `mem_req_ready` (no RETRY generated) |

Rip-out path: when LSQ talks directly to DDRAM or a real fabric, delete this module.

### D2: Compile gate — `CONF_ENABLE_LSQ_MEMIF`

- Default: `1'b0` (legacy stub path active).
- Under the gate: instantiate LSQ + shim, connect shim into mem_ctrl's data port.
- Flip default to `1'b1` only after smoke tests pass on a feature branch.
- Separate gate from existing `CONF_ENABLE_DCACHE` — they are orthogonal.

### D3: MMIO/Uncacheable policy — **Option A: bypass LSQ**

MMIO and uncacheable accesses bypass the LSQ entirely in P2.

Rationale:
- Store-to-load forwarding on uncacheable addresses is architecturally wrong.
- Strong ordering (drain + serialize) adds significant LSQ complexity.
- VGA, PIT, PIC, and MMIO registers must not be speculated through.

Implementation:
- AGU classifies addresses: cacheable DRAM → LSQ, uncacheable/MMIO → dedicated IO path.
- Classification source: existing `mem_class_t` from MMU remap gates (CLASS_MMIO, CLASS_ADPT_MEM).
- IO path is in-order, strongly ordered, does not use LSQ forwarding or store buffer.
- IO path speaks `mem_req_t`/`mem_rsp_t` (same contract, different client into mem_ctrl shim or direct).

### D4: Microcode memory ops — route through AGU→LSQ

All architecturally-visible memory ops flow through the LSQ protocol boundary.

- Microcode-generated LD/ST uops are emitted as normal uops into the dispatch path.
- They enter the same AGU → LSQ enqueue flow.
- No separate microcode memory bypass in P2.
- Audit gate: before Step 2 completion, verify that `OP_MICROCODE` memory emissions reach AGU. If the microcode sequencer currently emits direct memory ops that bypass AGU, that path must be rerouted or documented as a known gap.

### D5: RETRY watchdog — progress-based, simulation-only

Definition of "progress":
- Any `MEM_RESP_OK` received, OR
- Any `req_fire` (request accepted by downstream).

Implementation:
- Saturating counter in LSQ `gen_mem_path`, increments each cycle when a request is pending and no progress occurs.
- Resets to 0 on any progress event.
- `$fatal` when counter reaches `CONF_LSQ_WATCHDOG_THRESHOLD` (default 1024).
- Gated behind `ifndef SYNTHESIS` for P2. Real watchdog (NMI plumbing) deferred to P3+.

### D6: FAULT/MISALIGN policy

P2 baseline (current):
- Simulation: `$fatal` stops immediately.
- Synthesis: poison load (`0xDEAD_BEEF` to CDB) and store drain ack to prevent hang.
- **This is temporary P2 behavior.** The poison-data and blind-ack paths must be removed once precise exception-at-retire is wired, to prevent silent data corruption from surviving into later phases.

P2 upgrade (if exception lane is ready):
- Wire LSQ fault metadata (`mem_rsp_in.resp`, faulting address) into ROB exception info.
- ROB marks instruction as faulting; exception unit handles at retirement.
- Remove poison-data and blind store-drain-ack paths. Gate removal behind `CONF_ENABLE_PRECISE_MEM_EXC` so the temporary path can't accidentally coexist with the real one.

### D7: `mem_req_t.addr` is always a byte address

No alignment or masking at the LSQ. Downstream adapter (shim, DDRAM bridge) is responsible for any address transformation.

### D8: Epoch/ID scheme (Step 5 target)

- Start with outstanding table depth 4.
- Each request gets a monotonic ID from a 2-bit counter.
- Response routing checks ID match.
- Epoch tag increments on flush; responses with stale epoch are silently discarded.
- ID/epoch assertions under `ifndef SYNTHESIS`.

---

## Execution Steps

### Step 1: Freeze contracts and gates (Day 1)

- Add `CONF_ENABLE_LSQ_MEMIF` and `CONF_ENABLE_MEM_FABRIC` to `f386_pkg.sv`.
- Policy document = this file (locked).
- Exit: sv2v clean with both gates on/off.

### Step 2: Integration-first wiring (Days 2-4)

- Create `f386_lsq_to_memctrl_shim.sv` (D1 contract).
- Wire LSQ into `f386_ooo_core_top.sv` under `CONF_ENABLE_LSQ_MEMIF`.
- Propagate ports through `f386_emu.sv`.
- Do NOT bypass mem_ctrl — it still arbitrates ifetch/PT/data.
- Audit microcode memory path (D4 gate).
- MMIO bypass plumbing (required by D3):
  - Add `mem_class_t` or `cacheable` bit to AGU→LSQ interface (new AGU output).
  - Source classification from MMU remap gates (`CLASS_MMIO`, `CLASS_ADPT_MEM` → uncacheable).
  - Add routing mux in core_top: cacheable traffic → LSQ, uncacheable → direct IO path.
  - IO path: in-order, strongly ordered, speaks `mem_req_t`/`mem_rsp_t` (separate client).
  - Wire `mem_req_out.cacheable` and `mem_req_out.strong_order` fields from classification.
- Two-client arbitration into mem_ctrl (required by D3 + D1):
  - LSQ (cacheable) and IO path (uncacheable) are two `mem_req_t` clients sharing mem_ctrl's single legacy data port.
  - Add a 2-client round-robin arbiter in front of the shim (or inside the shim as a second input). Arbiter speaks `mem_req_t`/`mem_rsp_t` upstream, single legacy port downstream.
  - IO path gets strict priority over LSQ when both request simultaneously (MMIO must not be starved by burst DRAM traffic). Fallback: round-robin if priority causes measurable LSQ stalls.
- Exit: build passes, boot/smoke runs, no deadlock.

### Step 3: Correctness hardening (Days 5-7)

- Add RETRY watchdog (D5).
- Add epoch/sequence tracking prep for Step 5.
- Wire FAULT/MISALIGN into ROB if exception lane is ready (D6).
- Extend formal: no response consumed after flush for invalidated request context.
- Exit: formal passes + random flush/retry stress test.

### Step 4: Throughput pass A (Days 8-10)

- Add request FIFO (depth 2-4) **inside** the shim module. Keeping the FIFO inside the shim preserves the clean rip-out boundary — deleting the shim later removes the FIFO with it. No external FIFO module.
- Add perf counters: req/rsp, retry, drain, stalled cycles, flush-drain events.
- Keep single-outstanding response semantics.
- Exit: same correctness, reduced memory-stall cycles in microbench.

### Step 5: Concurrency pass B (Days 11-14)

- Introduce IDs + outstanding table (D8, depth 4).
- Add ID/epoch assertions and response routing checks.
- Only after validation: consider store buffer enable (gated).
- Exit: out-of-order response correctness in directed tests.

### Step 6: Front-end + microcode unblock (parallel)

- Decode cache: explicit invalidation for mode changes and SMC.
- Predictor: resolved-branch PC/tag training path.
- Microcode sequencer: ensure `OP_MICROCODE`/`OP_SYS_CALL` cannot wedge pipeline.
- Exit: no known architectural dead-stall opclasses.

---

## Definition of Done (P2)

- sv2v full build clean.
- Formal suite green for LSQ/mem handshake/flush invariants.
- Long random sim with injected retries and flushes: no deadlock.
- Performance counters show measurable front-end and memory progress.
- MMIO traffic confirmed to bypass LSQ (directed test or formal check).
- Microcode memory ops confirmed to flow through AGU→LSQ.
