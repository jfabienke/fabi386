# fabi386 Reference Cross-Analysis

Detailed mapping of every fabi386 feature to inspirational reference implementations,
plus non-functional requirements (formal verification, testing, build methodology).

---

## PART 1: FUNCTIONAL FEATURES

---

### 1. Out-of-Order Engine

#### 1.1 Register Renaming (8 arch → 32 physical)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **RSD** ★★★★★ | Closest match. SV interfaces, 64 phys regs, explicit RMT + RetirementRMT for bulk recovery on mispredict. Free list uses `MultiWidthFreeList` with dual-port push/pop. | `Src/RenameLogic/RMT.sv`, `Src/RenameLogic/ActiveList.sv` |
| **BOOM** ★★★★☆ | **Per-branch rename snapshots** — single-cycle recovery instead of multi-cycle RetirementRMT restore. Bit-vector free list with cascading priority decoder. 48-80 INT physical regs. | `src/main/scala/v4/exu/rename/` |
| **Toooba** ★★★☆☆ | `RenamingTable.bsv` with Eager History Register (Ehr) for multi-port scheduling. Shows formal-methods-friendly rename design. | `src_Core/RISCY_OOO/procs/lib/RenamingTable.bsv` |
| **NaxRiscv** ★★☆☆☆ | 64 INT + 64 FP physical regs. Plugin-based `RegFilePlugin` with configurable banking. | `src/main/scala/naxriscv/misc/RegFilePlugin.scala` |

**Recommendation:** Start from RSD's RetirementRMT pattern (simpler, lower area), but evaluate BOOM's per-branch snapshots if misprediction recovery latency becomes a bottleneck. fabi386's 32 physical regs for 8 architectural is conservative — RSD uses 64 for 32 architectural. Consider whether the 24 speculative entries are sufficient for the 16-entry ROB window.

---

#### 1.2 Reorder Buffer (16 entries, 2-wide retire)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **RSD** ★★★★★ | 64-entry "ActiveList" with 2 allocate/2 retire per cycle. Random-access write ports for OoO result update. Per-entry: PC, logical dest, execution state, load/store/branch flags. | `Src/RenameLogic/ActiveList.sv` |
| **BOOM** ★★★★☆ | Circular buffer with W banks (W = dispatch width). PC stored in separate 2-bank PC file to amortize area cost. 32-64 entries configurable. | `src/main/scala/v4/exu/rob.scala` |
| **Toooba** ★★★☆☆ | 48-128 entry ROB with fine-grained SpecBits (per-instruction speculation tracking). Shows how to handle large speculation windows. | `src_Core/RISCY_OOO/procs/RV64G_OOO/ReorderBuffer.bsv` |
| **NaxRiscv** ★★☆☆☆ | 64-entry ROB (memory or register-based, configurable per target). Useful for FPGA vs ASIC tradeoff. | `src/main/scala/naxriscv/misc/RobPlugin.scala` |

**Recommendation:** fabi386's 16-entry ROB is small but suitable for a dual-issue x86 that frequently stalls on microcode sequences. Study RSD's ActiveList for the SV implementation pattern. Consider BOOM's separate PC file trick to save ROB entry width — x86 variable-length instructions make this especially attractive since PC storage is larger.

---

#### 1.3 Issue Queue (8-entry unified)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **RSD** ★★★★★ | 16-entry IQ with SourceCAM + ReadyBitTable + ProducerMatrix wakeup. DestinationRAM maps tags to IQ indices. Priority encoder for selection. | `Src/Scheduler/IssueQueue.sv`, `Src/Scheduler/WakeupLogic.sv`, `Src/Scheduler/SelectLogic.sv` |
| **BOOM** ★★★★☆ | **Split IQ by class** (ALU, Mem, FP, Unique). Two scheduling options: unordered (R10K) or age-ordered (collapsing). Reduces port count per queue. | `src/main/scala/v4/exu/issue-units/` |
| **RSD** ★★★☆☆ | **ReplayQueue** for misspeculated loads that need re-issue after cache miss. Separate from main IQ. | `Src/Scheduler/ReplayQueue.sv` |

**Recommendation:** fabi386's unified 8-entry IQ is appropriate for dual-issue. Study RSD's wakeup/select logic (SourceCAM approach) directly — it's the most FPGA-friendly implementation. If IQ pressure becomes a problem, consider BOOM's split-queue approach: separate ALU queue (simple, fast select) from memory queue (needs age ordering for store-to-load forwarding).

---

#### 1.4 Dual-Issue Dispatch (U-pipe / V-pipe)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **RSD** ★★★★★ | 2-wide dispatch with pairing rules, hazard detection. Clean interface between rename and scheduler stages. | `Src/Pipeline/` dispatch logic |
| **BOOM** ★★★☆☆ | 1-4 wide dispatch with per-type queue routing. Shows how to scale dispatch width. | `src/main/scala/v4/exu/core.scala` |
| **ao486_MiSTer** ★★☆☆☆ | Single-issue but shows x86-specific dispatch complexities: prefix handling, microcode sequencing, segment overrides that affect dispatch decisions. | `rtl/ao486/pipeline/` |

**Recommendation:** The U-pipe (full capability) / V-pipe (simple ALU + SIMD) split is unique to fabi386. No reference implements this exact pattern. Use RSD's 2-wide dispatch infrastructure but add x86-specific pairing rules (branches monopolize U-pipe, microcode prevents V-pipe issue, etc.).

---

#### 1.5 Mispredict / Exception Recovery

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **RSD** ★★★★★ | RecoveryManager: RetirementRMT bulk copy back to RMT, selective flush of IQ + ReplayQueue + ActiveList, corrected PC into fetch. | `Src/Recovery/RecoveryManager.sv` |
| **BOOM** ★★★★☆ | **Per-branch snapshot recovery** — single-cycle restore of rename map. No need to wait for ROB drain. Massive IPC improvement on branch-heavy code. | `src/main/scala/v4/exu/rename/` |
| **Toooba** ★★★☆☆ | **Epoch-based flush** + SpecBit clearing. Fine-grained per-instruction speculation tags (8-32). Lower area than full checkpoint approach. | `src_Core/RISCY_OOO/procs/RV64G_OOO/` |

