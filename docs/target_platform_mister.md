# fabi386: Target Platform - MiSTer FPGA

## Hardware

- **Board:** Terasic DE10-Nano
- **FPGA:** Intel/Altera Cyclone V 5CSEBA6U23I7
- **SDRAM:** 32MB primary + 128MB expansion module (160MB total)
- **HPS:** Dual-core ARM Cortex-A9 (Linux host for OSD/menu/SD access)
- **Toolchain:** Intel Quartus Prime

## Resource Fit

| Resource            | Cyclone V Available | fabi386 Requirement | Headroom |
|---------------------|---------------------|---------------------|----------|
| ALMs (~2x LUT4)     | ~41K (~82K LUT-eq) | ~63K LUTs           | ~19K     |
| M10K BRAM blocks    | 553 (5.5 Mbit)     | 170 (18Kb-eq)       | ~383     |
| DSP 18x18           | 112                 | 60                  | 52       |

## Memory Map Adaptation

The original design uses 256MB HyperRAM. On MiSTer with 128MB expansion:

| Function                | Original (HyperRAM) | MiSTer (SDRAM)              |
|-------------------------|----------------------|-----------------------------|
| Main system memory      | 256MB HyperRAM       | 32MB primary SDRAM          |
| Trace buffer / RE data  | Shared in HyperRAM   | 128MB expansion SDRAM       |
| L2 cache backing        | HyperRAM             | FPGA BRAM (on-chip)         |

The 128MB expansion module can be dedicated to the Ultra-RE trace buffer,
giving ~10M+ instruction traces for time-travel debugging. The 32MB primary
SDRAM serves as main system memory (more than enough for DOS/Win9x workloads).

## Adaptation Points

### Must Change
- `f386_hyperbus_ctrl.sv` → Replace with MiSTer SDRAM controller interface
- Pin constraints → MiSTer DE10-Nano `.qsf` pinout
- Build scripts → Quartus synthesis flow

### Can Leverage from MiSTer Framework
- **Video output:** MiSTer's `video_mixer` and HDMI/VGA scan-doubler
- **SD card access:** HPS-side SD card via ARM Linux (for IDE DMA)
- **OSD/Menu:** MiSTer's standard OSD for configuration
- **UART debug:** MiSTer has accessible UART pins for the fabi386 console
- **Accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent accent USB input:** HPS-managed keyboard/mouse passthrough

### RTL Portable As-Is
- All `core/` modules (pipeline, ALU, FPU, branch prediction, OoO engine)
- All `soc/` modules (debug unit, guard unit, PASC, V86 monitor, BitBlt)
- Package and type definitions (`f386_pkg.sv`)
- Microcode ROM, dispatch, register rename, ROB, issue queue
