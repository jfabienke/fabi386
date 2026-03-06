
# ETX Display Engine Architecture
Version: 1.0 (Expanded Draft)

Author: Project Architecture Draft
Target Platform: FPGA-based SVGA / VBE Engine (MiSTer-compatible)
Document Type: Architectural Design Specification

---

# 1. Introduction

## 1.1 Purpose

This document specifies the **ETX display engine** architecture used in the FPGA video subsystem.  
The design provides a **VGA-compatible text mode baseline** and a **tile-based graphics rendering pipeline** for SVGA/VBE/AF-class operation, including:

- multiple font banks
- RAM-based fonts
- planar glyph formats
- hardware cursor layers
- programmable effects
- smooth scrolling
- Unicode glyph caching
- programmable palette and rendering formats
- hardware-accelerated 2D graphics/blit operations
- tile-based deferred compositing
- alpha cursor/overlay composition

The system is designed to maintain compatibility with **classic DOS software** while providing a **modern programmable display pipeline** suitable for advanced UI, diagnostics, and hybrid text/graphics environments.

---

# 2. Design Goals

The ETX architecture is guided by the following core principles.

### 2.1 VGA Compatibility

The engine must support legacy text-mode software expectations:

- Mode 03h compatibility
- B8000h / B0000h text memory access
- INT 10h cursor semantics
- attribute byte interpretation
- character-cell addressing

This ensures compatibility with:

- DOS boot messages
- BIOS output
- debuggers
- installers
- early OS loaders

### 2.2 Programmable Text Rendering

The architecture must support advanced features without sacrificing determinism:

- per-character styling
- font substitution
- hardware effects
- scalable cell geometry
- Unicode glyph mapping

### 2.3 Deterministic Scanout

Rendering must occur in a predictable pipeline that:

- does not stall scanout
- avoids frame underruns
- allows bounded memory latency

### 2.4 Feature Discovery

Software must be able to probe capabilities via hardware registers.

### 2.5 Monitor Mode Coverage

The ETX engine must operate correctly across all video timings exposed by the
platform video pipeline (legacy VGA timings and modern VESA/HDMI modes).

Key requirement:

- text rendering logic must be timing-agnostic
- mode timing (active area, porches, sync) is provided by display timing logic
- ETX consumes only the active pixel region contract

### 2.6 Variable Font Size Support

The engine must support runtime-selectable character-cell geometry per mode.

Minimum requirements:

- variable cell width and height
- font bank selection independent of display mode
- deterministic layout recompute on mode/font change
- fallback behavior if chosen geometry cannot fill the target mode cleanly

---

# 3. System Architecture Overview

The ETX subsystem consists of several cooperating components:

```
                +-----------------------+
                |  Text Surface Memory  |
                +-----------+-----------+
                            |
                            v
                +-----------------------+
                | Cell Decode Stage     |
                +-----------+-----------+
                            |
                            v
                +-----------------------+
                | Font Fetch / RAMFont  |
                +-----------+-----------+
                            |
                            v
                +-----------------------+
                | Glyph Pipeline        |
                | (effects & transforms)|
                +-----------+-----------+
                            |
                            v
                +-----------------------+
                | Cursor Overlay        |
                +-----------+-----------+
                            |
                            v
                +-----------------------+
                | Final Compositor      |
                +-----------------------+
```

This pipeline executes per scanline and is designed for deterministic latency.

---

# 4. Address Space Layout

The ETX subsystem exposes a memory-mapped register block.

| Range | Function |
|------|----------|
|0x0000–0x00FF|Global registers and capabilities|
|0x0100–0x01FF|Surface configuration|
|0x0200–0x02FF|Font system|
|0x0300–0x03FF|Cursor system|
|0x0400–0x04FF|Effect system|
|0x0500–0x05FF|Special features|
|0x0600–0x06FF|Counters and telemetry|

Registers are **little-endian**.

---

# 5. Capability Discovery

## 5.1 Capability Registers

Capability registers allow software to dynamically detect available functionality.

### CAP0

Primary feature flags.

|Bit|Feature|
|---|-------|
|0|VGA baseline support|
|1|Extended surface formats|
|2|Multiple font banks|
|3|RAMFont descriptors|
|4|Planar glyph rendering|
|5|Anti-aliased glyph support|
|6|Basic effects|
|7|Advanced effects|
|8|Multiple cursors|
|9|Smooth scrolling|
|10|Circular text surfaces|
|11|Box drawing acceleration|
|12|Proportional text mode|
|13|Text-to-graphics rendering|
|14|Palette animation|
|15|Per-scanline effects|

### CAP1

Hardware limits including:

- maximum cursors
- maximum fonts
- RAMFont capacity
- Unicode cache size
- L1 concurrent hot glyph capacity (v1 target: 1024)
- L2 glyph pool capacity (target range: 4096-8192)
- guaranteed min/max cell width and cell height
- optional extended min/max cell width and cell height

## 5.2 Recommended Capability Limit Fields

For software discoverability and tests, expose concrete ETX limits:

- `CAPL_GLYPH_L1_MAX_ACTIVE` (recommended v1 value: `1024`)
- `CAPL_GLYPH_L2_POOL_MAX` (recommended v1 minimum: `4096`, preferred `8192`)
- `CAPL_CELL_W_MIN_GUAR`, `CAPL_CELL_W_MAX_GUAR`
- `CAPL_CELL_H_MIN_GUAR`, `CAPL_CELL_H_MAX_GUAR`
- `CAPL_CELL_W_MIN_EXT`, `CAPL_CELL_W_MAX_EXT` (optional)
- `CAPL_CELL_H_MIN_EXT`, `CAPL_CELL_H_MAX_EXT` (optional)

---

# 6. Surface Model

