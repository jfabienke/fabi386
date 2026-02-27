# fabi386: Supervisor Runtime Instrumentation

Outlines how a "fabi386-Aware" Operating System or Protected-Mode Hypervisor utilizes
the Ultra-RE hardware suite.

## 1. Real-Time Security (Hardware IDS)

The Shadow Stack provides primary security gating, preventing ROP attacks.
Hardware `stack_fault` signals trigger `INT 61h` for immediate exploit prevention.

## 6. Real-Mode Memory Shield (Sandboxing DOS)

Standard 386 Real Mode has zero protection. The fabi386 introduces Hardware Allow-Lists
via the Guard Unit (`f386_guard_unit`), enforcing execution boundaries even without paging.

## 9. V86-Mode Hypervisor Debugging

Hardware-accelerated support for V86-Mode Monitors (Hypervisors).

### The "Invisible" Debugger

When running DOS programs in V86-mode, the fabi386 provides the hypervisor with a
"God-View" of the guest:

- **V86-State Tagging:** The hardware automatically tags telemetry packets with the VM
  (Virtual 8086) bit from the EFLAGS register (`f386_v86_monitor`).
- **I/O Trapping Context:** When a V86 guest triggers a `#GP(0)` by accessing a protected
  port, the AAR engine captures the 1024-cycle I/O history preceding the trap.
- **Guest Memory Isolation:** The Hardware Guard Unit can be programmed to enforce strict
  boundaries for a V86 task, ensuring it never touches the Hypervisor's memory space,
  even if the CPU's standard paging is bypassed.

### Virtual Device Profiling

The hypervisor can use the Temporal Sequencer to profile how a V86 DOS app communicates
with a virtualized device.

- **Scenario:** A DOS game writes to a "Virtual Sound Blaster."
- **Action:** The hardware groups these writes into a Transaction Block, providing the
  hypervisor with the exact timing needed to emulate the hardware latency correctly,
  preventing "Audio Stutter" common in early emulators.

## Summary: The "fabi386-Aware" OS

| Hardware Signal   | Supervisor Action      | Result                          |
|-------------------|------------------------|---------------------------------|
| `stack_fault`     | Raise `#GP` / Panic    | Instant Exploit Prevention      |
| `guard_fault`     | Terminate V86 Guest    | V86 Sandbox Security            |
| `SEM_V86_ENTER`   | Load Guest Context     | Hypervisor Context Switching    |
| `SEM_V86_EXIT`    | Save Guest Context     | Host Intercept Logging          |

## RTL Module Mapping

| Feature                    | Module                   | Interrupt Vector |
|----------------------------|--------------------------|------------------|
| Shadow Stack fault         | `f386_aar_engine`        | `INT 61h`        |
| Guard Unit violation       | `f386_guard_unit`        | `INT 60h`        |
| V86 mode transitions       | `f386_v86_monitor`       | Semantic tags    |
| Hardware breakpoint hit    | `f386_debug_unit`        | `INT 62h`        |
| Bus master coherency       | `f386_snoop_engine`      | Internal signal  |
