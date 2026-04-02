# fabi386

An out-of-order superscalar x86 CPU implemented in SystemVerilog, targeting the Intel Cyclone V FPGA on the DE10-Nano (MiSTer platform). The design is a ground-up microarchitecture — not a translation or wrapper around an existing core — built around a 486DX ISA base with gated extensions through Pentium, P6, and Nehalem instruction families.

The goal is a hardware platform for x86 workload analysis and reverse engineering, capable of booting DOS in real and protected mode, with integrated display output, peripheral I/O, and a hardware-assisted security analysis subsystem.


## Architecture

fabi386 is a dual-issue superscalar core with register renaming, reorder buffer retirement, and a common data bus writeback model. The pipeline supports speculative execution with branch misprediction recovery, and the memory subsystem provides a non-blocking L2 cache with miss-status holding registers.

```
                                 fabi386 SoC
 ============================================================================

                          +------------------+
                          |   Fetch (16B)    |
                          |  Branch Predict  |
                          | Gshare + Hybrid  |
                          +--------+---------+
                                   |
                          +--------v---------+
                          |  Decode / Cache   |
                          |  U-pipe   V-pipe  |
                          +--------+---------+
                                   |
                     +-------------v--------------+
                     |     Rename + Dispatch       |
                     |  32-entry PRF, Free List    |
                     +-------------+--------------+
                                   |
                  +----------------v-----------------+
                  |          Issue Queue (8)          |
                  +--+-----+-----+-----+-----+---+--+
                     |     |     |     |     |   |
                  +--v--+--v--+--v--+--v--+--v-+ |
                  | ALU | ALU |SIMD | FPU |DIV | |
                  | (U) | (V) |     |     |MUL | |
                  +--+--+--+--+--+--+--+--+--+-+ |
                     |     |     |     |     |   |
                     +-----+-----+-----+-----+  |
                                   |             |
                  +----------------v----------+  |
                  |     Common Data Bus       |  |
                  |      (CDB0 + CDB1)       |  |
                  +----------------+----------+  |
                                   |             |
                  +----------------v----------+  |   +-------------------+
                  |   Reorder Buffer (16)     |  |   |    Microcode      |
                  |   In-order Commit (x2)    |  +-->|    Sequencer      |
                  +-------+----------+--------+      | 256-entry ROM     |
                          |          |               +-------------------+
              +-----------v--+  +----v-----------+
              | Arch. State  |  |   Seg Cache    |
              |  EAX..EDI    |  |  CS/DS/SS/..   |
              |  EIP, FLAGS  |  |  GDT access    |
              +--------------+  +----------------+

 --- Memory ------------------------------------------------------------------

    +--------+    +-----------+    +---------------+    +-----------+
    |  AGU   |--->|    LSQ    |--->|   L2 Cache    |--->|   DDRAM   |
    | (flat) |    | LQ:8 SQ:8|    | 128KB 4-way   |    | Interface |
    +--------+    |  TSO ord. |    | 4 MSHRs       |    +-----------+
                  +-----+-----+    | 32B lines     |
                        |          +-------+-------+
                  +-----v-----+            |
                  |  Data TLB |    +-------v-------+
                  |  32-entry |    |  Mem Arbiter   |
                  |  + Walker |    | ID-based route |
                  +-----------+    +-------+-------+
                                           |
                                   +-------v-------+
                                   |   MMIO Path   |
                                   | strongly ord. |
                                   +---------------+

 --- SoC Peripherals ---------------------------------------------------------

    +-------+  +-------+  +-------+  +--------+  +----------+  +---------+
    |  PIC  |  |  PIT  |  |  PS/2 |  |  RTC   |  | Watchdog |  |   DMA   |
    | 8259  |  | 8254  |  | Kbd + |  | (stub) |  |   NMI    |  | (stub)  |
    +-------+  +-------+  | Mouse |  +--------+  +----------+  +---------+
                           +-------+

 --- ETX Display Engine (replaces VGA) ---------------------------------------

    +----------+   +-----------+   +---------------+   +-------------+
    |  Command |-->|   Blit    |-->|  Mem Hub      |-->| SDRAM A + B |
    |  Ring    |   |  Engine   |   | 6-port arbiter|   | (dual-ch)   |
    |  256x64  |   | ROP/Line  |   | QoS priority  |   +-------------+
    +----------+   +-----------+   +-------+-------+
                                           |
    +----------+   +-----------+   +-------v-------+   +-------------+
    |  Timing  |-->|  Scanout  |-->| Glyph Cache   |-->| Line Buffer |
    |  Gen     |   | 12-stage  |   | 1024-entry L1 |   | 2x1920x24  |
    | register |   |  pipeline |   | tag + data    |   | ping-pong   |
    | driven   |   +-----+-----+   +---------------+   +------+------+
    +----------+         |                                     |
                   +-----v-----+   +-------------+     +------v------+
                   |  Cursor   |   |    Tile     |     | Video Out   |
                   |  Overlay  |   |   Tracker   |     | VGA R/G/B   |
                   | 4-cursor  |   | 4K dirty bm |     | HS/VS/DE    |
                   +-----------+   +-------------+     +-------------+

 --- HARE (Hardware-Assisted Reverse Engineering) ----------------------------

    +-----------+  +-----------+  +-----------+  +-----------+  +---------+
    | Semantic  |  |    AAR    |  |  Shadow   |  |  Stride   |  | Snoop   |
    |  Tagger   |  |  Engine   |  |  Stack    |  | Detector  |  | Engine  |
    +-----------+  +-----------+  +-----------+  +-----------+  +---------+
    +-----------+  +-----------+  +------------------------------------------+
    |   PASC    |  |  Guard    |  |         Telemetry DMA                    |
    | Classify  |  |   Unit    |  |         (stream off-chip)                |
    +-----------+  +-----------+  +------------------------------------------+

 ============================================================================
```

