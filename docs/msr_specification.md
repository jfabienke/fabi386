# fabi386: Supervisor MSR Specification (v1.0)

Model Specific Registers (MSRs) allow "fabi386-Aware" software to control the FPGA-level
instrumentation logic. These are accessed using `RDMSR` and `WRMSR` instructions.

## 1. Security & Guarding Registers

| MSR Index    | Name             | Bitfield Description                                           |
|--------------|------------------|----------------------------------------------------------------|
| `0xC0001000` | `F386_GUARD_CTL` | [63:33] Reserved, [32] Enable, [31:0] Safe Range Start PC.    |
| `0xC0001001` | `F386_GUARD_END` | [63:32] Reserved, [31:0] Safe Range End PC.                    |

**Behavior:** When Enable is set, any instruction fetch outside the Start→End range
(that isn't a known BIOS call) triggers a hardware trap.

## 2. Telemetry & Thermal Registers

| MSR Index    | Name             | Bitfield Description                                                       |
|--------------|------------------|----------------------------------------------------------------------------|
| `0xC0001002` | `F386_RE_CTL`    | [63:33] Reserved, [32] Telemetry Global Enable, [31:0] Thermal Map Base Addr. |

**Behavior:** Configures where the 4-bit-per-byte execution heatmap is stored in HyperRAM.

## 3. Host-Side Debugging Registers

| MSR Index    | Name              | Bitfield Description                               |
|--------------|-------------------|-----------------------------------------------------|
| `0xC0001010` | `F386_DBG_UNLOCK` | Write `0xDEADBEEF` to unlock host-side debug control. |
| `0xC0001011` | `F386_TRIG_PC0`   | Hardware Breakpoint 0 Target PC.                    |
| `0xC0001012` | `F386_TRIG_PC1`   | Hardware Breakpoint 1 Target PC.                    |
| `0xC0001015` | `F386_DBG_EN`     | [3:0] Enable bits for Breakpoints 0–3.              |

**Behavior:** Allows a Protected-Mode debugger to set "Invisible" hardware breakpoints
that standard guest code cannot detect or disable.

## 4. MMU Remap Gates

| MSR Index        | Name                 | Bitfield Description                        |
|------------------|----------------------|----------------------------------------------|
| `0xC0002000`     | `F386_MMU_REMAP[0]` | Gate 0 Start Address + [32] Enable           |
| `0xC0002001`     | `F386_MMU_REMAP[1]` | Gate 0 End Address                           |
| `0xC0002002`     | `F386_MMU_REMAP[2]` | Gate 0 HyperRAM Physical Offset              |
| `0xC0002003+`    | `F386_MMU_REMAP[n]` | Additional gates (3 MSRs per gate)           |

**Behavior:** Redirects UMA ROM ranges into high-speed HyperRAM for Shadow-Packing.

## 5. Hardware Trap Vectors

When a violation occurs, the fabi386 injects a custom interrupt into the execution stream:

| Vector   | Name                      | Trigger                              |
|----------|---------------------------|--------------------------------------|
| `INT 60h`| Hardware Guard Violation   | Program escaped sandbox.             |
| `INT 61h`| Shadow Stack Fault         | Potential ROP exploit.               |
| `INT 62h`| Hardware Debug Trigger     | Breakpoint hit.                      |
