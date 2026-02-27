# fabi386 Project Directory Structure (Final Synchronized)

FPGA Requirements: **~68K+ LUTs, 170+ BRAM (18Kb), 60+ DSP (18x18)**

```
/fabi386
├── rtl/
│   ├── core/
│   │   ├── f386_pipeline_top.sv    // Dual-issue Superscalar Top
│   │   ├── f386_execute_stage.sv   // Execution Unit Controller
│   │   ├── f386_decode.sv          // Unified Decoder
│   │   ├── f386_alu.v              // Integer Unit
│   │   ├── f386_alu_simd.sv        // Graphics/Parallel Unit
│   │   ├── f386_fpu_spatial.v      // Full Parallel FPU (v3.0)
│   │   └── f386_microcode_rom.sv   // Slow-Path Sequencer (MUL/DIV)
│   ├── memory/
│   │   ├── f386_l1_cache.v         // 32KB I/D Cache Logic
│   │   ├── f386_mmu_tlb.v          // 256-entry TLB + i486 OpCodes
│   │   └── f386_hyperbus_ctrl.sv   // 256MB HyperRAM Controller
│   ├── soc/
│   │   ├── f386_svga_top.v         // VESA SVGA Engine
│   │   ├── f386_vbe_accel.sv       // BitBlt / Hardware 2D (Final)
│   │   ├── f386_ide_dma.sv         // Multi-Sector Storage Bridge
│   │   └── f386_aar_engine.sv      // RE Telemetry Suite
│   └── top/
│       ├── fabi386_top.sv          // MAIN TOP LEVEL
│       └── f386_pkg.sv             // Unified Global Package
├── constraints/
│   └── pins.lpf                   // Physical Pin Mapping (target-specific)
└── scripts/
    └── build_bitstream.sh          // Synthesis & PnR Script
```
