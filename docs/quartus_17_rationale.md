# Why Quartus Prime Lite 17.0.2

This document explains why fabi386 (and the MiSTer ecosystem generally) targets
Quartus 17.x rather than newer releases.

## 1. Cyclone V Generation Alignment

Cyclone V belongs to Intel/Altera's mid-2010s FPGA generation. Quartus 17.x
represents the final mature toolchain before Intel restructured the compiler
for Stratix 10 / Agilex. Device models, synthesis heuristics, and routing
strategies are stable and well-tuned for Cyclone V at this version.

| Quartus version | Target generation |
|-----------------|-------------------|
| 13-16 | Cyclone IV / V era |
| 17.x | Mature Cyclone V support |
| 18-19 | Stratix 10 / Agilex flow changes begin |
| Pro | New architecture and compiler |

## 2. Better Fitter Results for Cyclone V

The Fitter (place-and-route) is the most sensitive component. Small heuristic
changes produce measurably different results in timing closure, ALM packing,
routing congestion, and clock tree quality.

MiSTer developers consistently observed:

- **Quartus 17.x**: better timing, fewer routing failures, tighter ALM packing
- **Later versions**: higher resource usage, lower Fmax, longer compile times
  for the same HDL

## 3. Lighter Toolchain

Starting around Quartus 18/19, Intel introduced:

- New incremental compilation model
- Large Pro Edition infrastructure
- Synthesis pipeline changes
- New device abstraction layers

These made the toolchain slower, more memory-intensive, and less predictable
for Cyclone V projects. Build times increased significantly across versions:

| Version | Compile speed |
|---------|--------------|
| 17.x | Fast |
| 19.x | Noticeably slower |
| 21+ | Much slower |

For cores compiled frequently by hobbyists, this matters.

## 4. Deterministic Builds

MiSTer relies on reproducible FPGA builds. Small compilation differences can
cause timing violations, subtle logic differences, or different resource
layouts. Standardizing on a known-good toolchain avoids "works on my Quartus
but fails on yours" problems.

Quartus 17.0.2 is the de-facto canonical reference compiler for the ecosystem.

## 5. Legacy IP Compatibility

Many MiSTer cores use IP blocks generated in the Quartus 16-17 era:

- PLL configurations
- SDRAM controllers
- VGA timing generators
- Clock domain bridges

Later releases sometimes changed IP formats, deprecated legacy modules, or
altered parameter schemas, breaking old projects or requiring regeneration.

## 6. Community Momentum

Build scripts, Makefiles, CI pipelines, documentation, and bug reports across
dozens of MiSTer cores all assume Quartus 17.x. Switching versions would
impose a massive testing burden with no benefit for the fixed Cyclone V target.

## 7. Linux and Docker Compatibility

Quartus 17 works well in headless Linux environments and Docker build systems.
Later versions increasingly assume GUI workflows, heavier runtimes, and more
proprietary dependencies. For automated builds, 17.x integrates more easily.

## 8. Cyclone V Timing Sweet Spot

Cyclone V designs typically target 25-150 MHz clocks. Quartus 17's timing
models and routing heuristics are tuned for those ranges. Later toolchains
prioritize >300 MHz designs for newer architectures, which subtly harms
optimization at Cyclone V frequencies.

## 9. Stability Over Features

For MiSTer, the priorities are:

1. Stable timing
2. Predictable routing
3. Fast compile cycles
4. Compatibility with existing cores

Not newest features, latest device support, or modern toolchain architecture.
Quartus 17 meets those priorities best.

## 10. Long-Term Outlook

Because MiSTer targets a fixed FPGA platform (Cyclone V on DE10-Nano), there
is little incentive to upgrade unless:

- A new FPGA board replaces DE10-Nano
- The compiler becomes unavailable
- A major bug forces migration

Quartus 17 will likely remain the preferred toolchain indefinitely.

## Relevance to fabi386

For fabi386 + ETX + HARE on Cyclone V, Quartus 17 provides:

- Mature routing for large logic fabrics
- Predictable ALM packing for OoO CPU structures
- Stable timing closure around 100-150 MHz
- Compatibility with MiSTer's SDRAM and video infrastructure

Given the complexity of the architecture, toolchain stability is extremely
valuable. The compiler should be boring and predictable, not a moving target.
