# RTL vs Documentation Audit

Honest assessment of what the documentation claims versus what the RTL actually implements.

---

## Executive Summary

The documentation describes a **mature, Phase 7 Final** design with measured performance
numbers, timing closure, and simulation results. The RTL tells a different story: roughly
**16 of 29 modules are complete**, several critical modules are **stubs or skeletons**,
the design **will not compile** due to undefined types and missing modules, and the
top-level integration is **not wired up**. The documentation reads as an aspirational
architecture specification, not a description of what currently exists in RTL.

---

## Module-by-Module Verdict

### COMPLETE (16 modules — functional, synthesizable logic)

| Module | Doc Claim | RTL Reality | Match? |
|--------|-----------|-------------|--------|
| f386_pkg.sv | Core types and packets | All types defined, clean | YES |
| f386_alu_simd.sv | 4-lane byte SIMD, 7 ops | Full implementation | YES |
| f386_branch_predict.sv | 256-entry bimodal | Full implementation | YES |
| f386_branch_predict_gshare.sv | 8-bit GHR, 256 PHT | Full implementation | YES |
| f386_ras_unit.sv | 16-entry RAS | Full implementation | YES |
| f386_issue_queue.sv | 8-entry reservation station | Full wakeup/select logic | YES |
| f386_register_rename.sv | 8→32 rename map | Full free list + mapping | YES |
| f386_prefetch_unit.sv | Stride-aware prefetcher | Full confidence tracking | YES |
| f386_msr_file.sv | MSR register file | Full implementation | YES |
| f386_l2_cache.sv | 128KB 2-way cache | Full tag/data/FSM | YES |
| f386_mmu_remap_gates.sv | 8 programmable shadow gates | Full priority encoder | YES |
| f386_address_classifier.sv | Bus latency classifier | Full state machine | YES |
| f386_pasc_classifier.sv | PASC memory profiler | Full implementation | YES |
| f386_guard_unit.sv | Execution sandboxing | Full implementation | YES |
| f386_snoop_engine.sv | DMA coherency snooping | Full implementation | YES |
| f386_v86_monitor.sv | V86 mode tracking | Full implementation | YES |
| f386_vbe_accel.sv | SVGA BitBlt accelerator | Full ROP state machine | YES |

### PARTIAL (8 modules — logic present but incomplete or won't compile)

| Module | Doc Claim | RTL Reality | Gap |
|--------|-----------|-------------|-----|
| f386_alu.v | Full EFLAGS generation | Only ZF and SF computed; CF, OF, AF, PF flagged as "// ... etc" | 4 of 6 flags missing |
| f386_rob.sv | 16-entry ROB, 2-wide retire | Dispatch logic exists but `.ready` is never set to 1 — **instructions can never retire** | Non-functional retirement |
| f386_dispatch.sv | Dual-issue U/V dispatch | Good scoreboard + pairing logic, but uses undefined `instr_info_t` and `f386_uv_pipe_if` | Won't compile |
| f386_execute_stage.sv | Execution controller | Functional unit routing exists, but uses undefined `instr_info_t` | Won't compile |
| f386_branch_predict_hybrid.sv | Hybrid Gshare+RAS selector | Instantiates submodules but branch target calc is hardcoded `PC+4` | Always predicts next sequential |
| f386_debug_unit.sv | 4 BP + 4 WP, stealth debug | PC breakpoint matching exists; watchpoints are a comment: "[Watchpoint logic mirrors…]" | Half implemented |
| f386_microcode_rom.sv | 207 mnemonics, hierarchical | Only 5 instructions coded (NOP, PUSHA, CPUID, INVD, CLFLUSH) | ~2.5% of claimed coverage |
| f386_ide_dma.sv | 18.2 MB/s DMA bridge | State machine framework exists; SPI master and byte packing are missing | ~60% complete |

### STUB / SKELETON (5 modules — essentially empty or non-functional)