**Recommendation:** For fabi386's 16-entry ROB, RetirementRMT restore (RSD-style) is fast enough (drain at 2/cycle = 8 cycles max). But x86 has many branches (Jcc is in the top-25 instructions). Evaluate BOOM's per-branch snapshots if benchmark data shows recovery latency is significant. Toooba's SpecBits are a good middle ground — lower area than full snapshots but faster than full drain.

---

### 2. Branch Prediction

#### 2.1 Bimodal Predictor (256-entry, 2-bit)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **mor1kx** ★★★☆☆ | `mor1kx_branch_predictor_satcounter.v` — clean Verilog 2-bit saturating counter predictor. Simple and directly reusable pattern. | `rtl/verilog/mor1kx_branch_predictor_satcounter.v` |
| **VexRiscv** ★★☆☆☆ | DYNAMIC option: 2-bit BHT indexed by PC. Shows minimal-area bimodal implementation. | `src/main/scala/vexriscv/plugin/BranchPlugin.scala` |

---

#### 2.2 Gshare Predictor (8-bit GHR, 256-entry PHT)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **RSD** ★★★★★ | 10-bit GHR XOR PC → 2048-entry PHT. **Multi-bank PHT** with queue for bank conflict resolution. Larger than fabi386's 8-bit/256-entry — shows scaling approach. | `Src/FetchUnit/Gshare.sv` |
| **mor1kx** ★★★★☆ | `mor1kx_branch_predictor_gshare.v` — **Clean Verilog Gshare**. Global history + PC index, directly readable Verilog. | `rtl/verilog/mor1kx_branch_predictor_gshare.v` |
| **NaxRiscv** ★★★☆☆ | 24-bit history, 4KB PHT, 512-entry BTB. Shows aggressive Gshare scaling for FPGA. | `src/main/scala/naxriscv/prediction/GSharePlugin.scala` |

**Recommendation:** fabi386's 8-bit GHR / 256-entry PHT is conservative. RSD's 10-bit/2048-entry uses ~4x more storage but significantly better accuracy on loops. Consider scaling to 10-bit GHR (1024 entries = 2KB) which fits easily in one M10K block. Study RSD's multi-bank PHT for handling dual-fetch conflicts.

---

#### 2.3 Hybrid Predictor (Gshare + RAS selector)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **BOOM** ★★★★☆ | **TAGE predictor** — multi-level tagged tables with global history. Tournament/Local/Loop predictors. Far more accurate than simple Gshare. 64-bit GHR. | `src/main/scala/v4/ifu/bpd/tage.scala` |
| **BOOM** ★★★★☆ | **Fetch Target Queue** — decouples branch metadata from ROB. Saves ROB entry width significantly. | `src/main/scala/v4/ifu/frontend.scala` |
| **mor1kx** ★★★☆☆ | Simple → SAT_COUNTER → GSHARE progression shows how to build predictor hierarchy with configurable selection. | Branch predictor directory |

**Recommendation:** fabi386's hybrid (Gshare + RAS) is a good starting point. For a future upgrade, study BOOM's TAGE — it's the state of the art and would significantly improve prediction on x86 workloads with deep call chains and complex control flow. The Fetch Target Queue pattern is worth adopting immediately — x86 variable-length instructions make storing prediction metadata in the ROB expensive.

---

#### 2.4 Return Address Stack (16-entry)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **BOOM** ★★★☆☆ | 32-entry RAS with speculative push/pop and checkpoint restore on mispredict. | Branch prediction in frontend |
| **RSD** ★★☆☆☆ | RAS integrated with Gshare. Recovery on pipeline flush. | `Src/FetchUnit/` |

**Recommendation:** fabi386's RAS already leverages the Semantic Tagger (PROLOGUE/EPILOGUE detection) — this is a unique advantage no reference has. The 16-entry depth is adequate for 486-era call depth. Study BOOM's speculative RAS checkpoint for correctness on deep speculation.

---

### 3. Pipeline Front-End

#### 3.1 Fetch / Prefetch (stride-aware)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_MiSTer** ★★★★☆ | 16-byte prefetch FIFO for x86 variable-length instructions. Shows how to handle the unique challenge of x86 fetch: instruction boundaries are unknown until decode. | `rtl/ao486/pipeline/fetch.v` |
| **ao486_original** ★★★★☆ | Similar prefetch buffer. Code-only I-cache (16KB direct-mapped, VIPT). | `rtl/ao486/pipeline/prefetch.v` |
| **zipcpu** ★★★☆☆ | `pfcache.v` — formally verified instruction cache. Clean fetch pipeline with proof of correctness. | `rtl/core/pfcache.v`, `bench/formal/ffetch.v` |
| **NaxRiscv** ★★☆☆☆ | Speculative D-cache hit prediction — reduces load-to-use latency by predicting hits. Applicable to I-cache too. | Fetch stage in frontend |

**Recommendation:** x86 fetch is fundamentally different from RISC fetch (variable-length, prefix bytes, alignment issues). The ao486 implementations are the only relevant references for this specific problem. fabi386's stride-aware prefetcher goes beyond ao486 — study NaxRiscv's speculative hit prediction to further reduce fetch latency.

---

#### 3.2 Decode (x86 unified decoder)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_MiSTer** ★★★★★ | Auto-generated command tables from instruction definitions. Shows practical approach to the massive x86 decode problem. Python scripts generate decoder logic. | `rtl/ao486/autogen/` |
| **ao486_original** ★★★★★ | 78 microcode command files (`.txt`), each defining decode/read/execute/write sub-ops per instruction. Pattern-matching format for instruction definitions. | `rtl/ao486/commands/*.txt` |
| **80x86** ★★★★☆ | 6-state decode FSM (OPCODE→MODRM→DISPLACEMENT→IMMED1→IMMED2→WAIT_SPACE). 4-entry decoded instruction FIFO. Clean SV. | `rtl/InsnDecoder.sv` |
| **80x86** ★★★★☆ | 58 `.us` microcode files with C-preprocessor macros for code reuse. Mustache templates generate Microcode ROM. | `microcode/*.us` |