The text engine renders from **text surfaces** stored in system memory.

## 6.1 Surface Parameters

Each surface defines:

- base address
- row stride
- column count
- row count
- cell format
- cell width/height (or reference to active font geometry)

Surfaces may be mapped anywhere in system memory.

## 6.2 Mode-Derived Layout

For each active display mode:

- `cols = floor(h_active / cell_width)`
- `rows = floor(v_active / cell_height)`

Safety constraints:

- `h_active >= cell_width`
- `v_active >= cell_height`

Any remainder region is handled by policy:

- clip (default)
- center with margins
- pad with background color

This allows one text engine to run on multiple monitor modes without changing
the scanout timing generator.

## 6.3 Surface Formats

The ETX engine supports multiple cell layouts.

### VGA8

Standard VGA layout.

```
byte 0: character
byte 1: attribute
```

### EXT16

Four-byte extended cell.

```
glyph_id
palette_index
effect_flags
```

### RGBA32

Eight-byte direct color format.

```
glyph_id
effects
RGBA color
```

### ATTR24 + FX

Used for advanced rendering pipelines.

```
glyph_id
RGB attributes
effect flags
```

---

# 7. Palette System

Palette memory stores color definitions.

Supported formats include:

- RGB565
- RGB888
- RGBA8888

Palette animation allows smooth transitions between color sets.

---

# 8. Font System

## 8.1 Font Banks

Up to eight resident font banks allow rapid switching.

Typical uses:

- CP437
- CP850
- alternate glyph sets
- debugging overlays

## 8.1.1 Variable Font Geometry

Font banks may have independent geometry.

Tiered support contract:

- guaranteed (v1): width 8-16 pixels, height 8-32 pixels
- optional (extended): width 4-32 pixels, height 6-64 pixels

Geometry limits must be discoverable via CAP1 limit fields.

Common presets:

- 8x8, 8x14, 8x16 (legacy compatible)
- 9x16 (optional VGA-style widened box drawing)
- 12x24, 16x32 (high-DPI readability)

## 8.2 RAMFont Architecture

RAMFont descriptors enable dynamic fonts stored in memory.

Each descriptor contains:

- glyph base address
- glyph count
- geometry information
- glyph format
- optional width table

Supported glyph formats:

- MONO1
- PLANAR4
- AA2
- AA4

RAMFont descriptors must include explicit `glyph_width` and `glyph_height`
fields so dynamic fonts are not constrained to legacy VGA sizes.

RAMFont geometry overrides bank geometry when both are present.

## 8.3 Unicode Glyph Cache

A glyph cache stored in SDRAM enables mapping Unicode codepoints to glyph IDs.

Software manages cache population.

## 8.4 Glyph Cache Policy

Recommended cache hierarchy:

- L1 glyph cache in FPGA BRAM (hot glyphs, low latency)
- L2 glyph store in SDRAM (full RAMFont backing store)

Reference flow:

`glyph_id -> L1 lookup -> (miss) -> L2 fetch -> L1 insert -> render`

Suggested initial sizing:

- L1 BRAM cache: 512-1024 glyphs (recommended)
- L2 SDRAM glyph pool: 4096-8192 glyphs (recommended)
- replacement: pseudo-LRU or round-robin (implementation choice)

## 8.5 Working-Set Sizing and Capacity Targets

Maximum on-screen cell count from section 20.7:

- `240 x 135 = 32,400` cells (1920x1080 with 8x8 geometry)

Important distinction:

- cell count is not glyph working-set size
- cache pressure is driven by distinct glyph IDs active concurrently

Typical distinct-glyph working sets:

- DOS/BIOS/terminal ASCII+CP437: about 80-256
- rich UI text + symbols/box drawing: about 200-300
- multilingual UI: about 500-1000
- extreme mixed content: about 1500-2000

Design target for ETX:

- concurrently active working set budget: about 512-1024 glyphs
- RAMFont pool budget: 4096-8192 glyphs

v1 capability lock (recommended):

- advertise `L1_HOT_GLYPHS_MAX = 1024` in capability limits
- advertise `L2_GLYPH_POOL_MAX` per build (minimum 4096 target)

## 8.6 Glyph Storage Cost Reference

Example geometry: `16x32`.

- 1bpp glyph: `16*32 = 512 bits = 64 bytes`
- 4-plane glyph: `256 bytes`

| Glyph Count | 1bpp Storage | 4-plane Storage |
|-------------|--------------|-----------------|
| 256 | 16 KB | 64 KB |
| 512 | 32 KB | 128 KB |
| 1024 | 64 KB | 256 KB |
| 4096 | 256 KB | 1 MB |

These capacities are practical for SDRAM-backed RAMFont storage.

---

# 9. Effects Engine

The effects engine applies transformations during glyph rendering.

## 9.1 Basic Effects

- Bold
- Italic
- Underline
- Overline
- Strikethrough

## 9.2 Advanced Effects

- Shadow
- Outline
- Glow
- Emboss

These effects may be parameterized through a style table.

---

# 10. Cursor System

The ETX engine supports up to **four concurrent cursors**.

Cursor styles include:

- underline
- block
- I-beam
- box
- custom bitmap

Each cursor may independently control:

- position
- blink rate
- alpha fade
- shape parameters

---

# 11. Smooth Scrolling

Smooth scrolling allows sub-character vertical movement.

Key features:

- scanline-level offsets
- circular surface buffers
- optional momentum-based scrolling

This allows terminal-like or UI scrolling behavior.

Mode/font changes must atomically reset scroll phase to avoid row tearing.

## 11.1 Scroll Coordinate Precision

Required minimum:

- `SCROLL_Y_SUB` range: `0..(CELL_H-1)` (integer scanline phase)

