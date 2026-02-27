# fabi386: Host-to-Hardware Debug Bridge

Defines how a software debugger running on the fabi386 host CPU interfaces with the
out-of-band FPGA debug hardware.

## 1. The "fabi386-MSR" Interface

The host CPU accesses the Debug Unit through custom Model Specific Registers (MSRs),
accessed via `RDMSR` and `WRMSR` instructions (i486/Pentium feature, backported to fabi386).

| MSR Index    | Name              | Function                                          |
|--------------|-------------------|---------------------------------------------------|
| `0xC0001000` | `F386_DBG_CTL`    | Global Enable, Unlock Key, and Stealth Mode Toggle|
| `0xC0001001` | `F386_TRIG_PC0`   | Hardware Breakpoint 0 Address                     |
| `0xC0001002` | `F386_TRIG_PC1`   | Hardware Breakpoint 1 Address                     |
| `0xC0001010` | `F386_WATCH_ADDR` | Watchpoint Address Target                         |

> **Note:** These MSR addresses differ from the Supervisor MSR Specification (v1.0) which
> places `GUARD_CTL` at `0xC0001000` and debug registers at `0xC0001010–0xC0001015`.
> This document may represent an earlier revision. The MSR file RTL (`f386_msr_file.sv`)
> follows the v1.0 spec.

## 2. The "Stealth" Operation

To prevent malware from detecting the hardware debugger, the bridge implements
**Selective Transparency:**

- **Stealth ON:** `RDMSR` instructions for fabi386-MSRs return 0 or cause a General
  Protection Fault (`#GP`) unless the Hardware Unlock Key has been written to `F386_DBG_CTL`.
- **External Priority:** If the fabi386 Console (UART) is actively debugging the system,
  it can "Override" host-side requests, preventing a compromised OS from disabling its
  own surveillance.

## 3. Use Case: The "fabi386-Aware" GDB Stub

A Linux kernel developer can implement a driver that talks to these MSRs:

1. The developer sets a hardware watchpoint on a kernel structure via a standard GDB command.
2. The kernel driver translates this into a `WRMSR` to the FPGA logic.
3. When the hardware trigger hits, the FPGA asserts `debug_irq`.
4. The CPU receives a custom interrupt (e.g., `INT 62h`), and the host debugger takes control.

## 4. Advantages over Standard x86 Debugging

- **Unlimited Watchpoints:** Standard x86 only has 4 DR registers; the FPGA can be
  reconfigured to support dozens of triggers if the transistor budget allows.
- **Semantic Triggers:** The host can set a breakpoint that only fires if a specific
  Semantic Tag is present (e.g., "Break only when entering a function in the BIOS ROM").
- **Bus Master Awareness:** The host debugger can be notified if a Bus Master (DMA)
  touches a specific memory range -- impossible with standard DR registers.