### CPU Core

- **Dual-issue U+V pipeline** with 2-wide dispatch and 2-wide commit
- **16-entry reorder buffer**, 8-entry issue queue, 32-entry physical register file
- **Register renaming** with architectural-to-physical mapping and a free list
- **Branch prediction**: Gshare (256-entry PHT, 8-bit GHR), hybrid tournament predictor, 16-entry return address stack, 8-entry fetch target queue
- **Microcode sequencer**: 256-entry ROM compiled from structured `.us` source files, covering PUSHA/POPA, PUSHF/POPF, INT/IRET, far JMP, MOV Sreg, CR/DTR loads and stores, string operations, BCD arithmetic, and CPUID
- **Execute stage**: ALU (U+V pipes), SIMD byte-lane unit, FPU (spatial), hardware divider, multiplier, and a bitcount unit (POPCNT/LZCNT/TZCNT)
- **Protected mode**: GDT descriptor reads, segment register cache, far call gate traversal, real-to-protected-mode transition via MOV CR0 + far JMP
- **Exceptions**: precise EIP capture, CR2 fault address plumbing, #GP/#PF paths
- **Decode cache**: 256-entry direct-mapped M10K BRAM cache for decoded instruction pairs

### ISA Coverage

The base ISA is 80486DX. Additional instructions are gated behind feature flags and organized into three tiers, each implying the previous:

- **Pentium extensions**: CMOVcc, basic MMX (PAND/POR/PXOR/PANDN/PADDW), RDPMC, MSR performance counters
- **P3/P4 extensions**: PREFETCH, CLFLUSH, MFENCE/LFENCE/SFENCE
- **Nehalem extensions**: POPCNT, LZCNT, TZCNT

CPUID reports the appropriate family/model/feature bits based on which tier is enabled.

### Memory Subsystem

- **Load-store queue**: split-phase request/response, depth-4 pending FIFO, out-of-order response support, TSO ordering enforcement
- **L2 cache**: 128 KB, 4-way set-associative, 32-byte lines, non-blocking with 4 MSHRs
- **Data TLB**: 32-entry, hardware page walker, flush support, CR2 wiring for page faults
- **MMIO path**: strongly ordered, gated on store queue empty
- **Memory request arbiter**: stateless combinational arbitration with ID-based routing