Optional extension:

- fixed-point scroll accumulator (e.g. `SCROLL_Y_FP` as 8.8 format)
- integer part controls row advance; fractional part controls sub-row phase

---

# 12. Box Drawing Acceleration

Characters in the range **0xB0–0xDF** may be rendered algorithmically.

Benefits:

- crisp scalable box drawing
- reduced font storage
- improved appearance at larger cell sizes

---

# 13. Proportional Mode

Optional proportional rendering allows variable-width characters.

Implementation requires:

- glyph width tables
- layout adjustments
- scanline positioning logic

Proportional mode is not required for VGA compatibility.

---

# 14. Effects Pipeline

Rendering effects occur in a defined order.

1. geometry transforms
2. bold weight transform
3. decorations
4. outline
5. emboss
6. shadow
7. glow
8. cursor overlay
9. final compositing

Maintaining this order guarantees deterministic results.

Rule: decorations (underline/overline/strikethrough) operate in final scaled
space, not source glyph space.

---

# 15. Robustness and Fault Handling

Hardware must avoid catastrophic failure.

If unsupported features are requested:

- ignore safely
- set fault flag
- continue rendering baseline output

PANIC_TEXT_MODE must always restore a readable display.

---

# 16. Performance Counters

The ETX engine provides counters for monitoring:

- frames rendered
- cache misses
- scanout underruns
- font cache usage
- vblank events
- mode changes
- font geometry switches
- layout recompute cycles
- glyph_fetch_stalls
- cell_decode_stalls

These counters aid debugging and optimization.

---

# 17. Implementation Roadmap

Suggested staged implementation:

### Phase 0
- text-mode-only minimal renderer
- fixed 80x25-compatible path
- deterministic scanout and panic-safe fallback

### Phase 1
- VGA compatibility
- CP437 / CP850 font banks
- cursor support
- fixed legacy font sizes (8x16 baseline)

### Phase 2
- extended surfaces
- basic effects
- variable cell geometry (8x8 to 16x32)
- mode-derived layout logic

### Phase 3
- RAMFont descriptors
- Unicode cache
- runtime mode/font switch handshake

### Phase 4
- advanced effects
- multi-cursor

### Phase 5
- smooth scrolling
- per-scanline effects
- text-to-graphics rendering
- high-DPI font presets and proportional-mode tuning

---

# 18. Future Extensions

Potential future enhancements:

- hardware kerning engine
- GPU-style glyph caching
- vector font rasterization
- subpixel text rendering

---

# 19. UTF-8 Decode Block Specification

## 19.1 Goal and Scope

The ETX engine may include a hardware UTF-8 decoder to convert byte streams
into Unicode codepoints before glyph lookup.

This block is intended to accelerate terminal/UI text ingest while keeping
scanout deterministic.

In scope:

- UTF-8 byte sequence decode (1-4 byte sequences)
- validity checks (overlong, surrogate, range)
- codepoint output stream
- replacement handling for invalid sequences

Out of scope:

- Unicode normalization (NFC/NFD/NFKC/NFKD)
- grapheme cluster segmentation
- bidirectional layout
- script shaping (Arabic/Indic)
- font fallback policy

Those remain software responsibilities.

## 19.2 Pipeline Placement

UTF-8 decode must not be on the per-pixel scanout critical path.

Recommended placement:

1. software writes UTF-8 byte stream into text ingest buffer
2. hardware UTF-8 decoder emits codepoints into a codepoint FIFO
3. glyph mapper/cache resolves codepoint -> glyph_id
4. ETX cell surface stores glyph_id + attributes
5. scanout reads pre-decoded cells only

This preserves deterministic scanline timing even under malformed input.

Reference ingest pipeline:

```
CPU / DMA
   ->
UTF-8 Decoder
   ->
Codepoint FIFO
   ->
Glyph Mapper
   ->
Cell Surface
   ->
Scanout
```

## 19.3 Block Interfaces

### Input (byte stream)

- `in_valid`, `in_ready`
- `in_byte[7:0]`
- optional `in_sop` / `in_eop` framing for line/packet boundaries

### Output (codepoint stream)

- `out_valid`, `out_ready`
- `out_cp[20:0]` (Unicode scalar value)
- `out_err` (set when output is replacement for invalid input)
- optional `out_flags` (overlong, surrogate, out-of-range, unexpected-cont)

### Control

- enable/disable decoder
- strict mode vs replacement mode
- counters reset

## 19.4 Decode Rules (Normative)

Accepted lead-byte classes:

- `0x00-0x7F`: single-byte ASCII
- `0xC2-0xDF`: 2-byte sequence
- `0xE0-0xEF`: 3-byte sequence
- `0xF0-0xF4`: 4-byte sequence

Invalid lead bytes:

- `0x80-0xBF` as lead (unexpected continuation)
- `0xC0-0xC1` (overlong forms)
- `0xF5-0xFF` (outside UTF-8 scalar range)

Continuation bytes must be `0x80-0xBF`.

Additional validity constraints:

- reject overlong encodings
- reject surrogate range `U+D800-U+DFFF`
- reject codepoints above `U+10FFFF`

On invalid sequence:

- replacement mode: emit `U+FFFD` and continue at next byte boundary
- strict mode: set sticky fault flag and optionally halt ingest

## 19.5 Decoder FSM

Minimum FSM states:

- `S_IDLE` (expect lead)
- `S_EXP1` (expect 1 continuation)
- `S_EXP2` (expect 2 continuation)
- `S_EXP3` (expect 3 continuation)
- `S_ERR` (optional recovery state)

State tracks:

- expected continuation count
- partial codepoint accumulator
- lead-class constraints for first continuation (for overlong/range checks)

## 19.6 Throughput and Buffering

