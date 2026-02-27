# fabi386: Shadow-Packing & PASC Mockups

Visualizes the transformation of the Upper Memory Area (UMA) through hardware-assisted
remapping and the identification of physical adapter memory.

## 1. UMA Reconstruction (The "Swiss Cheese" Problem)

Fragmentation prevents large drivers (like network stacks) from loading into UMBs.
Hardware Shadow-Packing compacts scattered ROM regions into contiguous HyperRAM-backed
blocks, freeing up UMA space.

## 2. PASC Diagnostics Console (UART Output)

Mockup of `f386_pasc_classifier` in action, with Bus Master Tracking via `f386_snoop_engine`.

```
fabi386 Console v5.0 (AAR + Snoop Enabled)
> monitor bus-mastering

[EVENT] HLDA Asserted: ISA Master #1 (DMA Channel 2)
[SNOOP] Write detected at 0x0001:4200 (Size: 2048 bytes)
[ACTION] Invalidating L1 Cache Line... SUCCESS.
[ACTION] Syncing HyperRAM Shadow... SUCCESS.

> show coherency-map
[00000000 - 0009FFFF] MODE: SNOOPED   | Source: Motherboard SIMMs
[000A0000 - 000BFFFF] MODE: UNCACHED  | Source: Integrated SVGA
[000C0000 - 000EFFFF] MODE: SNOOPED   | Source: Compacted UMBs
[000F0000 - 000FFFFF] MODE: READ_ONLY | Source: Shadowed BIOS
```

## 3. Real-Mode Memory Shield (Runtime Monitor)

The "Guard Unit" (`f386_guard_unit`) prevents rogue DOS programs from jumping into
protected BIOS regions. Violations trigger `INT 60h`.

## 4. DMA Collision Alert

The Snoop Engine detects when two masters are fighting for the same memory -- a common
issue in legacy SCSI/Sound card setups.

```
!!! F386-BUS-CONTENTION ALERT !!!
[ADDR]  0x000D0000
[STATE] Internal Shadow (HyperRAM) != External Bus (ISA)
[CAUSE] External Master wrote to address while fabi386-IDE DMA was active.
[FIX]   fabi386 Supervisor: Auto-stalling ISA Master until DMA completion.
```

## Module Mapping

| Console Feature       | RTL Module              | Description                           |
|-----------------------|-------------------------|---------------------------------------|
| `monitor bus-mastering` | `f386_snoop_engine`   | HLDA/ADS#/WR# monitoring             |
| `show coherency-map`   | `f386_pasc_classifier`| Latency-based memory classification   |
| Guard violation alert  | `f386_guard_unit`      | PC range enforcement via MSR          |
| DMA collision detect   | `f386_snoop_engine`    | Multi-master contention detection     |