### SoC Peripherals

- **PIC**: 8259-compatible interrupt controller
- **PIT**: 8254-compatible programmable interval timer
- **PS/2**: keyboard and mouse controller with IRQ1/IRQ12
- **RTC, DMA, IDE**: functional stubs for platform compatibility
- **Hardware watchdog**: NMI timeout (gated)
- A20 gate, system reset, NMI path

### ETX Display Engine

The ETX display engine replaces the legacy VGA text controller with a register-configurable rendering pipeline. When enabled, it provides:

- **12-stage scanout pipeline**: cell fetch, glyph cache lookup, format decode, pixel select, text effects (bold, italic, underline, overline, strikethrough, shadow), cursor overlay, palette lookup, and RGB output
- **L1 glyph cache**: 1024-entry direct-mapped, 8x16 monochrome glyphs (16 bytes each), backed by tag and data BRAMs
- **Double line buffer**: 2 x 1920 x 24-bit ping-pong buffers, sized for future 1080p support
- **2D blit engine**: FILL_RECT, BLIT_COPY, BLIT_COLORKEY, PATTERN_FILL, LINE (Bresenham), MONO_EXPAND, with ROP support (COPY/XOR/AND/SOLID_FILL) and color-key comparator
- **Command ring**: 256-entry x 64-bit FIFO with fence/completion tracking, plus an SDRAM-backed ring buffer read path
- **Dual-channel memory hub**: 6-port SDRAM arbiter (3 per channel) with QoS priority FSM and BRAM-backed request FIFOs
- **4-cursor overlay**: position/shape/blink/alpha per cursor, priority mux
- **Dirty tile tracker**: 4K-tile bitmap for partial-screen update optimization
- **640x400 baseline timing** with register-configurable active region

### HARE — Hardware-Assisted Reverse Engineering

A set of coprocessor modules for real-time x86 workload analysis, sitting alongside the CPU core:

- Semantic tagger and PASC (program-aware security) classifier
- AAR engine for automated pattern recognition
- Shadow stack and stride detector
- Snoop engine and guard unit
- Telemetry DMA for streaming analysis data off-chip


## Feature Gating

All major subsystems are controlled by `CONF_ENABLE_*` localparam gates in `rtl/top/f386_pkg.sv`. The default synthesis configuration is a bare 486 core — every extension, cache tier, and peripheral is individually gated and defaults to off. This supports phased development: RTL is written, verified behind its gate, and promoted to default-on only after integration testing passes.

Gates are activated either by Verilog `ifdef` defines (for synthesis and Verilator test selection) or by changing the localparam default. Key gates include:

- `CONF_ENABLE_MICROCODE` — microcode sequencer (Verilator-selectable)
- `CONF_ENABLE_LSQ_MEMIF` — LSQ split-phase memory interface
- `CONF_ENABLE_L2_CACHE` — 128 KB L2 with MSHRs
- `CONF_ENABLE_TLB` — data-side paging translation
- `CONF_ENABLE_PENTIUM_EXT`, `CONF_ENABLE_P3_EXT`, `CONF_ENABLE_NEHALEM_EXT` — ISA tiers
- `CONF_ENABLE_ETX` — ETX display engine (replaces VGA)
- `CONF_ENABLE_DECODE_CACHE` — decoded instruction pair cache
- `CONF_ENABLE_V86` — Virtual 8086 mode (on by default, boot-critical)


## Project Structure