**Recommendation:** x86 decode is the hardest part of any x86 implementation. ao486_original's 78-file microcode command system and ao486_MiSTer's auto-generated tables are essential references. 80x86's C-preprocessor macro approach to microcode is cleaner and more maintainable. fabi386's hierarchical Micro-ROM + Nano-ROM compression (135K transistor budget) should study all three approaches.

---

#### 3.3 Microcode ROM (hierarchical: Micro-ROM + Nano-ROM + x87 Sequencer)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_original** ★★★★★ | 78 command definition files with structured format. Each file is one instruction class. Auto-generated via scripts. Defines read/execute/write micro-ops. | `rtl/ao486/commands/` |
| **ao486_MiSTer** ★★★★☆ | Auto-generated `autogen/` directory with full decode/execute tables from Python. | `rtl/ao486/autogen/` |
| **80x86** ★★★★☆ | Mustache-template microcode generation. C-preprocessor macros like `ARITH_REGMEM_REG` handle instruction families. 304+ microinstructions. | `rtl/Microcode.sv.templ`, `microcode/*.us` |
| **zet** ★★☆☆☆ | Simple microcode ROM loaded from file. Useful baseline for comparison. | `cores/zet/rtl/zet_micro_rom.v` |

**Recommendation:** fabi386's hierarchical compression (Nano-Store dedup, operand-agnostic templates, BRAM/LUTRAM split) is more advanced than any reference. The key insight from ao486 is auto-generation from structured definitions — consider building a similar toolchain to generate the Micro-ROM and Nano-ROM content from high-level instruction specifications.

---

### 4. Execution Units

#### 4.1 Integer ALU (32-bit, dual instance)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **RSD** ★★★★☆ | 2x Integer ALU in 3-stage pipeline (issue → regread → execute → writeback). Clean SV implementation. | `Src/Pipeline/IntegerBackEnd/` |
| **80x86** ★★★☆☆ | 27 separate ALU operation modules — one per operation. Very modular but verbose. Shows x86-specific flag generation. | `rtl/alu/*.sv` |
| **ao486_original** ★★★☆☆ | x86-specific flag computation (AF, PF, etc.) which is notoriously complex. Reference for EFLAGS generation. | `rtl/ao486/pipeline/execute.v` |
| **zipcpu** ★★★☆☆ | Formally verified `cpuops.v` ALU — proof that flag generation is correct. | `rtl/core/cpuops.v`, `bench/formal/` |

**Recommendation:** fabi386's dual ALU is straightforward. The critical x86-specific concern is EFLAGS generation — study ao486's implementation for the notoriously tricky AF (Adjust Flag) and PF (Parity Flag) calculations. Consider ZipCPU's approach of formally verifying ALU correctness.

---

#### 4.2 x87 FPU (pipelined, DSP-based)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **mor1kx** ★★★★★ | `pfpu32` — **pipelined IEEE 754 single-precision FPU**. Modules: addsub, muldiv, cmp, i2f, f2i, rnd. Formally verified. Multiple rounding modes. | `rtl/verilog/pfpu32/pfpu32_top.v`, `pfpu32_addsub.v`, `pfpu32_muldiv.v` |
| **RSD** ★★★☆☆ | Optional FP pipeline (7 stages). Shows how to integrate FPU into OoO backend with separate FP physical register file. | FP execution pipeline |
| **VexRiscv** ★★★☆☆ | Cascaded 17x17 multipliers (no DSP blocks). Shows pure-logic FP multiply for FPGA portability. | FPU plugin |
| **NaxRiscv** ★★☆☆☆ | FPU execution unit integrated into OoO engine with separate 64 FP physical regs. | FPU plugin |

**Recommendation:** mor1kx's pfpu32 is the primary reference for fabi386's pipelined FPU. The module decomposition (addsub, muldiv, cmp, conversions, rounding) maps directly to x87 operations. fabi386 needs 64-bit (double precision) support in addition to 32-bit — the pfpu32 architecture can be extended. The formal verification proofs for FPU correctness are critical given IEEE 754 corner cases. Study how RSD integrates FPU into the OoO pipeline (separate issue queue, longer pipeline, result forwarding).

---

#### 4.3 SIMD Unit (4-lane byte operations)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **VexRiscv** ★★★☆☆ | **CfuPlugin** — Custom Function Unit framework. Shows how to add non-standard execution units (like SIMD) to a pipeline via a clean plugin interface. | `src/main/scala/vexriscv/plugin/CfuPlugin.scala` |
| *No direct match* | fabi386's byte-lane SIMD for graphics acceleration is unique among references. No 486-era x86 core implements SIMD. |

**Recommendation:** fabi386's SIMD unit (saturating add/sub, min/max, alpha blend) is a custom extension with no direct precedent in x86 reference designs. VexRiscv's CfuPlugin pattern shows how to cleanly integrate custom execution units. Ensure the SIMD unit's interface to the V-pipe is well-defined so it can be optionally removed for area savings.

---

#### 4.4 Multiply / Divide

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **zipcpu** ★★★★☆ | **Configurable multiply:** 0 (none) to 4 (pipelined stages) to 36 (DSP) cycle options. Formally verified abstract models (`abs_mpy.v`, `abs_div.v`). | `rtl/core/`, `bench/formal/` |
| **80x86** ★★★☆☆ | Non-restoring divider with signed/unsigned overflow detection. x86-specific division behavior (INT 0 on overflow). | `rtl/Divider.sv` |
| **RSD** ★★★☆☆ | MUL/DIV in Complex Execution Unit (5-6 stages). Shows how to handle multi-cycle operations in OoO pipeline without blocking issue queue. | `Src/Pipeline/IntegerBackEnd/` |
| **VexRiscv** ★★☆☆☆ | Cascaded 17x17 multipliers — FPGA-friendly approach avoiding DSP block dependency. | Multiplier plugin |

