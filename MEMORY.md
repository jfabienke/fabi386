# fabi386 Memory Subsystem (Current State)

**Updated:** 2026-03-02  
**Reference commit:** `f919624`

## 1. Active Data Path Today

Current default integration uses a legacy req/ack data port:

`f386_ooo_core_top (mem_*) -> f386_mem_ctrl -> MiSTer DDRAM_*`

`f386_mem_ctrl` currently arbitrates three clients:
- instruction fetch,
- data port,
- page-walker port.

## 2. Split-Phase Contract (Implemented at Module Boundaries)

`mem_req_t` / `mem_rsp_t` are defined in `rtl/top/f386_pkg.sv`.

Key contract points:
- `addr` is always byte-addressed.
- store `byte_en`/`wdata` are lane-aligned by producer relative to `addr[31:3]`.
- responses carry status (`OK/RETRY/FAULT/MISALIGN`) and request ID.

Modules already using this contract:
- `rtl/core/f386_lsq.sv` (LSQ boundary)
- `rtl/memory/f386_mem_sys_to_ddram.sv` (draft adapter scaffold)

## 3. Current Integration Gap

The LSQ split-phase interface is not yet the active end-to-end path in top-level wiring.
Top-level memory still runs through legacy `f386_mem_ctrl` data handshake.

## 4. Locked P2 Decisions

See `docs/p2_memory_integration_plan.md` for full detail. Core locked points:

1. Add `f386_lsq_to_memctrl_shim.sv` for split-phase -> legacy translation.
2. Gate rollout with `CONF_ENABLE_LSQ_MEMIF` (default `0`).
3. MMIO/uncacheable accesses bypass LSQ (strong-ordered IO path).
4. Microcode memory ops route through AGU->LSQ.
5. Progress-based RETRY watchdog in simulation.
6. `FAULT/MISALIGN` temporary unblock behavior in synthesis, fatal in sim until precise exception path is wired.
7. Keep byte-address contract intact.
8. Add epoch+ID response handling when enabling multiple outstanding requests.

## 5. Known Risks

- Fault handling is temporarily safety-unblocking, not final precise retirement semantics.
- Flush + stale responses must be revalidated when moving beyond single outstanding request.
- MMIO bypass plumbing is required before LSQ can be considered architecturally complete.