| Module | Doc Claim | RTL Reality | Gap |
|--------|-----------|-------------|-----|
| f386_fpu_spatial.v | "Full Parallel FPU (v3.0)", pipelined x87, 48 DSP slices, IEEE 754 | **29 lines total.** Hardcoded `fp_done=1; fp_res=fp_a+fp_b`. No pipeline, no DSP, no IEEE 754. | Complete stub |
| f386_ooo_core_top.sv | OoO core integration | Instantiates 3 of 5 components. References `f386_decode_unit` and `f386_aar_engine` which don't exist. | ~40% skeleton |
| f386_pipeline_top.sv | "Dual-issue Superscalar Top" | Instantiates MSR, guard, debug. Comment: "// Integration of f386_dispatch and f386_alu here…" The actual pipeline is not wired. | ~30% skeleton |
| f386_mmu_remap.sv | 8 programmable shadow gates | Hardcoded 2 address ranges (VGA + Option ROM). Not programmable. | Stub (superseded by f386_mmu_remap_gates.sv) |

---

## Files Referenced in Docs But Missing from RTL

| Documented File | Described As | Exists? |
|-----------------|-------------|---------|
| f386_decode.sv | Unified Decoder | NO |
| f386_l1_cache.v | 32KB I/D Cache | NO |
| f386_mmu_tlb.v | 256-entry TLB | NO |
| f386_hyperbus_ctrl.sv | 256MB HyperRAM Controller | NO |
| f386_svga_top.v | VESA SVGA Engine | NO |
| f386_aar_engine.sv | RE Telemetry Suite (shadow stack, thermal map, trace DMA) | NO |
| fabi386_top.sv | Main Top Level | NO |

These 7 modules are listed in `project_directory_structure.md` as existing files and are
referenced by other RTL modules, but they do not exist on disk. They represent the
majority of the system's critical path: **decode, caches, TLB, memory controller, VGA,
telemetry, and top-level integration**.

---

## Documentation Claims vs Reality

### Performance Claims

| Claim | Source | Verifiable? | Verdict |
|-------|--------|-------------|---------|
| 1.78 IPC target | instruction_frequency_analysis.md | No — ROB cannot retire instructions; no working pipeline exists to measure | ASPIRATIONAL |
| 1.28 IPC measured on Dhrystone | timing_verification_summary.md | No — no decoder, no L1 cache, no TLB, no working top-level. Cannot run Dhrystone. | UNVERIFIABLE |
| 150 MHz timing closure, +0.245ns WNS | timing_verification_summary.md | No — design doesn't compile (undefined types, missing modules). No synthesis run is possible. | UNVERIFIABLE |
| 2.05ms BitBlt 640×480×8 | timing_verification_summary.md | Plausible — f386_vbe_accel.sv is complete, but no testbench exists to confirm the number | PLAUSIBLE |
| 18.2 MB/s IDE DMA | timing_verification_summary.md | No — SPI master is not implemented in f386_ide_dma.sv | UNVERIFIABLE |
| 680mW @ 66% utilization | timing_verification_summary.md | No — no synthesis, no power estimate possible | UNVERIFIABLE |

### Resource Utilization Claims

| Claim | Source | Verdict |
|-------|--------|---------|
| OoO Core: 32,700 LUTs | fpga_resource_budget.md | UNVERIFIABLE — design doesn't synthesize |
| Ultra-RE Suite: 10,450 LUTs | semantic_detection_analysis.md | PARTIALLY VERIFIABLE — some RE modules exist (guard, PASC, snoop, V86) but f386_aar_engine (shadow stack, thermal map, trace DMA) is missing |
| SVGA & Accel: 11,550 LUTs | fpga_resource_budget.md | PARTIALLY VERIFIABLE — f386_vbe_accel exists but f386_svga_top is missing |
| L2 Cache: 1,400 LUTs | fpga_resource_budget.md | PLAUSIBLE — f386_l2_cache.sv is complete |
| Total: ~63K LUTs | fpga_resource_budget.md | UNVERIFIABLE |

### Verification Claims