**Recommendation:** x86 IMUL/IDIV are multi-cycle and complex (especially 64-bit results from 32x32 multiply, and division overflow trapping). Study 80x86's non-restoring divider for x86-correct overflow detection. ZipCPU's configurable multiply (trade area vs latency) is useful for FPGA tuning. RSD shows how to keep the IQ from stalling during multi-cycle operations.

---

### 5. Memory Hierarchy

#### 5.1 L1 Cache (32 KB target)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_MiSTer** ★★★★☆ | 4KB 4-way I-cache with LRU. Small but shows x86-specific cache concerns: self-modifying code invalidation, alignment handling. | `rtl/cache/l1_icache.v` |
| **ao486_original** ★★★★☆ | 16 KB direct-mapped I$ and D$ (VIPT). Write-back D-cache. Shows x86 cache coherency with page-level write protection. | Cache modules |
| **RSD** ★★★★☆ | 2KB 2-way D-cache, **non-blocking with 2 MSHRs**. Write-back. Shows how to avoid pipeline stalls on cache miss in OoO context. | `Src/Cache/DCache.sv` |
| **zipcpu** ★★★★☆ | **Formally verified** `dcache.v` — proof that cache maintains coherency invariants. | `rtl/core/dcache.v`, `bench/formal/` |
| **NaxRiscv** ★★★☆☆ | 16KB 4-way, **non-blocking (2 refill + 2 writeback slots)**, speculative hit prediction (3-cycle load-to-use). | `src/main/scala/naxriscv/lsu/DataCache.scala` |
| **VexRiscv** ★★★☆☆ | Multi-way with sync/async tag options. Shows FPGA BRAM vs LUT tradeoffs for cache tags. | `src/main/scala/vexriscv/ip/DataCache.scala` |
| **BOOM** ★★★☆☆ | 16KB 4-way non-blocking L1 I$ and D$. Store-to-load forwarding. | LSU module |
| **mor1kx** ★★★☆☆ | Set-associative with LRU, **write-around with snoop support** for DMA coherency. 256-entry store buffer. | `rtl/verilog/mor1kx_dcache.v` |

**Recommendation:** fabi386's 32KB L1 target is larger than any reference. Start with ao486's x86-specific cache logic (write-through vs write-back policies, self-modifying code handling) and scale up. For the OoO pipeline, non-blocking cache is critical — study RSD's MSHR approach. NaxRiscv's speculative hit prediction (3-cycle load-to-use) would significantly improve fabi386's effective memory latency.

---

#### 5.2 L2 Cache (128 KB, 2-way)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_MiSTer** ★★★★☆ | 4KB unified L2 **shared with VGA framebuffer** access. Shows how to arbitrate between CPU and display controller for shared cache. | `rtl/cache/l2_cache.v` |
| **Toooba** ★★★☆☆ | L1 → LLC hierarchy with MESI coherence. Shows multi-level inclusion policies. | Coherence modules |
| **mor1kx** ★★☆☆☆ | Cache with snoop support for multicore/DMA. Relevant for fabi386's snoop engine. | D-cache module |

**Recommendation:** fabi386's L2 is much larger than ao486's (128KB vs 4KB). The key insight from ao486_MiSTer is VGA framebuffer sharing — fabi386's SVGA engine will need similar arbitrated access to the L2. Study Toooba's inclusive cache hierarchy for the L1-L2 coherency protocol.

---

#### 5.3 TLB / MMU (256-entry, shadow gates)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_original** ★★★★★ | 32-entry TLB with hardware page table walker, 4KB/4MB pages, access checking (U/S, R/W, dirty bit update). x86-specific INVLPG/INVD flush. | `rtl/ao486/memory/tlb.v` |
| **ao486_MiSTer** ★★★★☆ | Same TLB with MiSTer-adapted memory paths. Shows integration with Avalon bus for page walks. | `rtl/ao486/memory/tlb.v` |
| **Toooba** ★★★☆☆ | **Two-level TLB:** L1 (32 entries, fast) + L2 (1024 4KB + 8 huge page entries). Non-blocking D-TLB (4 concurrent translations). | TLB modules |
| **NaxRiscv** ★★★☆☆ | 2-level TLB: L0 (4-way/32-set) + L1 (2-way/32-set). Shows FPGA-efficient TLB hierarchy. | TLB modules |
| **mor1kx** ★★☆☆☆ | Configurable sets/ways TLB with optional hardware reload. | TLB module |

**Recommendation:** fabi386's 256-entry TLB is much larger than ao486's 32-entry. The shadow gate remapping (8 programmable gates for UMA/ROM shadowing) is unique to fabi386. For the core TLB design, ao486_original's page table walker is essential — it handles all x86-specific page walk semantics (accessed/dirty bit updates, page fault conditions, CR0/CR3 interactions). Consider Toooba/NaxRiscv's two-level TLB hierarchy if the 256-entry single-level TLB causes timing issues.

---

#### 5.4 Load-Store Queue

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **RSD** ★★★★★ | 16-entry LQ + 16-entry SQ with **store forwarding** and **memory dependency prediction** for speculative load execution. | `Src/Pipeline/MemoryBackEnd/` |
| **BOOM** ★★★★☆ | Split: Load Address Queue + Store Address Queue + Store Data Queue (8-16 entries each). Speculative loads with ordering violation detection at store commit. | `src/main/scala/v4/lsu/lsu.scala` |
| **Toooba** ★★★★☆ | **Split Load-Store Queue** with store buffer. TSO memory model support — directly relevant for x86 which requires strong ordering. | `src_Core/RISCY_OOO/procs/RV64G_OOO/SplitLSQ.bsv` |
| **mor1kx** ★★★☆☆ | 256-entry store buffer (FIFO). Decouples LSU from memory bus. Shows simple store buffer design. | Store buffer module |

