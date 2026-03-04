# fabi386 Project Directory Structure (Current)

This document reflects the current repository layout and active integration state.

## Top-Level Layout

```text
/fabi386
├── rtl/
│   ├── core/          # OoO pipeline blocks (decode/rename/IQ/ROB/execute/LSQ)
│   ├── memory/        # D-cache, MSHR, TLB, page walker, MMU remap, mem adapters
│   ├── soc/           # Peripherals and instrumentation (PIC/PIT/PS2/VGA/iobus/AAR)
│   ├── primitives/    # RAM, freelist, picker primitives
│   └── top/           # Package + top-level wrappers (emu, mem_ctrl, pll, conf_str)
├── bench/
│   ├── verilator/     # C++ simulation testbench and tests
│   └── formal/        # SymbiYosys properties and scripts
├── scripts/           # Quartus/Yosys and microcode tooling
├── docs/              # Architecture, planning, and status documents
└── f386.qpf / f386.qsf
```

## Key Source Files

- `rtl/core/f386_ooo_core_top.sv`: OoO core integration.
- `rtl/core/f386_lsq.sv`: LSQ with split-phase memory interface on the module boundary.
- `rtl/memory/f386_mem_sys_to_ddram.sv`: split-phase to MiSTer DDRAM adapter (draft/scaffold).
- `rtl/top/f386_emu.sv`: MiSTer top-level; currently wires core data port through `f386_mem_ctrl`.
- `rtl/top/f386_mem_ctrl.sv`: legacy single-port data + ifetch/page-walker DDRAM arbiter.
- `rtl/top/f386_pkg.sv`: global types, feature gates, and memory request/response structs.

## Integration Note (Important)

The LSQ exists and has the new split-phase contract, but it is **not yet instantiated** in the current `f386_ooo_core_top` data path. The active top-level memory path remains:

`core_top legacy mem_* -> f386_mem_ctrl -> DDRAM_*`

P2 work is tracked in `docs/p2_memory_integration_plan.md`.