```
rtl/
  top/           Top-level modules, PLL, global package (5 files)
  core/          CPU pipeline: decode, dispatch, execute, ROB, rename,
                 branch prediction, microcode, ALU, FPU, LSQ (43 files)
  memory/        L1D, L2, TLB, page walker, DDRAM interface (14 files)
  soc/           Peripherals: ETX display, PIC, PIT, PS/2, DMA,
                 debug, HARE/AAR subsystem (31 files)
  primitives/    Block RAM, distributed RAM, free list, priority picker (4 files)

bench/
  verilator/     C++ testbenches and CMake build (13 ctest targets)

scripts/
  microcode/     Microcode compiler (Python) and .us source files
  quartus_*.sh   Remote synthesis dispatchers (NAS and VM backends)
  yosys_*.sh     Per-module resource estimation via Yosys
  regression_*.sh  Gated regression scripts

docs/            28 design documents covering ISA coverage, microarchitecture,
                 memory integration, resource budgets, workload analysis,
                 debug protocols, and ETX display engine specification
```

The codebase is 97 SystemVerilog source files across the four RTL directories.


## Target Platform

**Board**: Terasic DE10-Nano (MiSTer FPGA platform)

**Device**: Intel Cyclone V 5CSEBA6U23I7
- 41,910 ALMs
- 553 M10K block RAM (5.66 Mbit)
- 112 DSP blocks

**Quartus**: Prime Lite 17.0.2, chosen for Cyclone V fitter quality, deterministic builds, and compatibility with the NAS-based Docker build flow. The design also builds under Quartus 21.1 on a VM backend.

### Current Resource Utilization

As of the latest Quartus synthesis (full stack: core + LSQ + L2 + TLB + SoC, ETX off):

| Resource | Used | Available | Utilization |
|----------|-----:|----------:|------------:|
| ALMs | 27,236 | 41,910 | 65.0% |
| Registers | 17,515 | 166,036 | 10.6% |
| Block RAM | 1,122,944 bits | 5,662,720 bits | 19.8% |
| DSPs | 9 | 112 | 8.0% |

With ETX display engine enabled (replacing VGA): +383 ALMs, +13 M10K, +1 DSP.

Projected worst-case with all remaining work (CPU completion + HARE + ETX + UTF-8): approximately 86-95% ALM utilization. M10K and DSP headroom remain comfortable.


## Building and Testing

### Prerequisites

- **Verilator** 3.916 or later (for simulation)
- **CMake** 3.16+ and a C++17 compiler
- **sv2v** (for Verilog-2001 conversion before Quartus synthesis)
- **Yosys** (optional, for resource estimation)
- **Python 3** (for microcode compiler)

### Running Tests

```
make test
```

This builds and runs all 13 Verilator test targets via ctest. Tests cover ALU operations, branch prediction, OoO core integration, microcode sequencing, L2 cache, TLB, and a full protected-mode boot sequence.

Individual tests can be run from the build directory:

```
cd bench/verilator/build
cmake .. && make -j
ctest --output-on-failure
```

### Quartus Synthesis

Synthesis is dispatched to a remote backend (NAS preferred, VM fallback):

```
make quartus QUARTUS_HOST=192.168.50.100
```

The synthesis script runs sv2v locally, stages a self-contained job directory, copies it to the remote host, executes `quartus_map` inside a Docker container, and fetches the resource report. An `--etx` flag enables the ETX display engine gate. An `--full` flag runs the fitter and timing analysis in addition to synthesis.

### Resource Estimation

For quick local resource estimates without a Quartus license:

```
make yosys          # Per-module cell counts
make yosys-full     # Full-design flattened count
```


## Documentation

The `docs/` directory contains 28 design documents. Key starting points:

- **`fpga_resource_budget.md`** — Per-module ALM/BRAM/DSP breakdown with Quartus-measured numbers
- **`missing_resource_budget_2026-03-15.md`** — Remaining work items and projected utilization
- **`p2_memory_integration_plan.md`** — LSQ, L2, arbiter, and memory fabric design decisions
- **`etx_display_engine_architecture.md`** — Full ETX specification (1,651 lines)
- **`isa_coverage_analysis.md`** — 486DX instruction coverage matrix
- **`semantic_detection_analysis.md`** — HARE pattern detection design
- **`debug_introspection_protocol.md`** — Multi-tier debug interface specification
