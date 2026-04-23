; ============================================================================
; fabi386 — diagnostics ROM (microcode-free revision)
; ----------------------------------------------------------------------------
; Loaded at physical 0xFC000..0xFFFFF (16 KB BIOS region).
; On x86 reset, CS=F000, IP=FFF0 → physical 0xFFFF0 = image offset 0x3FF0.
;
; First hardware test (diag_rom_01/02) showed LEDR[4] + LEDR[2]
; blinking (bitstream alive, PLL locked, cpu_clk ticking) but LEDR[0]
; dark (CPU-driven heartbeat never fires). The most likely cause is
; that this ROM's reset vector originally used FAR JMP (opcode 0xEA),
; which the fabi386 decoder handles only via microcode — and
; CONF_ENABLE_MICROCODE is OFF in the default synthesis build.
;
; This revision uses only "basic" 486 instructions that do not require
; microcode: MOV reg,imm — MOV reg,reg — OUT — INC reg — DEC reg —
; Jcc — JMP rel16. No FAR JMP, no CLI/CLD/STI, no MOV Sreg, no stack
; setup (no push/pop, no MOV SS: the instruction-prefix shadow of
; MOV SS is itself microcoded on many cores).
;
; Observable output:
;   - I/O port 0x378 bit 0 toggles at ~1 Hz → LED_USER on DE10-Nano
;     (snooped in rtl/top/f386_emu.sv at periph_io_addr == 16'h0378).
;
; Layout inside the 16 KB image (origin F000:C000 → physical 0xFC000):
;   0x0000..0x3EFF : 0xFF padding
;   0x3F00         : main loop (256 bytes max; enough for the whole loop)
;   0x3F00..0x3FEF : main code + internal pad
;   0x3FF0         : reset vector — NEAR JMP to main (3 bytes, opcode 0xE9)
;   0x3FFB..0x3FFE : "FABI" signature
;   0x3FFF         : final 0xFF pad
;
; Build:
;   nasm -f bin -o asm/diagnostic.bin asm/diagnostic.asm
;   python3 asm/bin_to_hex.py asm/diagnostic.bin asm/diagnostic.hex
; ============================================================================

BITS 16
ORG 0xC000

; -------- padding to image offset 0x3F00 (main code lands just before
;          the reset vector so the reset-vector NEAR JMP can reach it)
times 0x3F00 - ($ - $$) db 0xFF

; ---- main — runs directly on reset after the near-jump from 0xFFFF0 ----
main:
    mov   dx, 0x0378        ; DX = I/O port address (kept in dx across loop)
    mov   bl, 0              ; BL = LED state (bit 0 = LED_USER pattern)

heartbeat:
    mov   al, bl             ; AL ← BL
    out   dx, al             ; port[0x378] ← AL
    inc   bl                 ; BL++ (bit 0 toggles every iteration)

    ; Delay ~½ second at ~33 MHz: two nested 16-bit counters.
    mov   cx, 0xFFFF
.outer:
    mov   di, 0x00FF
.inner:
    dec   di
    jnz   .inner
    dec   cx
    jnz   .outer

    jmp   heartbeat          ; NEAR JMP rel16 (opcode 0xE9)

; -------- padding to image offset 0x3FF0 = physical 0xFFFF0 (reset vector)
times 0x3FF0 - ($ - $$) db 0xFF

reset_vector:
    jmp   main               ; NEAR JMP back to 'main' (opcode 0xE9)
                             ;   3 bytes: E9 <rel16>
                             ; rel16 = main - (reset+3) = FF00 - FFF3 = -0xF3 = 0xFF0D

; -------- signature at the end of ROM
times 0x3FFB - ($ - $$) db 0xFF
    db 'FABI'
    db 0xFF                  ; final pad → 16 KB exactly