Target behavior:

- accept up to 1 byte/cycle (`in_valid && in_ready`)
- emit up to 1 codepoint/cycle (`out_valid && out_ready`) when boundary reached

Required buffering:

- input skid buffer: 2-4 bytes
- output FIFO: 16-64 codepoints (depends on glyph mapper latency)

Backpressure:

- deassert `in_ready` when output FIFO near full
- no byte drops permitted in hardware mode

## 19.7 Register and Counter Additions

Recommended register window:

- `0x0700-0x07FF`: UTF-8 decode control/status (new ETX subrange)

Suggested registers:

- `UTF8_CTRL`: enable, strict/replacement mode, soft reset
- `UTF8_STATUS`: active, fault_sticky, fifo levels
- `UTF8_FAULT`: last fault type + byte offset (optional)
- `UTF8_REPL_CP`: replacement codepoint (default `U+FFFD`)

Suggested counters:

- bytes_in
- codepoints_out
- invalid_sequences
- overlong_rejects
- surrogate_rejects
- out_of_range_rejects

## 19.8 Capability Discovery

Add `CAP2` register for ETX extensions:

- bit 0: hardware UTF-8 decoder present
- bit 1: strict mode supported
- bit 2: extended fault counters supported

Software must probe `CAP2` before enabling UTF-8 hardware path.

## 19.9 Estimated FPGA Cost

Rough estimate for Cyclone V implementation:

- decoder control + checks: ~200-600 ALMs
- FIFOs/counters/status: ~150-400 ALMs
- optional fault metadata: ~50-150 ALMs
- M10K usage: 0-2 blocks (if FIFOs implemented in BRAM)

Total expected delta:

- lightweight mode: ~350-700 ALMs
- full diagnostics mode: ~700-1,150 ALMs

This is feasible within projected ETX and memory-fabric headroom.

## 19.10 Verification Requirements

Directed tests must include:

- valid 1/2/3/4-byte sequences
- overlong sequence rejection
- surrogate rejection
- `>U+10FFFF` rejection
- unexpected continuation handling
- backpressure (input stall) behavior
- replacement output correctness (`U+FFFD`)

Formal properties (recommended):

- no output without complete valid sequence or replacement policy trigger
- FSM cannot deadlock on malformed streams
- byte accounting: consumed bytes equal input handshake count

---

# 20. Display Mode and Font-Size Contract

## 20.1 Monitor Mode Support Contract

ETX shall support any mode accepted by the video output path, provided:

- active resolution is within configured max (`H_ACTIVE_MAX`, `V_ACTIVE_MAX`)
- pixel clock is within validated timing closure for ETX scanline pipeline
- line fetch FIFO depth meets worst-case memory latency at target refresh rate

ETX is not responsible for generating sync timings. It consumes:

- `h_active`
- `v_active`
- `frame_start` / `line_start`

from the display timing block.

Timing interface contract (logical bus):

```
etx_timing_if {
    frame_start
    line_start
    pixel_valid
    h_active[15:0]
    v_active[15:0]
}
```

## 20.2 Runtime Mode Switching

Mode switch sequence:

1. software programs pending mode + font geometry
2. hardware latches on next `frame_start`
3. layout (`rows`, `cols`, stride interpretation) updates atomically
4. status bit `MODE_SWITCH_DONE` set

No mid-frame geometry change is permitted.

Handshake semantics:

- writes to mode/font registers during active frame update only shadow
  (`pending_*`) registers
- active timing and layout state change only on next `frame_start`
- `MODE_SWITCH_DONE` is level-sensitive and means:
  - active timing profile is switched
  - layout recompute completed
  - scanout is using new active layout
- software clears `MODE_SWITCH_DONE` via write-1-to-clear before issuing the
  next switch request

## 20.3 Variable Font Policy

Required behavior:

- per-surface or global active font descriptor
- geometry-aware cursor and decorations
- glyph cache invalidation on geometry change

Optional behavior:

- per-region mixed font sizes (deferred feature)

## 20.4 Minimum Register Additions

Recommended registers:

- `MODE_ACTIVE_W`, `MODE_ACTIVE_H`
- `CELL_W`, `CELL_H`
- `LAYOUT_COLS`, `LAYOUT_ROWS` (readback)
- `MODE_SWITCH_CTRL` / `MODE_SWITCH_STATUS`
- `FONT_GEOM_STATUS`

## 20.5 Fallback and Safety

If requested font geometry is not feasible for the current mode:

- clamp to nearest supported geometry, or
- enter safe fallback (8x16), set sticky fault bit

Readable text output must be preserved in all cases.

## 20.6 Mode Validation Matrix (Bring-Up Baseline)

The following monitor modes form the minimum validation set for ETX runtime
mode switching and layout recompute.

| Timing Profile ID | Standard Family | Active Area | Pixel Clock Target | Pixel Clock Range | Validation Scope |
|-------------------|-----------------|-------------|--------------------|-------------------|------------------|
| `ETX_TIM_VGA_640_480_60` | VESA DMT | 640x480 | 25.175 MHz | 25.0-25.35 MHz | required |
| `ETX_TIM_SVGA_800_600_60` | VESA DMT | 800x600 | 40.000 MHz | 39.8-40.2 MHz | required |
| `ETX_TIM_XGA_1024_768_60` | VESA DMT | 1024x768 | 65.000 MHz | 64.7-65.3 MHz | required |
| `ETX_TIM_WXGA_1280_720_60` | CEA-861 | 1280x720 | 74.250 MHz | 73.9-74.6 MHz | required |
| `ETX_TIM_SXGA_1280_1024_60` | VESA DMT | 1280x1024 | 108.000 MHz | 107.5-108.5 MHz | required |
| `ETX_TIM_WXGA_1366_768_60RB` | VESA CVT-RB | 1366x768 | 85.500 MHz | 85.1-85.9 MHz | required |
| `ETX_TIM_HDPLUS_1600_900_60RB` | VESA CVT-RB | 1600x900 | 97.750 MHz | 97.3-98.2 MHz | required |
| `ETX_TIM_FHD_1920_1080_60` | CEA-861 | 1920x1080 | 148.500 MHz | 147.8-149.2 MHz | required |

