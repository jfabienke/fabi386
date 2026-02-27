# fabi386: Debugging & Introspection Protocol

The fabi386 offers a tiered debugging experience that bridges the gap between a hardware
logic analyzer and a software debugger.

## 1. The "Invisible" Breakpoint

Unlike the standard x86 `INT 3` (`0xCC`), fabi386 breakpoints are handled by the HDU
in the FPGA fabric.

- **Non-Intrusive:** The binary is not modified. No `CC` bytes are inserted into the code.
- **Anti-Anti-Debug:** Software cannot detect the breakpoint by checksumming its own code
  or checking interrupt vectors.
- **Complex Triggers:** Break when `PC == 0x1234 AND EAX > 0x55`.

## 2. Time-Travel Debugging (Rewind)

Since the HyperRAM Trace Buffer (256MB) records every instruction and memory access,
the developer can "Rewind" the system state.

- **Post-Mortem Analysis:** If the system crashes, the developer can inspect the last
  ~10 million instructions leading up to the fault.
- **State Reconstruction:** The fabi386 Console can reconstruct the General Purpose
  Registers (GPRs) at any point in the historical trace.

## 3. Real-Time Variable Inspection

The Data Probe acts as a background "Memory Inspector."

- **Global Watch:** Monitor a specific DOS memory variable (e.g., the Tick Counter at
  `0040:006C`) without slowing down the CPU.
- **I/O Sniffing:** Watch every byte sent to the Sound Blaster or VGA controller in a
  dedicated scrolling window on the fabi386 Console.

## 4. Forced Step Control

The supervisor can take manual control of the instruction retirement engine.

- **Single Step:** Retire exactly one instruction and freeze.
- **N-Step:** Retire X instructions (e.g., "Run for 1000 cycles and stop").
- **Semantic Step:** Run until the next `SEM_PROLOGUE` (step into next function) or
  `SEM_EPILOGUE` (step out of current function).

## 5. Summary of Debug Commands (fabi386 Console)

| Command                    | Description                                            |
|----------------------------|--------------------------------------------------------|
| `break pc <addr>`          | Set invisible hardware breakpoint.                     |
| `watch addr <addr> [val]`  | Set data watchpoint (optional value match).            |
| `trace start/stop`         | Toggle the HyperRAM circular trace buffer.             |
| `rewind <instr_count>`     | Move the "Virtual EIP" back in time.                   |
| `step [n]`                 | Execute N instructions and freeze.                     |
| `inspect gpr`              | Dump registers from the hardware shadow registers.     |
