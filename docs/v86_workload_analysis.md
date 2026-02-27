# fabi386: V86 & 32-bit Workload Analysis (v2.5)

Updated to reflect the "Primary Usage Profile": DOS running in V86-mode
(under Windows/OS-2) and modern 32-bit Protected Mode OSes.

## 1. The V86 Transition (Primary Workload A)

In V86 mode, the processor executes 16-bit code but uses the paging and protection
mechanisms of 32-bit mode. The fabi386 optimizes the frequent "Traps" to the monitor.

### Hardware-Accelerated Trapping

- **Context:** DOS programs frequently use INT 21h or direct I/O.
- **The Problem:** Standard 486s force a full context switch to the hypervisor for every
  trapped operation, killing performance.
- **fabi386 Solution:** The AAR Engine identifies "Safe Traps" (e.g., non-destructive I/O
  reads like VGA Status 0x3DA) and handles them with a Fast-Path Micro-op, bypassing the
  full OS context switch when possible.

## 2. 32-bit Performance (Primary Workload B)

For Windows 95, Linux, and NetBSD, the Phase 7 OoO Engine is at peak efficiency.

| OS Class       | Mode          | fabi386 Optimization                                                                                          |
|----------------|---------------|---------------------------------------------------------------------------------------------------------------|
| Windows 9x     | Hybrid 16/32  | The Return Address Stack (RAS) prevents stalls during frequent Thunking (switching between 16-bit and 32-bit) |
| Linux / BSD    | Flat 32-bit   | Register Renaming eliminates stalls in tight C-compiled loops common in kernel schedulers                     |
| DOS Extenders  | Protected 32  | Stride Detection optimizes high-speed memory moves used in 32-bit DOS games (Doom, Quake)                    |

## 3. Ghidra UI: The "V86 Overlay" View

Since users are primarily in V86, the Ghidra plugin defaults to an Interleaved View:

- **Soft Purple (Guest):** Highlights the 16-bit DOS application logic.
- **Bright Cyan (Host):** Highlights the 32-bit Windows/Hypervisor kernel handling the V86 guest.
- **Trace Linking:** The AAR engine "links" a guest I/O write (e.g., to 0x220) directly to
  the host's emulation routine, allowing you to see the "Logic Bridge" in real-time.

## 4. Hardware Integrity in Primary Modes

- **Shadow Stack:** Independent stacks are maintained for the Guest (V86) and Host (PM).
  This allows for Cross-Mode Stack Integrity, detecting if a DOS guest attempts to "smash"
  its way into the 32-bit Host kernel.
- **PASC Classification:** In 32-bit mode, the Address Classifier helps the OS identify
  which physical memory regions are high-speed internal HyperRAM versus slow external adapter
  memory, allowing for more intelligent `malloc()` allocation.

## 5. Conclusion

By focusing on V86 and 32-bit Protected Mode, the fabi386 delivers a "snappy" experience
that exceeds period-accurate hardware. The architecture treats "Pure Real Mode" as a mere
bootloader phase, focusing all 150MHz of its power on the environments where users actually live.