| Claim | Source | Verdict |
|-------|--------|---------|
| Shadow Stack: 100% tracking in BIOS boot | timing_verification_summary.md | NO — f386_aar_engine.sv (which contains shadow stack) does not exist |
| Stack Pivot detection validated | timing_verification_summary.md | NO — shadow stack module missing |
| Stride Detection: 3-byte stride at 0x3C9 | timing_verification_summary.md | PLAUSIBLE — f386_prefetch_unit has stride detection, but no testbench |
| PASC Classification: 100% reliable | timing_verification_summary.md | PLAUSIBLE — f386_pasc_classifier is complete, but no testbench |
| Timing: PASS +0.245ns WNS | timing_verification_summary.md | NO — cannot synthesize; missing 7 modules and undefined types |

### ISA Coverage Claims

| Claim | Source | Verdict |
|-------|--------|---------|
| 207 mnemonics supported | isa_coverage_analysis.md | NO — f386_decode.sv doesn't exist; f386_microcode_rom.sv covers 5 instructions |
| ~900 instruction forms | isa_coverage_analysis.md | NO — no decoder exists |
| 486-specific: BSWAP, CMPXCHG, XADD, etc. | isa_coverage_analysis.md | NO — no decoder, no ALU support for these |
| Full x87 FPU | multiple docs | NO — FPU is a 29-line stub returning `a + b` |

---

## Structural Issues

### 1. Design Cannot Compile
Three modules reference `instr_info_t` (a type) and `f386_uv_pipe_if` (an interface) that
are NOT defined in `f386_pkg.sv` or anywhere else. The dispatch, execute, and debug modules
will fail elaboration.

### 2. Pipeline Is Not Connected
`f386_pipeline_top.sv` has a comment where the actual pipeline should be. The OoO core
top (`f386_ooo_core_top.sv`) references two modules that don't exist. There is no datapath
from fetch → decode → rename → dispatch → execute → retire.

### 3. ROB Cannot Retire
`f386_rob.sv` dispatches instructions and checks `.ready` for retirement, but no logic
ever sets `.ready = 1`. This means the ROB will fill up and stall permanently.

### 4. No Testbenches
Zero testbench files exist anywhere in the repository. No `_tb.sv` files, no simulation
scripts, no waveform references, no cocotb tests. The timing and performance claims in
the documentation cannot have been generated from this codebase.

### 5. MSR Address Conflicts
`msr_specification.md` and `debug_bridge_specification.md` assign different functions to
the same MSR addresses (e.g., 0xC0001000 is `F386_GUARD_CTL` in one doc and `F386_DBG_CTL`
in the other). The docs acknowledge this conflict but it remains unresolved.

---

## What IS Real

Despite the gaps, the project has genuine substance:

1. **Architecture vision is coherent** — the documentation describes a well-thought-out
   OoO 486 with reasonable design choices
2. **16 complete modules** implement real, synthesizable logic for: branch prediction
   (bimodal + gshare + RAS), issue queue, register rename, L2 cache, prefetching,
   MSR file, MMU remapping, memory classification, security monitoring, and SVGA
   acceleration
3. **The OoO building blocks are present** — rename, IQ, and ROB exist (ROB needs the
   retirement fix)
4. **The instrumentation suite** (guard, PASC, snoop, V86 monitor) is largely complete
5. **The package file** defines clean types and structures

---

## Honest Status Assessment

| Category | Docs Say | Reality |
|----------|----------|---------|
| Overall status | "Phase 7 Final" | Early-to-mid development; ~55% of modules complete |
| Compilable | Implied (timing closure claimed) | NO — undefined types, missing modules |
| Synthesizable | YES (resource numbers given) | NO |
| Simulatable | YES (IPC numbers given) | NO — no testbenches, no complete pipeline |
| ISA coverage | 207 mnemonics, 900 forms | 0% — no decoder exists |
| FPU | "Full Parallel FPU v3.0" | Stub: `fp_res = fp_a + fp_b` |
| Pipeline integration | Complete dual-issue OoO | Skeleton; pipeline not wired |
| Verification | Timing closure, IPC measured | No testbenches, no synthesis possible |
