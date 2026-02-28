/*
 * fabi386: CPUID Response Generator
 * Phase P1.8b: Three-Tier Feature Gate Restructure
 *
 * Generates CPUID leaf responses based on the input function (EAX).
 * Feature bits are gated by three tiers:
 *   CONF_ENABLE_PENTIUM_EXT  — P5/P6: CMOVcc, MMX, RDPMC
 *   CONF_ENABLE_P3_EXT       — PIII/P4: PREFETCH, CLFLUSH, fences
 *   CONF_ENABLE_NEHALEM_EXT  — Nehalem+: POPCNT, LZCNT, TZCNT
 *
 * Supported leaves:
 *   EAX=0:          Maximum leaf + vendor string ("fabi386 CPU")
 *   EAX=1:          Family/Model/Stepping + Feature flags (EDX/ECX)
 *   EAX=80000001h:  Extended feature flags (ECX/EDX)
 */

import f386_pkg::*;

module f386_cpuid (
    input  logic [31:0] eax_in,     // CPUID function selector
    output logic [31:0] eax_out,
    output logic [31:0] ebx_out,
    output logic [31:0] ecx_out,
    output logic [31:0] edx_out
);

    // Vendor string: "fabi386 CPU " (12 bytes in EBX:EDX:ECX order)
    // EBX = "fabi", EDX = "386 ", ECX = "CPU "
    localparam [31:0] VENDOR_EBX = {8'h69, 8'h62, 8'h61, 8'h66}; // "ibaf" → "fabi" in little-endian
    localparam [31:0] VENDOR_EDX = {8'h20, 8'h36, 8'h38, 8'h33}; // " 683" → "386 " in little-endian
    localparam [31:0] VENDOR_ECX = {8'h20, 8'h55, 8'h50, 8'h43}; // " UPC" → "CPU " in little-endian

    // Family/Model/Stepping — three tiers
    // PIII (Katmai): Family 6, Model 7, Stepping 1
    // Pentium (P54C): Family 5, Model 2, Stepping 1
    // 486 (fabi386):  Family 4, Model 8, Stepping 1
    localparam [31:0] CPUID_1_EAX_486  = {20'h0, 4'h4, 4'h8, 4'h1};
    localparam [31:0] CPUID_1_EAX_PENT = {20'h0, 4'h5, 4'h2, 4'h1};
    localparam [31:0] CPUID_1_EAX_P3   = {20'h0, 4'h6, 4'h7, 4'h1};

    // Feature flags — EAX=1, EDX (per tier)
    // Base:    bit 0 (FPU), bit 4 (TSC), bit 5 (MSR)
    // Pentium: + bit 15 (CMOVcc), bit 23 (MMX), bit 29 (PMC/RDPMC)
    // P3:      + bit 19 (CLFLUSH), bit 25 (SSE — fence support), bit 26 (SSE2 — LFENCE/MFENCE)
    localparam [31:0] BASE_EDX_FEATURES = 32'h0000_0031; // FPU + TSC + MSR
    localparam [31:0] PENT_EDX_FEATURES = 32'h2080_8000; // CMOVcc (15) + MMX (23) + PMC (29)
    localparam [31:0] P3_EDX_FEATURES   = 32'h0608_0000; // CLFLUSH (19) + SSE (25) + SSE2 (26)

    // Feature flags — EAX=1, ECX (Nehalem tier)
    // Bit 23: POPCNT
    localparam [31:0] NEHALEM_ECX_FEATURES = 32'h0080_0000; // POPCNT (bit 23)

    // Extended feature flags — EAX=80000001h, ECX (Nehalem tier)
    // Bit 5: LZCNT/ABM
    localparam [31:0] EXT_ECX_FEATURES = 32'h0000_0020; // LZCNT (bit 5)

    always_comb begin
        eax_out = 32'h0;
        ebx_out = 32'h0;
        ecx_out = 32'h0;
        edx_out = 32'h0;

        case (eax_in)
            32'h0000_0000: begin
                // Max standard leaf + vendor string
                eax_out = 32'h0000_0001;
                ebx_out = VENDOR_EBX;
                edx_out = VENDOR_EDX;
                ecx_out = VENDOR_ECX;
            end

            32'h0000_0001: begin
                // Family/Model/Stepping — highest enabled tier
                if (CONF_ENABLE_P3_EXT)
                    eax_out = CPUID_1_EAX_P3;
                else if (CONF_ENABLE_PENTIUM_EXT)
                    eax_out = CPUID_1_EAX_PENT;
                else
                    eax_out = CPUID_1_EAX_486;

                // EDX feature bits — cumulative per tier
                edx_out = BASE_EDX_FEATURES;
                if (CONF_ENABLE_PENTIUM_EXT)
                    edx_out = edx_out | PENT_EDX_FEATURES;
                if (CONF_ENABLE_P3_EXT)
                    edx_out = edx_out | P3_EDX_FEATURES;

                // ECX feature bits — Nehalem only
                ecx_out = CONF_ENABLE_NEHALEM_EXT ? NEHALEM_ECX_FEATURES : 32'h0;
            end

            32'h8000_0000: begin
                // Max extended leaf
                eax_out = 32'h8000_0001;
            end

            32'h8000_0001: begin
                // Extended feature flags — Nehalem: LZCNT/ABM
                ecx_out = CONF_ENABLE_NEHALEM_EXT ? EXT_ECX_FEATURES : 32'h0;
            end

            default: ;  // Unsupported leaf — return zeros
        endcase
    end

endmodule