Note: each `Timing Profile ID` corresponds to a full timing tuple (active,
porches, sync widths, polarity, total pixels/lines), not active area alone.

Per-mode pass criteria:

- mode switch applies atomically at `frame_start`
- `LAYOUT_COLS` and `LAYOUT_ROWS` match floor-division math
- no scanout underrun or stuck `MODE_SWITCH_DONE`
- cursor, scroll window, and glyph fetch stay within computed bounds
- full timing tuple correctness validated per profile class:
  - DMT/CEA profiles must match programmed porches/sync/polarity
  - CVT-RB profiles must match reduced-blanking tuple, not just active area
- `MODE_SWITCH_DONE` behavior:
  - deasserts only via W1C
  - must not glitch low during active scanout

## 20.7 Font Preset Layout Table (Exact Outcomes)

Layout formula:

- `cols = floor(h_active / cell_w)`
- `rows = floor(v_active / cell_h)`
- `rem_x = h_active - cols * cell_w`
- `rem_y = v_active - rows * cell_h`

Cell format in table: `cols x rows (rem_x, rem_y)`.

| Mode | 8x8 | 8x16 | 9x16 | 12x24 | 16x32 |
|------|-----|------|------|-------|-------|
| 640x480 | 80x60 (0,0) | 80x30 (0,0) | 71x30 (1,0) | 53x20 (4,0) | 40x15 (0,0) |
| 800x600 | 100x75 (0,0) | 100x37 (0,8) | 88x37 (8,8) | 66x25 (8,0) | 50x18 (0,24) |
| 1024x768 | 128x96 (0,0) | 128x48 (0,0) | 113x48 (7,0) | 85x32 (4,0) | 64x24 (0,0) |
| 1280x720 | 160x90 (0,0) | 160x45 (0,0) | 142x45 (2,0) | 106x30 (8,0) | 80x22 (0,16) |
| 1280x1024 | 160x128 (0,0) | 160x64 (0,0) | 142x64 (2,0) | 106x42 (8,16) | 80x32 (0,0) |
| 1366x768 | 170x96 (6,0) | 170x48 (6,0) | 151x48 (7,0) | 113x32 (10,0) | 85x24 (6,0) |
| 1600x900 | 200x112 (0,4) | 200x56 (0,4) | 177x56 (7,4) | 133x37 (4,12) | 100x28 (0,4) |
| 1920x1080 | 240x135 (0,0) | 240x67 (0,8) | 213x67 (3,8) | 160x45 (0,0) | 120x33 (0,24) |

Recommended defaults by mode class:

- legacy-centric bring-up: `8x16`
- dense diagnostics/terminal: `8x8`
- high-DPI readability: `12x24` or `16x32`

For non-zero remainders, default policy remains clip-to-active-area with
top-left anchoring unless centering is explicitly enabled.

9x16 note:

- 9x16 is primarily intended for 720-wide active timings (80 columns exact)
- on 640-wide modes, formula-derived result is 71 columns (as shown above)

Remainder-region addressing rule:

- software-visible cell address space is strictly `0..cols-1` by `0..rows-1`
- cursor bounds, scroll-window bounds, and fault checks use computed
  `cols/rows` only
- remainder pixels are not addressable as cells

Surface metadata mismatch policy (firmware-facing):

- if software programs `surface_cols/rows` exceeding computed `LAYOUT_COLS/ROWS`:
  - clamp accesses to computed layout bounds
  - set sticky `LAYOUT_MISMATCH_FAULT`
  - increment `layout_mismatch_count`
- if programmed stride is too small for computed visible rows:
  - reject activation of pending mode/surface
  - keep previous active configuration
  - set sticky `SURFACE_STRIDE_FAULT`

---

# 21. Memory Bandwidth Budget (Planning)

This section provides first-order bandwidth estimates for capacity planning.

## 21.1 Example: 1920x1080 @ 60 Hz, 8x16 cells

From section 20.7 table:

- `cols x rows = 240 x 67 = 16,080 cells/frame`

Cell surface read bandwidth (VGA8, 2 bytes/cell):

- `16,080 * 2 = 32,160 bytes/frame`
- `32,160 * 60 = 1.93 MB/s`

Monochrome glyph row traffic estimate (8x16, 16 bytes/glyph, no reuse):

- `16,080 * 16 = 257,280 bytes/frame`
- `257,280 * 60 = 15.44 MB/s`

Total first-order text payload:

- about `17.4 MB/s` before effects/cursor overhead

## 21.2 Example: 1920x1080 @ 60 Hz, 16x32 cells

From section 20.7 table:

- `cols x rows = 120 x 33 = 3,960 cells/frame`

Cell surface read (2 bytes/cell):

- `3,960 * 2 * 60 = 0.48 MB/s`

Monochrome glyph traffic (16x32, 64 bytes/glyph, no reuse):

- `3,960 * 64 * 60 = 15.21 MB/s`

Observation: larger cells reduce cell count; glyph payload remains similar.

## 21.3 Budget Guidance

- keep steady-state external bandwidth target under `~50 MB/s` for text path
- use BRAM L1 glyph caching to suppress SDRAM fetch bursts
- track `glyph_fetch_stalls` and `cell_decode_stalls` to validate headroom

---

