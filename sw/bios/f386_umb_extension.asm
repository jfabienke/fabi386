; fabi386: BIOS Extension for UMB Optimization
; Version 1.1 - Corrected Assembly Implementation
; Targets the fabi386-specific MSRs for Shadow-Packing.

[BITS 16]

SECTION .text

; fabi386-specific Model Specific Register Addresses
%define MSR_F386_GUARD_CTL  0xC0001000
%define MSR_F386_GUARD_END  0xC0001001
%define MSR_F386_RE_CTL     0xC0001002
%define MSR_F386_MMU_REMAP  0xC0002000 ; Start of Remap Gates

; -----------------------------------------------------------------------------
; SHADOW_PACK_ROMS
; Scans the UMA (C000-EFFF), identifies hot paths, and compacts them.
; -----------------------------------------------------------------------------
shadow_pack_roms:
    pusha

    ; 1. Enable Global Telemetry via MSR to start Heat-Mapping
    ; This allows the hardware to begin witnessing the boot process.
    mov ecx, MSR_F386_RE_CTL
    rdmsr
    or  eax, 1                  ; Set Telemetry Enable Bit
    wrmsr

    ; 2. (System would typically wait here for boot completion/analysis)
    ; For Phase 5 validation, we perform a manual compaction of the SCSI ROM.

    ; 3. Compact SCSI BIOS at C800:0000 (16KB)
    ; Map it to an internal high-speed HyperRAM UMB at 0x01000000.

    mov ecx, MSR_F386_MMU_REMAP ; GATE_START_0
    mov eax, 0x000C8000         ; Start of SCSI Segment
    mov edx, 1                  ; Enable Gate
    wrmsr

    inc ecx                     ; GATE_END_0
    mov eax, 0x000CBFFF         ; 16KB later
    xor edx, edx
    wrmsr

    inc ecx                     ; GATE_OFFSET_0
    mov eax, 0x01000000         ; HyperRAM Physical Offset
    xor edx, edx
    wrmsr

    popa
    ret

; -----------------------------------------------------------------------------
; ENABLE_GUARD_SHIELD
; Protects the BIOS range [F000:0000 - F000:FFFF] from unauthorized jumps.
; -----------------------------------------------------------------------------
enable_guard_shield:
    push eax
    push ecx
    push edx

    mov ecx, MSR_F386_GUARD_CTL
    mov eax, 0x000F0000         ; Start of BIOS Segment
    mov edx, 1                  ; Enable Guard
    wrmsr

    mov ecx, MSR_F386_GUARD_END
    mov eax, 0x000FFFFF         ; End of BIOS Segment
    xor edx, edx
    wrmsr

    pop edx
    pop ecx
    pop eax
    ret