**Recommendation:** fabi386's LSQ is listed as "TBD" in the RSD comparison — this is a critical missing piece. x86 requires TSO (Total Store Order) — all stores must be visible in program order, but loads can be reordered with respect to other loads. Study Toooba's TSO support directly. RSD's memory dependency predictor enables speculative load execution, which is key for OoO performance. BOOM's split address/data queues reduce area by separating store address computation from data availability.

---

#### 5.5 Non-Blocking Cache / MSHR

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **RSD** ★★★★★ | D-cache with **2 MSHRs** — handles 2 outstanding misses without stalling. Write-back policy. | `Src/Cache/DCache.sv` |
| **NaxRiscv** ★★★★☆ | **2 refill + 2 writeback** concurrent slots. Speculative hit prediction further reduces miss penalty. | Data cache module |
| **BOOM** ★★★☆☆ | Non-blocking L1 with MSHR tracking. 4-way associative. | D-cache module |

**Recommendation:** Non-blocking cache with MSHRs is essential for OoO to be effective. Without it, a cache miss stalls the entire memory pipeline. Study RSD's 2-MSHR implementation — it's a good balance of area vs miss-level parallelism for FPGA. Consider NaxRiscv's speculative hit prediction for further latency reduction.

---

#### 5.6 Bus Snoop / DMA Coherency

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **mor1kx** ★★★★☆ | D-cache with **snoop port** for external coherency. Write-around policy simplifies coherency. Designed for DMA coherency in SoC. | `rtl/verilog/mor1kx_dcache.v` |
| **Toooba** ★★★☆☆ | Full **MESI cache coherence** protocol (L1 → LLC). Overkill for fabi386 but shows correct coherence state machines. | `src_Core/RISCY_OOO/coherence/src/CCTypes.bsv` |
| **ao486_MiSTer** ★★☆☆☆ | L2 shared with VGA — implicit coherency through shared access port. | L2 cache |

**Recommendation:** fabi386's snoop engine monitors ISA bus for external DMA (HLDA + write cycles) and invalidates L1. mor1kx's snoop port design is the closest match — passive monitoring with cache line invalidation. This is simpler than full MESI (which is overkill for a single-core 486).

---

### 6. SoC Peripherals

#### 6.1 PC Peripheral Set (PIC, PIT, DMA, IDE, PS/2, RTC)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_MiSTer** ★★★★★ | **Complete PC peripheral set**: dual 8259 PIC, 8254 PIT, DMA controller, IDE/ATA (4 devices), floppy (NEC765), dual PS/2, RTC, joystick. All tested with real DOS/Windows. | `rtl/soc/` (all peripheral modules) |
| **zet** ★★★☆☆ | 8254 PIT, 8259 PIC, PS/2 controller, UART. Simpler implementations but clean Verilog. | `cores/` peripheral directories |
| **zipcpu** ★★★☆☆ | **Formally verified** interrupt controller, timers, DMA controller, watchdog. | `rtl/peripherals/icontrol.v`, `wbdmac.v` |

**Recommendation:** ao486_MiSTer's peripheral modules are production-tested on real hardware running DOS/Windows 95. These should be adapted directly for fabi386's SoC. ZipCPU's formally verified DMA and interrupt controller could replace ao486's if formal guarantees are desired.

---

#### 6.2 VGA / SVGA Graphics

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_MiSTer** ★★★★★ | VGA/SVGA up to 1280x1024. Shared L2 cache for framebuffer. MiSTer video_mixer integration for HDMI/VGA output. | VGA modules in `rtl/soc/` |
| **zet** ★★★☆☆ | VGA controller (25+ files) — text and graphics modes. **FML (Fast Memory Link)** — dedicated graphics memory path separate from CPU bus. | `cores/vga/` |
| **ao486_MiSTer** ★★★☆☆ | MiSTer video pipeline: video_mixer → HDMI TX. Clock domain crossing for VGA → system clock. | `sys/` framework modules |

**Recommendation:** fabi386's SVGA + BitBlt accelerator goes far beyond ao486's VGA. Use ao486_MiSTer's VGA core as the base register-compatible implementation, then layer fabi386's BitBlt engine on top. Zet's FML concept (dedicated graphics memory path) aligns with fabi386's approach of separate VGA memory access.

---

#### 6.3 Sound (OPL3 via DSP)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_MiSTer** ★★★★★ | **Sound Blaster 16 + OPL3 FM synthesis + SAA1099 + CDDA audio**. Complete audio subsystem with MiSTer audio_mixer integration. | Sound modules in `rtl/soc/` |

**Recommendation:** ao486_MiSTer's OPL3 implementation is the direct reference. fabi386 allocates 48 DSP slices and 850 LUTs for audio. The ao486 audio modules handle all mixing, sample rate conversion, and MiSTer audio pipeline integration.

---

#### 6.4 IDE / Storage DMA

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_MiSTer** ★★★★☆ | IDE/ATA controller supporting 4 devices (2 channels). Integrated with MiSTer's SD card mounting (virtual HDDs/CD-ROMs). | IDE module in `rtl/soc/` |
| **zipcpu** ★★★☆☆ | **Formally verified DMA controller** (wbdmac.v) — Wishbone DMA with proof of correctness. | `rtl/peripherals/wbdmac.v` |

**Recommendation:** fabi386's IDE DMA bridge (18.2 MB/s) goes beyond ao486's PIO-mode IDE. Study ao486_MiSTer's IDE register interface for compatibility, then add fabi386's DMA acceleration layer. ZipCPU's formally verified DMA is worth studying for the DMA correctness proofs.

---

### 7. MiSTer Platform Integration

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_MiSTer** ★★★★★ | **Complete MiSTer integration**: `emu` top module, `hps_io.sv` for HPS bridge, OSD menu, SD card mounting, PS/2 forwarding, UART bridge, PLL clock management, status register protocol. | `ao486.sv`, `sys/` framework |
| **ao486_MiSTer** ★★★★★ | **Multi-clock domain management**: clk_sys (CPU), clk_vga (pixel clock), clk_audio (44.1/48 kHz), clk_uart. PLL reconfiguration for dynamic CPU speed. | PLL and clock modules |
| **ao486_MiSTer** ★★★★★ | **DDR3 access from FPGA**: 64-bit DDRAM interface through MiSTer's memory controller. Arbitrated between CPU and trace buffer. | DDRAM interface modules |

