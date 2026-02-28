/*
 * fabi386: CPUID Response Generator
 * Phase P1.8: Pentium-Era ISA Extensions
 *
 * Generates CPUID leaf responses based on the input function (EAX).
 * Feature bits are gated by CONF_ENABLE_PENTIUM_EXT.
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

    // Family/Model/Stepping — conditional on Pentium extensions
    // Pentium: Family 5, Model 2, Stepping 1 (classic Pentium P54C)
    // 486:     Family 4, Model 8, Stepping 1 (fabi386 custom)
    localparam [31:0] CPUID_1_EAX_486  = {20'h0, 4'h4, 4'h8, 4'h1};
    localparam [31:0] CPUID_1_EAX_PENT = {20'h0, 4'h5, 4'h2, 4'h1};

    // Feature flags — EAX=1, EDX
    // Bit  0: FPU (x87)
    // Bit  4: TSC (RDTSC)
    // Bit  5: MSR (RDMSR/WRMSR)
    // Bit 15: CMOVcc (conditional move) — Pentium extension
    // Bit 23: MMX — Pentium extension
    // Bit 29: Performance Monitoring Counters (RDPMC) — Pentium extension
    localparam [31:0] BASE_EDX_FEATURES = 32'h0000_0031; // FPU + TSC + MSR
    localparam [31:0] PENT_EDX_FEATURES = 32'h2080_8000; // CMOVcc (15) + MMX (23) + PMC (29)

    // Feature flags — EAX=1, ECX
    // Bit 23: POPCNT — Pentium extension
    localparam [31:0] PENT_ECX_FEATURES = 32'h0080_0000; // POPCNT (bit 23)

    // Extended feature flags — EAX=80000001h, ECX
    // Bit 5: LZCNT — Pentium extension
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
                // Family/Model/Stepping + Feature flags
                eax_out = CONF_ENABLE_PENTIUM_EXT ? CPUID_1_EAX_PENT : CPUID_1_EAX_486;
                edx_out = CONF_ENABLE_PENTIUM_EXT ?
                          (BASE_EDX_FEATURES | PENT_EDX_FEATURES) :
                          BASE_EDX_FEATURES;
                ecx_out = CONF_ENABLE_PENTIUM_EXT ? PENT_ECX_FEATURES : 32'h0;
            end

            32'h8000_0000: begin
                // Max extended leaf
                eax_out = 32'h8000_0001;
            end

            32'h8000_0001: begin
                // Extended feature flags
                ecx_out = CONF_ENABLE_PENTIUM_EXT ? EXT_ECX_FEATURES : 32'h0;
            end

            default: ;  // Unsupported leaf — return zeros
        endcase
    end

endmodule
