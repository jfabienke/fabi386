; ============================================================================
; fabi386 — diagnostics ROM (VGA console + LED heartbeat)
; ----------------------------------------------------------------------------
; Loaded at physical 0xFC000..0xFFFFF (16 KB BIOS region).
; On x86 reset, CS=F000, IP=FFF0 → physical 0xFFFF0 = image offset 0x3FF0.
;
; Does two things after reset:
;   1. Writes a banner string to the VGA text console via I/O ports
;        0xC001  W   set attribute byte (color) for subsequent chars
;        0xC002  W   reset cursor to top-left
;        0xC000  W   write char at cursor, advance cursor
;      (decoded by rtl/soc/f386_console_port.sv → f386_vga text framebuffer)
;   2. Enters a forever loop toggling I/O port 0x378 bit 0, which
;      rtl/top/f386_emu.sv snoops onto LED_USER (→ DE10-Nano LEDR[0]).
;
; Only non-microcoded instructions used: MOV reg,imm — MOV reg,reg —
; MOV r8,[cs:reg] — OUT — INC reg — DEC reg — OR reg,reg — Jcc —
; JMP rel16. In particular no FAR JMP, no MOV Sreg, no CLI/CLD,
; no stack.
;
; Build:
;   nasm -f bin -o asm/diagnostic.bin asm/diagnostic.asm
;   python3 asm/bin_to_hex.py asm/diagnostic.bin asm/diagnostic.hex
; ============================================================================

BITS 16
ORG 0xC000              ; image loaded at physical 0xFC000 = F000:C000

; -------- padding to main code (placed near reset vector for NEAR-JMP reach)
times 0x3D00 - ($ - $$) db 0xFF

; ============================================================================
; main — first instruction after reset-vector NEAR JMP
; ============================================================================
main:
    ; ---- set console attribute to white on blue ----
    mov   dx, 0xC001
    mov   al, 0x1F
    out   dx, al

    ; ---- reset cursor to home (0,0) ----
    mov   dx, 0xC002
    mov   al, 0
    out   dx, al

    ; ---- write banner through the char port ----
    mov   si, banner     ; SI = offset of banner within CS segment
    mov   dx, 0xC000
.banner_loop:
    mov   al, [cs:si]    ; load byte from CS:SI (opcode 2E 8A 04)
    or    al, al         ; zero terminator?
    jz    .banner_done
    out   dx, al         ; emit char (console port advances cursor)
    inc   si
    jmp   .banner_loop
.banner_done:

    ; ---- forever: heartbeat LED_USER via port 0x378 ----
    mov   dx, 0x0378
    mov   bl, 0
heartbeat:
    mov   al, bl
    out   dx, al
    inc   bl
    mov   cx, 0xFFFF
.outer:
    mov   di, 0x00FF
.inner:
    dec   di
    jnz   .inner
    dec   cx
    jnz   .outer
    jmp   heartbeat

; ============================================================================
; banner string (null-terminated)
; ============================================================================
banner:
    db "fabi386 diag v0.4  -  hello, mister!", 0

; -------- padding to reset vector at image offset 0x3FF0 (physical 0xFFFF0)
times 0x3FF0 - ($ - $$) db 0xFF

reset_vector:
    jmp   main           ; NEAR JMP (0xE9 rel16) back to main

; -------- signature
times 0x3FFB - ($ - $$) db 0xFF
    db 'FABI'
    db 0xFF
