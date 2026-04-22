# rtl/sys — MiSTer Framework (Third-Party, GPL)

This directory contains the MiSTer FPGA framework as used by every MiSTer core.
It is **not** fabi386's own code. It provides the hardware abstraction layer
between the DE10-Nano board (HPS-side Linux, HDMI scaler, audio codec, OSD,
SD card, file loading, controller input) and any core that implements the
`emu` module contract.

## License and Attribution

These files are **GPL v2 or later** (some files v3), copyright the individual
authors listed in each file header. Key attributions:

- `sys_top.v`, `hps_io.sv`, `osd.v`, and most framework files:
  (c) 2017-2020 **Alexey Melnikov** (the MiSTer project)
- `hps_io.sv` additionally: (c) 2014 **Till Harbaum**
- `ascal.vhd` (advanced scaler): separate author, GPL-compatible
- Altera/Intel megafunction IP (`pll_*.qip`, `pll_*/` subdirectories): covered
  by Intel's FPGA IP license, freely redistributable for Cyclone V targets

The original upstream is the MiSTer-Console_MiSTer-style framework, copied
here via the AO486 MiSTer port (`reference/ao486_MiSTer/sys/`) which uses
the same framework verbatim.

## Scope and Implications

- This directory is a **self-contained GPL unit**. Distribution of any
  bitstream that includes these files obliges the distributor to make the
  corresponding source available under GPL, per the standard MiSTer
  community practice.
- Modifications to files within this directory must remain under GPL.
- fabi386's own RTL (elsewhere in the tree) is not automatically brought
  under GPL by the presence of this directory — it is a separate work that
  links against this framework via the `emu` module interface.

## Do Not Modify Casually

These files are maintained upstream and are the same across every MiSTer
core. Changes here should be minimal and ideally upstreamed. Normal fabi386
integration work happens in the `emu` module (in `rtl/top/`) and in the
core's own logic (in `rtl/core/`, `rtl/memory/`, `rtl/soc/`).

## Source Snapshot

Imported from `reference/ao486_MiSTer/sys/` on 2026-04-22. If this
directory diverges significantly from upstream MiSTer, document it here.
