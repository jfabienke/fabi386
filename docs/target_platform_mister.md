# fabi386 Target Platform: MiSTer / DE10-Nano (Current)

## 1. Hardware Baseline

### FPGA / SoC

- Board: Terasic DE10-Nano
- FPGA: Cyclone V SE 5CSEBA6U23I7
- Capacity: 41,910 ALMs, 166,036 regs, 553 M10K, 112 DSP
- HPS: dual-core Cortex-A9 + 1GB DDR3 (HPS-attached)

### MiSTer-relevant memory model

- DDR3 is physically attached to HPS.
- FPGA fabric reaches it through MiSTer `DDRAM_*` bridge interface.
- Access latency is higher and less deterministic than FPGA-direct SDRAM modules.

---

## 2. Current RTL Integration on MiSTer

Active top-level path in this repo:

`f386_ooo_core_top -> legacy mem_* data interface -> f386_mem_ctrl -> DDRAM_*`

Notes:
- `f386_emu.sv` is the active MiSTer top-level.
- `f386_mem_ctrl.sv` currently arbitrates ifetch, data, and page-walker requests.
- LSQ split-phase integration is in progress (P2), not yet the default active path.

---

## 3. Current Limitations (Known)

1. Data path still uses legacy req/ack semantics through `f386_mem_ctrl`.
2. `f386_mem_ctrl` currently uses older addressing/data assumptions and is a bring-up bridge,
   not a final non-blocking memory fabric.
3. LSQ split-phase contract exists (`mem_req_t`/`mem_rsp_t`) but is not yet end-to-end wired.

---

## 4. P2 Direction

P2 work introduces:

- `f386_lsq_to_memctrl_shim.sv` (planned): split-phase <-> legacy mem_ctrl bridge
- `CONF_ENABLE_LSQ_MEMIF` gate for incremental integration
- MMIO/uncacheable bypass policy (strongly ordered IO path)
- Later migration to direct memory fabric (`CONF_ENABLE_MEM_FABRIC`)

See `docs/p2_memory_integration_plan.md` for locked decisions and staged execution.

---

## 5. Practical Guidance

For timing-sensitive retro-style memory semantics, continue treating HPS DDRAM as a
high-latency backend. Keep CPU-side memory behavior correct via LSQ/cache/fabric logic,
rather than assuming deterministic backend timing from the bridge.