# 22. Pipeline Latency Budget (Planning)

The ETX scanout pipeline should meet an initial bounded-latency target.

Reference stage budget:

- cell fetch/decode: 2 cycles
- glyph fetch/cache lookup: 3 cycles
- effects pipeline: 4 cycles
- cursor blend: 1 cycle
- final compositing/output: 1 cycle

Nominal total: about 11 cycles.

Design target:

- keep total at or below 12 cycles for baseline feature set
- re-time and pipeline effects stages as optional features are enabled
- preserve deterministic latency independent of UTF-8 ingest activity

---

# 23. Integration Plan for fabi386 + MiSTer DE10 (Dual 32MB SDRAM Modules)

This section maps ETX onto the current fabi386 integration and MiSTer hardware
constraints, assuming at least two 32MB SDRAM GPIO modules are available.

## 23.1 Current Baseline in This Repository

Current active top-level memory path:

- `f386_ooo_core_top -> f386_mem_ctrl or L2 -> DDRAM_*` (MiSTer HPS bridge)

Implication:

- HPS DDRAM remains high-latency and variable-latency from FPGA perspective
- scanout-critical ETX traffic should not depend on DDRAM service determinism

## 23.2 Target Memory Topology (DE10 Reality-Aware)

Use a split memory strategy:

- SDRAM-A (32MB GPIO module): scanout-critical ETX surfaces
- SDRAM-B (32MB GPIO module): RAMFont L2 glyph store and ingest staging
- HPS DDRAM (`DDRAM_*`): bulk assets, low-priority background loads, debug dumps

Recommended allocation:

- SDRAM-A:
  - active text surface(s)
  - scanline row cache spill (if needed)
  - cursor/overlay metadata
- SDRAM-B:
  - RAMFont glyph pages
  - UTF-8 ingest/codepoint staging buffers
  - optional proportional width tables and style tables
- DDRAM:
  - large font packs
  - infrequently used glyph assets
  - tooling/trace buffers

## 23.3 ETX Integration Blocks (Incremental)

Add a dedicated ETX memory subsystem in `f386_emu`:

- `f386_etx_frontend`:
  - register file, mode/font state machine, layout engine
  - exposes software-visible MMIO register block
- `f386_etx_scanout_pipe`:
  - deterministic scanline pipeline from sections 14 and 22
  - consumes `etx_timing_if`
- `f386_etx_mem_hub`:
  - arbitrates ETX memory clients to SDRAM-A/B and optional DDRAM DMA
  - enforces scanline-deadline QoS
- `f386_etx_glyph_cache`:
  - BRAM L1 glyph cache (512-1024 entries target)
  - refill path from SDRAM-B

CPU-side dependency:

- ETX remains logically separate from LSQ/L2 CPU memory path
- shared resources are only:
  - MMIO control plane
  - optional bulk DMA path from DDRAM to SDRAM-B

## 23.4 Arbitration and QoS Policy

Priority policy inside `f386_etx_mem_hub`:

1. next-line scanout fetches (hard real-time)
2. current-line emergency refill (deadline rescue)
3. glyph L1 refill misses
4. UTF-8/codepoint ingest writes
5. background DMA (DDRAM <-> SDRAM-B)

Rules:

- never allow low-priority DMA to consume slots reserved for next-line fetch
- maintain per-line fetch watermark (line buffer must reach safe threshold before
  servicing non-scanout traffic)
- if watermark violated, force emergency mode: only class-1/2 traffic until safe

## 23.5 Clocking and CDC Strategy

Use at least two domains:

- `clk_sys` for control/MMIO/cache/tag logic
- `pixel_clk` for scanout timing and pixel pipeline

Optional memory domain if SDRAM PHY requires separate phase-aligned clock.

CDC requirements:

- async FIFO between `clk_sys` and `pixel_clk` for scanline commands/data
- frame-boundary shadow->active config transfer (`frame_start` synchronized)
- sticky fault/counter readback synchronized into MMIO domain

## 23.6 SDRAM Throughput and Headroom Assumptions

For planning, treat each 32MB SDRAM module as medium-bandwidth, lower-latency
memory relative to HPS DDRAM bridge.

Conservative planning target:

- use only a fraction of theoretical peak bandwidth for guaranteed service
- reserve deterministic budget for scanout-critical reads first

Given section 21 text-payload estimates (`~17-20 MB/s` order for 1080p text
workloads), dual-module partitioning provides substantial practical headroom
for glyph misses and effects traffic when arbitration is deadline-driven.

## 23.7 Degraded/Fallback Modes

If one SDRAM module is missing or fails timing closure:

- single-module fallback:
  - keep text surface + glyph L1 refill on the available module
  - throttle or disable non-essential effects
  - reduce max supported font geometry/mode set if required
- no-SDRAM fallback:
  - force safe ETX profile (8x16, reduced features)
  - optional direct DDRAM-backed mode with strict watchdog/fault reporting

Readable output remains mandatory in all fallback states.

## 23.8 Suggested Bring-Up Sequence (Implementation)

Phase A:

- integrate ETX register block + fixed 8x16 path
- store surface in SDRAM-A
- verify mode switching and scanout determinism

Phase B:

- add BRAM L1 glyph cache + SDRAM-B refill
- enable variable geometry presets from section 20.7

Phase C:

- enable UTF-8 ingest path and codepoint staging on SDRAM-B
- add counters for glyph/cache stall analysis

Phase D:

- add optional DDRAM background DMA for asset streaming
- verify no scanout regressions under stress

## 23.9 Verification Gates for DE10 Deployment

Must-pass checks:

- no scanout underrun across all section 20.6 timing profiles
- mode switch handshake semantics hold (section 20.2)
- watermark emergency policy prevents line misses under synthetic burst load
- glyph/cache counters remain within expected thresholds for 1080p60 workloads
- fallback mode activates cleanly when one SDRAM module is disabled