**Recommendation:** ao486_MiSTer is the only reference that targets the same platform. Its MiSTer integration pattern is mandatory study — the `emu` module interface, `hps_io.sv` protocol, status register format, and clock domain management must all be adopted. fabi386 will need to adapt the HyperBus controller to use MiSTer's SDRAM (32MB + 128MB) instead.

---

### 8. Security & Debug (unique to fabi386)

#### 8.1 Shadow Stack (512-entry)

No reference implements a hardware shadow stack. This is a unique fabi386 feature.

**Possible inspiration:** BOOM's per-branch rename snapshots use a similar concept — storing architectural state for later comparison/recovery. The shadow stack is effectively a "return address snapshot" with mismatch detection.

#### 8.2 Hardware Guard Unit (execution sandboxing)

No reference implements execution range sandboxing. Toooba's **DARPA SSITH security modes** (cache partitioning) are the closest concept — hardware-enforced security boundaries.

#### 8.3 Semantic Tagger (9-pattern detector)

Unique to fabi386. No reference has instruction-level pattern matching for prologue/epilogue detection.

#### 8.4 Debug Unit (4 BP + 4 WP)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **VexRiscv** ★★★☆☆ | OpenOCD/GDB integration via JTAG debug interface. Shows industry-standard debug protocol implementation. | Debug plugin |
| **RSD** ★★★☆☆ | **Konata pipeline visualization** — debug tool that displays per-instruction pipeline stage progression. Useful for performance debugging. | Debug/visualization tools |

#### 8.5 Telemetry / Trace DMA

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **Toooba** ★★★☆☆ | **Tandem verification** — instruction trace output compared against golden model (Spike). Same concept as fabi386's trace buffer but used for verification. | Tandem verification modules |

---

### 9. FPGA Resource Optimization

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **RSD** ★★★★★ | `BlockMultiBankRAM` (BRAM dual-port with banking for port scaling), `DistributedMultiPortRAM` (LUT-based for small structures), `MultiWidthFreeList`. | `Src/Primitives/` |
| **VexRiscv** ★★★★☆ | 504 LUT → 1935 LUT scaling. No vendor primitives — pure synthesizable logic. Sync (BRAM) vs Async (LUT) register file options. Cascaded 17x17 multipliers. Configurable pipeline depth for area/frequency tradeoff. | Various plugins |
| **NaxRiscv** ★★★☆☆ | 13.3K LUT + 11.5 BRAM for full OoO RV64 on Artix-7. Dual LSU: Legacy vs ASIC-optimized, choose per target. | Generation configs |
| **zipcpu** ★★★☆☆ | Configurable multiply (0/1/2/3/4/36-cycle options) — trade area vs latency per FPGA capacity. | Multiply modules |

**Recommendation:** RSD's FPGA primitives library is directly reusable in fabi386's SystemVerilog codebase. The `BlockMultiBankRAM` pattern is critical for implementing multi-ported structures (register file, IQ CAM) using Cyclone V's dual-port M10K blocks. VexRiscv's area optimization techniques (sync vs async register file, configurable shifter, optional features) should guide fabi386's resource budget decisions.

---

## PART 2: NON-FUNCTIONAL REQUIREMENTS

---

### 10. Formal Verification

#### 10.1 Formal Verification Framework

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **zipcpu** ★★★★★ | **Gold standard.** 40 formal verification suites (.sby files). SymbiYosys framework with SMT-based model checking. Every major component has a proof: core, decode, ALU, all memory controllers, bus arbiters, all peripherals, full system. | `bench/formal/*.sby` |
| **zipcpu** ★★★★★ | **Formal property files**: `ffetch.v` (fetch properties), `fmem.v` (memory properties), `fdebug.v` (debug properties). Reusable assume/assert patterns. CPU_ASSUME/CPU_ASSERT macros. | `bench/formal/ffetch.v`, `fmem.v`, `fdebug.v` |
| **zipcpu** ★★★★★ | **Abstract models**: `abs_mpy.v`, `abs_div.v` — simplified behavioral models used in place of full multiply/divide during formal proofs to reduce state space. | `bench/formal/abs_mpy.v`, `abs_div.v` |
| **mor1kx** ★★★★☆ | 40+ SymbiYosys verification files. Verified: Cappuccino control, register file, writeback, fetch, ALU, bus, caches, store buffer, **FPU (all pfpu32 modules)**. | `bench/formal/*.sby` |
| **mor1kx** ★★★★☆ | **FPU formal proofs** — each pfpu32 module (addsub, muldiv, cmp, i2f, f2i) has formal properties proving IEEE 754 correctness. Critical for x87. | `bench/formal/pfpu32_*.sby` |

**Recommendation for fabi386:**
1. Adopt SymbiYosys as the formal verification framework (both ZipCPU and mor1kx use it)
2. Write `.sby` configuration files for every RTL module
3. Create formal property files following ZipCPU's pattern (separate `f*.v` property files)
4. Use abstract models for multiply/divide/FPU during system-level proofs
5. Priority order for formal proofs:
   - **Phase 1:** ALU (flag correctness), ROB (consistency), register rename (mapping correctness)
   - **Phase 2:** Cache (coherency invariants), TLB (translation correctness), LSQ (ordering)
   - **Phase 3:** Branch prediction (state machine correctness), prefetch (buffer management)
   - **Phase 4:** Full pipeline (liveness, deadlock freedom)
   - **Phase 5:** Peripherals, DMA, snoop engine
6. FPU formal verification should follow mor1kx's per-module proof pattern

---

#### 10.2 Formal Verification Methodology Patterns

