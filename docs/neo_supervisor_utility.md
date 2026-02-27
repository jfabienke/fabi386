# fabi386 Supervisor Utility (FABI.EXE)

A DOS-based command-line tool to manage the fabi386 hardware features at runtime.

**Usage:** `FABI [COMMAND] [PARAMS]`

## Commands

| Command | Parameter                  | Description                                                        |
|---------|----------------------------|--------------------------------------------------------------------|
| GUARD   | ON/OFF [START] [END]       | Toggle Hardware Guard Unit on a specific memory range.             |
| REMAP   | [GATE] [SRC] [DEST] [LEN] | Manually program an MMU Shadow Gate for ROM relocation.            |
| STATS   | [ADDR]                     | Display Hardware Invocation Count and Heat for a specific address. |
| SCAN    | -                          | Run a PASC scan to identify hidden "Memory Holes" or SRAM buffers.|
| DEBUG   | BP [0-3] [ADDR]            | Set an "Invisible" Hardware Breakpoint via the OOB Engine.         |

## Example Scenarios

### 1. Sandboxing a Suspicious Driver

```
C:\> FABI GUARD ON 1000:0000 1000:FFFF
```

Enables the Hardware Guard Unit for the segment 1000h. If the driver attempts to execute
code outside this 64KB block, the fabi386 will trigger a hardware trap (INT 60h).

### 2. Identifying a Sound Card Buffer

```
C:\> FABI SCAN

[fabi386 PASC Scan Results]
00000000-0009FFFF : CLASS_INTERNAL (System RAM)
000A0000-000BFFFF : CLASS_ADPT_MEM (VGA VRAM)
000D0000-000D07FF : CLASS_ADPT_MEM (NEW! Found SRAM at D000:0000)
000D0800-000EFFFF : CLASS_HOLE (Available for UMB)
```

### 3. Setting an Invisible Breakpoint

```
C:\> FABI DEBUG BP 0 0010:0500
```

Sets a hardware breakpoint at function entry. Unlike software debuggers, the 0xCC
instruction is not used, making it invisible to anti-debug checks.
