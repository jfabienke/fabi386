; ============================================================================
; fabi386 — minimal diagnostics ROM (LED heartbeat only, no data section)
; ----------------------------------------------------------------------------
; Every previous attempt produced a ROM that had a data string near the
; code. Speculative prefetch over the data → decoder saw complex/microcoded
; opcodes (POPAD 0x61, BOUND 0x62, IMUL with memory, etc.) → LSQ boundary
; assertion a few cycles in. Fixed by removing the data section entirely.
; Also avoids: CLI/CLD, MOV Sreg, stack setup, FAR JMP, and [cs:si] loads
; — anything that could touch microcode or odd-offset memory.
;
; This ROM only uses: MOV reg,imm8 — MOV reg,imm16 — OUT — INC r8 —
; DEC r16 — Jcc rel8 — JMP rel8 — JMP rel16. All basic, all non-microcoded.
;
; Load at physical 0xC000 (so the reset-vector NEAR-JMP target is reachable).
; fabi386's reset PC is 0x0000FFF0 linear (NOT the canonical x86 0xFFFFFFF0).
;
; Hardware-observed behaviour of JMP NEAR:
;   target = jmp_addr + rel16  (NOT jmp_addr + 3 + rel16 as x86 spec says)
; → CPU lands 3 bytes earlier than NASM's target. The NOP sled covers this.
; ============================================================================

BITS 16
ORG 0xC000

; Everything before main is a NOP sled — any stray landing from a branch
; or mispredicted fetch flows harmlessly into main.
times 0x3FC0 - ($ - $$) db 0x90

; ============================================================================
; main — the entire diagnostic. 48 bytes, fits comfortably in one 16-byte
; fetch block's worth of code plus a follow-on block, with a tiny backwards
; JMP SHORT to loop. No data between here and the reset vector at 0x3FF0
; means speculative prefetch past main falls into NOP padding, not into
; multi-byte opcodes that need microcode.
; ============================================================================
main:                          ; at image offset 0x3FC0 = physical 0xFFC0
    mov   dx, 0x0378           ; BA 78 03
    mov   bl, 0                ; B3 00

heartbeat:
    mov   al, bl               ; 88 D8
    out   dx, al               ; EE
    inc   bl                   ; FE C3
    jmp   heartbeat            ; short/near back to heartbeat — tight loop

; Everything between end-of-main and the reset vector is NOP padding, so
; speculative fetch past the final JMP stays in safe territory.
times 0x3FF0 - ($ - $$) db 0x90

reset_vector:                   ; at image offset 0x3FF0 = physical 0xFFF0
    jmp   main                  ; NEAR JMP (E9 rel16) — CPU lands 3 bytes
                                ; earlier than expected; falls through NOPs.

; Signature at the tail.
times 0x3FFB - ($ - $$) db 0x90
    db 'FABI'
    db 0x90