## 23.10 RTL Hook Points in Current Tree

Recommended integration path in this repository:

- `rtl/top/f386_pkg.sv`
  - add `CONF_ENABLE_ETX`
  - add `CONF_ENABLE_ETX_DUAL_SDRAM`
- `rtl/top/f386_emu.sv`
  - add ETX block generate branch:
    - OFF: current behavior unchanged
    - ON: instantiate ETX frontend/pipeline/mem hub and SDRAM-A/B controllers
  - keep CPU memory path (`mem_ctrl`/L2/DDRAM) isolated from ETX fast path
- `rtl/soc/` or `rtl/video/` (new modules)
  - `f386_etx_frontend.sv`
  - `f386_etx_scanout_pipe.sv`
  - `f386_etx_mem_hub.sv`
  - `f386_etx_glyph_cache.sv`
- optional bridge module:
  - `f386_etx_dma_ddram_bridge.sv` for background asset copy only

Integration rule:

- ETX real-time scanout traffic must never hard-depend on `DDRAM_*` acceptance
- DDRAM participation is best-effort and background-priority for ETX

## 23.11 DE10 / MiSTer Physical Constraints and Policies

Board-level realities to encode in the design:

- SDRAM module quality and timing margin vary by board/module pair
- closure must be validated per memory clock target, not assumed from theory
- keep default clock profile conservative for bring-up, then bin higher profiles

Policy recommendations:

- boot-time memory profile select:
  - `SAFE` (lowest clock, widest timing margins)
  - `BALANCED`
  - `PERF` (validated boards only)
- runtime status bits expose:
  - detected dual-module availability
  - active ETX memory profile
  - fallback reason code if degraded

Address-map guidance (ETX-local):

- SDRAM-A window: fixed contiguous region for surface/scanout assets
- SDRAM-B window: fixed contiguous region for RAMFont/glyph assets
- avoid cross-module striping in v1 (simpler controller timing and debug)

---

# 24. Advanced Graphics Rendering Pipeline (SVGA/VBE/AF) — Complete Design

This section defines the non-text graphics pipeline that coexists with ETX text.
It targets MiSTer DE10 deployment with at least two 32MB SDRAM GPIO modules.

## 24.1 Scope and Objectives

The graphics path provides:

- VBE-compatible linear framebuffer operation
- AF-style 2D acceleration primitives
- tile-based deferred compositing for scanout determinism
- hardware cursor plane with alpha and optional animation

Design objective:

- maintain deterministic scanout while CPU/blitter traffic is active

## 24.2 Hard v1 Design Decisions

The following are fixed for v1:

- scanout architecture: Variant B only (line buffers + tile cache)
- tile geometry: `32x16` pixels
- command model: MMIO command registers plus single ring FIFO
- alpha convention: premultiplied alpha in compositor
- scanout source: cacheable backing store in SDRAM, never direct CPU-visible VRAM
- real-time dependency: scanout must not depend on `DDRAM_*` acceptance

## 24.3 Top-Level Graphics Block Diagram

```
CPU / Driver / DMA
   |
   v
GFX MMIO + Command Frontend
   |
   v
2D Render/Blit Engine -----> Backing Store Surfaces (SDRAM-A/B)
   |                                   |
   |                                   v
   +------> Dirty Tile Tracker ----> Tile Scheduler
                                       |
                                       v
                               Tile Prefetch Engine
                                       |
                                       v
                                Tile Cache + Line Buffers
                                       |
                                       v
                           Cursor/Overlay Alpha Compositor
                                       |
                                       v
                           Pixel Formatter + Optional Gamma
                                       |
                                       v
                            Timing/Scanout (HDMI/VGA output)
```

## 24.4 Memory Model and Placement

### 24.4.1 Domains

- cacheable backing store (SDRAM): render targets, offscreen surfaces, tiles
- scanout-local BRAM structures: tile cache tags/data slices, line FIFOs
- optional background asset source (DDRAM): low-priority streaming only

### 24.4.2 Recommended Physical Placement

- SDRAM-A:
  - active visible surface(s)
  - scanout-critical tile source region
  - cursor frame source (optional prefetch path)
- SDRAM-B:
  - offscreen surfaces
  - command ring
  - glyph/atlas/sprite resources
- DDRAM:
  - bulk assets and background upload/download

### 24.4.3 Example ETX Graphics Local Map (v1 suggestion)

- SDRAM-A (32MB):
  - 0-16MB: visible/back buffers (double/triple depending format)
  - 16-24MB: scanout staging and tile-source overflow
  - 24-32MB: reserved/diagnostics
- SDRAM-B (32MB):
  - 0-8MB: command ring + completion/fence buffers
  - 8-24MB: offscreen surfaces/sprites/patterns
  - 24-32MB: upload scratch + reserved

## 24.5 Surface and Format Contract

Required primary formats:

- 8bpp indexed (palette)
- 16bpp RGB565
- 24bpp packed RGB
- 32bpp XRGB/ARGB

Surface descriptor fields:

- base address
- width/height
- stride bytes
- format
- cache policy flags
- scanout enable bit

Legacy banked VBE compatibility:

- bank-window accesses are translated to the same linear surface address space

## 24.6 Coherency and Visibility Contract (Critical)

CPU and graphics engine share cacheable backing store. Visibility is explicit.

Rules:

- rendering engine writes become visible to scanout immediately after tile dirty
  bookkeeping completes
- CPU writes to cacheable surfaces are not guaranteed scanout-visible until a
  sync primitive is issued