| Pattern | Reference | Description |
|---------|-----------|-------------|
| **Module-level assume/assert** | ZipCPU | Each module defines input assumptions and output assertions. Compose proofs hierarchically. |
| **Abstract model substitution** | ZipCPU | Replace complex units (MUL, DIV) with behavioral models during system proofs to reduce state space. |
| **Interface contracts** | ZipCPU | Bus protocols (Wishbone B4) have formal property files proving protocol compliance. |
| **Cover statements** | ZipCPU | Use `cover()` to prove reachability — ensure valid states are actually reachable, not just that invalid states are unreachable. |
| **Bounded model checking** | ZipCPU, mor1kx | SMT-based proofs with configurable depth bounds. Practical for 10-30 cycle proofs. |
| **Per-FPU-operation proofs** | mor1kx | Each FP operation (add, mul, div, compare, convert) has separate proof with IEEE 754 corner cases. |

---

### 11. Simulation & Validation

#### 11.1 ISA-Level Validation (Golden Model Comparison)

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_original** ★★★★★ | **Bochs486 golden model** — modified Bochs 2.6.2 CPU serves as cycle-by-cycle reference. RTL simulation runs alongside Bochs, comparing register state and memory writes. Proves ISA correctness. | `bochs486/` directory |
| **80x86** ★★★★☆ | **C++ reference model** — 67+ instruction implementations. Software model runs alongside RTL for comparison. More lightweight than full emulator. | `sim/cppmodel/` |
| **Toooba** ★★★☆☆ | **Tandem verification** — instruction trace from RTL compared against Spike (RISC-V ISA simulator). Catches any ISA divergence. | Tandem verification modules |

**Recommendation for fabi386:**
1. **Primary approach:** Bochs-based validation following ao486_original. Run Bochs 2.6.2 (or modern Bochs) as golden reference for x86 ISA correctness.
2. **Lightweight alternative:** Build a C++ reference model (like 80x86) for quick per-instruction unit tests.
3. **Integration:** Toooba's tandem verification pattern — emit instruction traces from RTL, compare against golden model continuously during simulation.
4. **Key x86 corner cases to validate:** Protected mode transitions, V86 mode, task switching, exception delivery, segment limit checking, page fault handling, x87 exception flags.

---

#### 11.2 Cycle-Accurate Simulation

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_original** ★★★★☆ | iVerilog and Verilator testbenches. Verilator for fast C++ simulation. | Testbench directory |
| **80x86** ★★★★☆ | Comprehensive Verilator-based simulation with 20+ unit tests, per-instruction tests, integration tests. **Docker build environment** for reproducible CI. | Test infrastructure |
| **RSD** ★★★☆☆ | **Konata pipeline visualization** — generates visual pipeline diagrams showing per-instruction stage progression. Invaluable for debugging OoO stalls and hazards. | Visualization tools |

**Recommendation:** Use Verilator for fast simulation (following ao486/80x86 pattern). Adopt RSD's Konata visualization to debug OoO pipeline behavior — seeing instruction flow through rename/issue/execute/retire is critical for OoO performance tuning.

---

#### 11.3 Random / Fuzz Testing

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **VexRiscv** ★★★★☆ | **Random configuration regression testing** — TestIndividualFeatures with random seeds. Tests every permutation of feature flags to catch interaction bugs. | Test infrastructure |
| **BOOM** ★★★☆☆ | SmallBOOM → MegaBOOM configuration sweep. Each configuration is a separate test target. | Config mixins and test suite |

**Recommendation:** fabi386 should implement random configuration testing — vary ROB size, IQ depth, cache parameters, branch predictor type, and verify correctness across all combinations. This catches subtle interaction bugs between features.

---

### 12. Build & Integration

#### 12.1 Synthesis Flow

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_MiSTer** ★★★★★ | **Complete Quartus project** for Cyclone V DE10-Nano. Pin constraints (.qsf), timing constraints (.sdc), PLL configuration, IP block instantiation. | Project files in root |
| **ao486_original** ★★★☆☆ | Quartus project for DE2-115 (Cyclone IV). Shows how to set up timing constraints for CPU cores. | Quartus project files |

**Recommendation:** ao486_MiSTer's Quartus project is the template for fabi386's build. Copy the pin constraints, PLL configuration, and MiSTer framework files. Modify CPU core instantiation and memory controller mapping.

---

#### 12.2 Multi-Platform Support

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **zet** ★★★☆☆ | Same core across DE0/DE1/DE2/DE2-115 — board-specific wrappers with shared RTL. | `boards/` directory |
| **VexRiscv** ★★★★☆ | AXI4, Avalon, Wishbone, AHB-Lite all from same core. Shows how to abstract bus interface for portability. | Bus interface plugins |
| **NaxRiscv** ★★★☆☆ | **LiteX integration** — SoC builder for rapid FPGA prototyping. Generates full SoC from Python description. | LiteX integration |

**Recommendation:** fabi386 currently targets MiSTer only, but if portability is desired, VexRiscv's bus abstraction pattern (same core, multiple bus wrappers) and Zet's board-specific wrapper approach are the models to follow.

---

#### 12.3 Configuration / Parameterization

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **RSD** ★★★★★ | `MicroArchConf.sv` — single file with ALL microarchitecture parameters. `ifdef`-controlled feature gating. | `Src/MicroArchConf.sv` |
| **BOOM** ★★★★☆ | `BoomCoreParams` — SmallBOOM/MediumBOOM/LargeBOOM/MegaBOOM as named configurations. Configuration mixins for composability. | `src/main/scala/v4/common/parameters.scala`, `config-mixins.scala` |
| **mor1kx** ★★★☆☆ | `FEATURE_*` parameters for feature gating. Each feature can be independently enabled/disabled at synthesis time. | Module parameters |
| **VexRiscv** ★★★☆☆ | Plugin system — every feature is opt-in. 42+ pre-built configurations in `demo/` directory. | Demo configurations |

**Recommendation:** fabi386 should adopt RSD's pattern: single `MicroArchConf.sv` (similar to existing `f386_pkg.sv`) with all tunable parameters. Define named configurations: "fabi386_minimal" (small ROB/IQ, no SIMD, no RE suite) → "fabi386_full" (current spec) → "fabi386_debug" (full + expanded trace buffer). This enables resource exploration and testing.

---

