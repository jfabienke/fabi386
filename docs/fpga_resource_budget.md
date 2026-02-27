# fabi386 FPGA Resource Utilization Budget

| Domain             | LUTs (Logic) | BRAM (18Kb) | DSP (18x18) | Status                        |
|--------------------|--------------|-------------|-------------|-------------------------------|
| OoO Core & P7      | 32,700       | 24          | 4           | LOCKED                        |
| L2 Cache (128KB)   | 1,400        | 64          | 0           | NEW (Uses BRAM for Data/Tags) |
| BTB (4096-entry)   | 600          | 12          | 0           | NEW (Uses BRAM for Targets)   |
| Audio DSP (OPL3)   | 850          | 4           | 48          | NEW (Uses DSP Slices)         |
| Ultra-RE Suite     | 10,450       | 60          | 0           | LOCKED                        |
| SVGA & Accel       | 11,550       | 6           | 8           | LOCKED                        |
| PnR Buffer         | ~5,500       | —           | —           | HEALTHY                       |

## Totals (estimated)

- **LUTs:** ~63,000 used + ~5,500 PnR buffer
- **BRAM (18Kb):** 170 blocks
- **DSP (18x18):** 60 slices

## Notes

- **LOCKED** domains have finalized resource allocations.
- **NEW** domains were added leveraging BRAM and DSP slices to minimize LUT pressure.
- **PnR Buffer** represents remaining headroom for place-and-route flexibility.
- Resource counts use generic FPGA primitives (LUTs, 18Kb BRAM blocks, 18x18 DSP slices).
  Target any FPGA with sufficient capacity (~68K+ LUTs, 170+ BRAM, 60+ DSP).