- mandatory software primitive: `GFX_SYNC_RECT(surface_id, x, y, w, h, fence)`
- scanout consumes only committed regions for current frame epoch

Fallback compatibility mode:

- if direct CPU aperture writes are detected without explicit sync, engine may
  mark coarse dirty region (up to full frame) at vblank boundary

## 24.7 Command Submission and Execution Model

### 24.7.1 Submission Paths

- direct MMIO command registers (single command kick)
- ring FIFO in SDRAM (recommended for batching)

### 24.7.2 Minimum v1 Opcodes

- `NOP`
- `FILL_RECT`
- `BLIT_COPY`
- `BLIT_COLORKEY`
- `PATTERN_FILL`
- `LINE_BRESENHAM`
- `MONO_EXPAND`
- `SYNC_RECT`
- `FENCE`

### 24.7.3 Completion

- each command carries or implies a fence sequence number
- completion FIFO returns `seqno`, `status`, `fault_flags`
- optional IRQ on fence reach

## 24.8 2D Render Engine Data Path

Pipeline stages:

1. command decode
2. source read burst generation
3. format unpack/convert
4. ROP/blend/colorkey/pattern stage
5. destination write burst generation
6. dirty-tile mark update

Write policy:

- destination writes are burst-aligned when possible
- partial writes use byte-enable masks

## 24.9 Dirty Tracking and Tile Cache Design

### 24.9.1 Tile Grid

v1 tile size: `32x16`.

At 1920x1080:

- tiles_x = 60
- tiles_y = 68
- total = 4080 tiles

### 24.9.2 Dirty Metadata

Per-surface metadata:

- dirty bitmap (1 bit/tile)
- optional pending/locked bits for in-flight prefetch
- surface epoch

### 24.9.3 Tile Cache Entry Tag

Each cached tile carries:

- `surface_id`
- `tile_x`, `tile_y`
- `surface_epoch`
- `format_id`
- `palette_epoch` (indexed modes)

Any mismatch invalidates the entry.

## 24.10 Scanout and Deadline Scheduling

### 24.10.1 Scanout Stages (per pixel/line)

1. timing `(x,y,DE,HS,VS)`
2. tile address map
3. tile cache lookup
4. miss prefetch (if needed)
5. line buffer output
6. cursor/overlay blend
7. gamma/LUT (optional)
8. output format pack

### 24.10.2 Line Buffers

Minimum recommendation:

- double line buffer
- size for max active width and max bpp profile

Reference storage per line:

- 1920x24bpp: 5760 bytes
- 1920x32bpp: 7680 bytes

### 24.10.3 QoS Priorities

Hard priority order:

1. next-line mandatory prefetch
2. current-line emergency refill
3. tile-cache miss service
4. render-engine reads/writes
5. background DMA

Emergency rule:

- if line watermark drops below threshold, service only classes 1-2 until
  safe watermark restored

## 24.11 Cursor and Overlay Plane

Cursor is a separate plane composited in scanout path.

Required v1 features:

- ARGB8888 cursor format
- size up to 64x64 (128x128 optional)
- hotspot x/y
- alpha blend (premultiplied)

Blend equation (premultiplied):

- `out_rgb = cursor_rgb + (1 - cursor_a) * under_rgb`

Animated cursor:

- frame table with `frame_base`, `frame_count`, `frame_period`

## 24.12 Register and MMIO Contract (v1 minimum)

### 24.12.1 Global Graphics Control

- `GFX_CTRL` (enable, reset, irq_en)
- `GFX_STATUS` (busy, underrun, fault, profile)
- `GFX_MODE` (format, width, height, stride)
- `GFX_BASE` (visible surface base)

### 24.12.2 Command Interface

- `CMD_HEAD`, `CMD_TAIL`, `CMD_BASE`, `CMD_SIZE`
- `CMD_KICK`
- `CMD_STATUS`

### 24.12.3 Sync/Fence

- `FENCE_EMIT`
- `FENCE_DONE`
- `SYNC_RECT_XY`
- `SYNC_RECT_WH`
- `SYNC_RECT_SURFACE`
- `SYNC_RECT_KICK`

### 24.12.4 Cursor

- `CUR_CTRL`
- `CUR_POS`
- `CUR_HOTSPOT`
- `CUR_BASE`
- `CUR_FRAME_CFG`

### 24.12.5 Counters

- `CTR_TILE_HIT`
- `CTR_TILE_MISS`
- `CTR_LINE_EMERG`
- `CTR_SCAN_UNDERRUN`
- `CTR_CMD_STALL`

## 24.13 Fault Model and Recovery

Sticky fault classes:

- surface stride/format invalid
- command decode invalid
- SDRAM timeout or starvation
- scanout underrun

Recovery behavior:

- preserve output with last-good frame when possible
- raise sticky fault and counter
- optionally force safe graphics profile

## 24.14 Performance Envelope and Limits

Known full-frame bandwidth at 1080p60:

- 24bpp: ~373 MB/s read
- 32bpp: ~497 MB/s read

Implication:

- full-frame uncached reread each frame is high risk on shared memory
- tile cache reuse + deadline prefetch are required for robust 1080p operation

Policy:

- if workload exceeds sustained budget, drop to safe profile (lower bpp and/or
  reduced mode) rather than permit scanout underrun

## 24.15 Phased Implementation Plan

Phase G0:

- sequential scanout via line buffers
- single visible surface
- solid fill + copy blit
- alpha cursor

Phase G1:

- dirty tracking and tile cache activated
- ring command FIFO
- fence/sync contract fully wired

Phase G2:

- color-key and mono-expand acceleration
- indexed-mode palette epoch invalidation
- background DDRAM streaming path

Phase G3:

- optimization pass (tile-cache associativity, scheduler tuning)
- optional larger cursor and extra overlays