#### 12.4 Documentation

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **BOOM** ★★★★★ | **Gold standard documentation.** ReStructuredText specs in `docs/` covering entire microarchitecture. Published tech report (UC Berkeley EECS-2017-157). | `docs/` directory |
| **RSD** ★★★★☆ | Konata pipeline visualization docs. Architecture overview with block diagrams. | Documentation |
| **ao486_MiSTer** ★★★☆☆ | MiSTer-specific integration docs, memory map, peripheral register descriptions. | Various docs |

**Recommendation:** fabi386 already has excellent documentation (15 files in `docs/`). Consider BOOM's RST-based approach for generating a unified HTML/PDF architecture manual that can be published alongside the GitHub repo.

---

### 13. Performance Benchmarking

| Reference | Relevance | What to Study |
|-----------|-----------|---------------|
| **ao486_original** ★★★★☆ | **Dhrystone** as baseline: 1.0-4.58 VAX MIPS. Direct comparison target for fabi386 on same ISA. | Benchmark results |
| **NaxRiscv** ★★★★☆ | 2.93 DMIPS/MHz, 5.02 CoreMark/MHz at 155 MHz on Artix-7 (13.3K LUT). Best FPGA OoO performance reference. | Published benchmarks |
| **BOOM** ★★★☆☆ | 6.2 CoreMarks/MHz. Sets upper bound for what OoO on FPGA can achieve. | Published results |
| **VexRiscv** ★★★☆☆ | 1.44 DMIPS/MHz, 2.57 CoreMark/MHz. Good baseline for in-order comparison. | Published results |

**Recommendation:** ao486 Dhrystone results are the direct comparison: fabi386's OoO should significantly outperform ao486's in-order on the same x86 ISA. Target >2x improvement. NaxRiscv's 5.02 CoreMark/MHz shows what's achievable with OoO on similar FPGA fabric.

---

## SUMMARY MATRIX

Quick-reference: which reference to consult for each fabi386 feature.

| fabi386 Feature | Primary Reference | Secondary References |
|-----------------|-------------------|---------------------|
| Register rename | **RSD** (RetirementRMT) | BOOM (per-branch snapshots), Toooba (Ehr) |
| ROB | **RSD** (ActiveList) | BOOM (banked, separate PC file) |
| Issue queue | **RSD** (SourceCAM wakeup) | BOOM (split by class, collapsing) |
| Dual-issue dispatch | **RSD** (2-wide) | BOOM (1-4 wide) |
| Mispredict recovery | **RSD** (RetirementRMT) | BOOM (snapshots), Toooba (SpecBits) |
| Bimodal predictor | **mor1kx** (sat counter) | VexRiscv (2-bit BHT) |
| Gshare predictor | **RSD** (10-bit, multi-bank) | mor1kx (Verilog), NaxRiscv (24-bit) |
| Hybrid / TAGE | **BOOM** (TAGE) | mor1kx (hierarchy) |
| Return Address Stack | **BOOM** (speculative RAS) | RSD (integrated RAS) |
| x86 fetch/prefetch | **ao486_MiSTer** (prefetch FIFO) | ao486_original |
| x86 decode | **ao486_original** (78 commands) | ao486_MiSTer (autogen), 80x86 (FSM) |
| Microcode ROM | **ao486_original** (command files) | 80x86 (templates), ao486_MiSTer (autogen) |
| Integer ALU | **RSD** (dual ALU) | 80x86 (x86 flags), ao486 (EFLAGS) |
| x87 FPU | **mor1kx** (pfpu32 pipelined) | RSD (FP pipeline integration) |
| SIMD unit | **VexRiscv** (CfuPlugin) | *(unique to fabi386)* |
| Multiply/Divide | **zipcpu** (configurable, verified) | 80x86 (x86 division), RSD (OoO integration) |
| L1 cache | **RSD** (non-blocking, MSHR) | ao486 (x86-specific), NaxRiscv (spec hit) |
| L2 cache | **ao486_MiSTer** (VGA shared) | Toooba (multi-level) |
| TLB / MMU | **ao486_original** (x86 page walk) | Toooba (2-level), NaxRiscv (2-level) |
| Load-Store Queue | **RSD** (LQ+SQ+mem dep pred) | BOOM (split), Toooba (TSO) |
| Bus snoop / DMA | **mor1kx** (snoop port) | Toooba (MESI) |
| PC peripherals | **ao486_MiSTer** (complete set) | zet (PIT/PIC), zipcpu (verified) |
| VGA / SVGA | **ao486_MiSTer** (VGA+L2) | zet (FML graphics path) |
| Sound / OPL3 | **ao486_MiSTer** (SB16+OPL3) | — |
| IDE / Storage | **ao486_MiSTer** (IDE+SD) | zipcpu (verified DMA) |
| MiSTer integration | **ao486_MiSTer** (complete) | — |
| FPGA RAM primitives | **RSD** (Block/Dist RAM) | VexRiscv (sync/async options) |
| Shadow stack | *(unique)* | BOOM (snapshots concept) |
| Guard unit | *(unique)* | Toooba (SSITH security) |
| Semantic tagger | *(unique)* | — |
| Debug unit | **VexRiscv** (JTAG/GDB) | RSD (Konata visualization) |
| Telemetry / trace | **Toooba** (tandem verify) | — |
| Formal verification | **zipcpu** (40 .sby suites) | mor1kx (FPU proofs) |
| ISA validation | **ao486_original** (Bochs) | 80x86 (C++ model), Toooba (tandem) |
| Simulation | **80x86** (Verilator+Docker) | RSD (Konata viz) |
| Random testing | **VexRiscv** (config fuzz) | BOOM (config sweep) |
| Build / synthesis | **ao486_MiSTer** (Quartus) | zet (multi-board) |
| Parameterization | **RSD** (MicroArchConf) | BOOM (config mixins), mor1kx (FEATURE_*) |
| Documentation | **BOOM** (RST docs) | — |
| Benchmarking | **ao486_original** (Dhrystone) | NaxRiscv (CoreMark), BOOM (IPC) |
