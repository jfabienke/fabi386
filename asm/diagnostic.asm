; ============================================================================
; fabi386 — diagnostics ROM
; ----------------------------------------------------------------------------
; Minimal 16-bit real-mode diagnostic. Loaded at physical 0xFC000..0xFFFFF
; (16 KB BIOS region). On x86 reset, CS=F000, IP=FFF0 → physical 0xFFFF0,
; which is at offset 0x3FF0 in our image. That slot holds a far jump to
; F000:C000 (main code at the start of the ROM).
;
; Address math:
;   image offset 0x0000  ⇔  F000:C000  ⇔  physical 0xFC000
;   image offset 0x3FF0  ⇔  F000:FFF0  ⇔  physical 0xFFFF0  (reset vector)
;   image offset 0x3FFF  ⇔  F000:FFFF  ⇔  physical 0xFFFFF
;
; With `ORG 0xC000` NASM makes the assembled label addresses match the
; F000:XXXX offsets directly, which is what we want.
;
; Build:
;   nasm -f bin -o diagnostic.bin diagnostic.asm
;   python3 asm/bin_to_hex.py diagnostic.bin diagnostic.hex
;
; Observable outputs:
;   - I/O port 0x378 bit 0 → LED_USER on the DE10-Nano.
;     Toggles at ~1 Hz so a steady heartbeat is visible.
; ============================================================================

BITS 16
ORG 0xC000

; ============================================================================
; main — first instruction the CPU runs after the reset-vector far jump
; ============================================================================
main:
    cli                      ; interrupts off
    cld                      ; string ops count up

    ; Stack somewhere sane: SS:SP = 0000:7C00 (below the BIOS area).
    xor   ax, ax
    mov   ss, ax
    mov   sp, 0x7C00

    mov   bl, 0               ; LED state

heartbeat:
    ; Drive LED via I/O port 0x378 bit 0.
    mov   al, bl
    mov   dx, 0x0378
    out   dx, al

    ; Flip bit 0 for next iteration.
    xor   bl, 0x01

    ; Delay loop ~½ second at ~33 MHz CPU. Two nested 16-bit counters
    ; (0xFFFF × 0x00FF ≈ 16 M iterations, each ≈ 1 clock on a fast core
    ; — loose approximation; will be refined after first-light).
    mov   cx, 0xFFFF
.delay_outer:
    mov   di, 0x00FF
.delay_inner:
    dec   di
    jnz   .delay_inner
    dec   cx
    jnz   .delay_outer

    jmp   heartbeat

; ============================================================================
; Pad to image offset 0x3FF0 (physical 0xFFFF0) — the x86 reset vector.
; ============================================================================
times 0x3FF0 - ($ - $$) db 0xFF

reset_vector:
    jmp   0xF000:0xC000      ; far jump to main (physical 0xFC000)

; ============================================================================
; Signature "FABI" at the end of the ROM (last 4 bytes, with 1 byte pad).
; ============================================================================
times 0x3FFB - ($ - $$) db 0xFF
    db 'FABI'
    db 0xFF                  ; pad to 0x4000 bytes total
