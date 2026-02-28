/*
 * fabi386: System Register File (v1.0)
 * -------------------------------------
 * Holds all architectural system state for protected/V86 mode:
 *   - Control registers CR0, CR2, CR3, CR4
 *   - Full 32-bit EFLAGS with ALU flag scatter/gather
 *   - Descriptor table registers GDTR, IDTR, LDTR, TR
 *   - Current Privilege Level (CPL)
 *
 * All read ports are combinational (zero latency).
 * Write priority: page fault CR2 > general EFLAGS > ALU flags.
 *
 * Architectural decision: Ring 0/3 hardware fast-path,
 * ring 1/2 microcode fallback. CPL stored as full 2 bits.
 */

import f386_pkg::*;

module f386_sys_regs (
    input  logic         clk,
    input  logic         rst_n,

    // --- Control Register Write Port (microcode: MOV CRn) ---
    input  cr_idx_t      cr_idx,
    input  logic [31:0]  cr_din,
    input  logic         cr_we,

    // --- Page Fault CR2 Write (MMU hardware, highest priority) ---
    input  logic [31:0]  pf_cr2_din,
    input  logic         pf_cr2_we,

    // --- EFLAGS Write Port (microcode: POPF, IRET, CLI, STI) ---
    input  logic [31:0]  eflags_din,
    input  logic [31:0]  eflags_mask,      // Which bits to update
    input  logic         eflags_we,

    // --- ALU Flags Write Port (ROB retirement) ---
    input  logic [5:0]   alu_flags_in,     // {OF, SF, ZF, AF, PF, CF}
    input  logic [5:0]   alu_flags_mask,   // Per-flag write enables (BOOM/80x86 pattern)
                                           // INC/DEC: 6'b11_1110 (preserve CF)
                                           // ROL/ROR: 6'b10_0001 (only CF+OF)
                                           // NOT:     6'b00_0000 (no flags)
    input  logic         alu_flags_we,

    // --- DTR Write Port (microcode: LGDT, LIDT, LLDT, LTR) ---
    input  dtr_idx_t     dtr_idx,
    input  logic [31:0]  dtr_base_din,
    input  logic [15:0]  dtr_limit_din,
    input  logic [15:0]  dtr_sel_din,       // For LDTR/TR selector
    input  logic [63:0]  dtr_cache_din,     // For LDTR/TR descriptor cache
    input  logic         dtr_we,

    // --- CS Selector Input (from seg_cache, for CPL derivation) ---
    // ao486 pattern: CPL = CS.RPL, not a separate register.
    // This eliminates divergence risk between CPL and CS selector.
    input  logic [15:0]  cs_sel_in,

    // --- Segment Cache D/B Input (from seg_cache) ---
    input  logic         cs_cache_db,

    // --- Control Register Read Ports ---
    output logic [31:0]  cr0,
    output logic [31:0]  cr2,
    output logic [31:0]  cr3,
    output logic [31:0]  cr4,

    // --- EFLAGS Read Port ---
    output logic [31:0]  eflags,

    // --- DTR Read Ports ---
    output logic [31:0]  gdtr_base,
    output logic [15:0]  gdtr_limit,
    output logic [31:0]  idtr_base,
    output logic [15:0]  idtr_limit,
    output logic [15:0]  ldtr_sel,
    output logic [63:0]  ldtr_cache,
    output logic [15:0]  tr_sel,
    output logic [63:0]  tr_cache,

    // --- CPL Read Port ---
    output logic [1:0]   cpl,

    // --- Derived Convenience Outputs ---
    output logic         pe_mode,
    output logic         pg_mode,
    output logic         v86_mode,
    output logic [1:0]   iopl,
    output logic         iopl_allow,
    output logic         vme_enabled,
    output logic         pse_enabled,
    output logic         wp_enabled,
    output logic         default_32,

    // --- Pipeline Flush Outputs (1-cycle pulses) ---
    output logic         cr0_write_flush,
    output logic         cr3_write_flush,
    output logic         cr4_write_flush
);

    // =================================================================
    // CR0 Write Mask — only architecturally valid bits
    // PG(31), CD(30), NW(29) | AM(18), WP(16) | NE(5), ET(4), TS(3), EM(2), MP(1), PE(0)
    // =================================================================
    localparam logic [31:0] CR0_RW_MASK = 32'hE005_003F;

    // =================================================================
    // Internal Registers
    // =================================================================
    logic [31:0] reg_cr0;
    logic [31:0] reg_cr2;
    logic [31:0] reg_cr3;
    logic [31:0] reg_cr4;
    logic [31:0] reg_eflags;

    logic [31:0] reg_gdtr_base;
    logic [15:0] reg_gdtr_limit;
    logic [31:0] reg_idtr_base;
    logic [15:0] reg_idtr_limit;

    logic [15:0] reg_ldtr_sel;
    logic [63:0] reg_ldtr_cache;
    logic [15:0] reg_tr_sel;
    logic [63:0] reg_tr_cache;

    // Shadow registers for flush edge detection
    logic [31:0] cr0_prev;
    logic [31:0] cr4_prev;

    // =================================================================
    // Control Registers (CR0, CR2, CR3, CR4)
    // =================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_cr0 <= 32'h0000_0010;   // ET=1 hardwired on 486
            reg_cr2 <= 32'h0;
            reg_cr3 <= 32'h0;
            reg_cr4 <= 32'h0;
        end else begin
            // Page fault CR2 — highest priority
            if (pf_cr2_we)
                reg_cr2 <= pf_cr2_din;

            // General CR write (MOV CRn)
            if (cr_we) begin
                case (cr_idx)
                    CR_0: begin
                        // Mask to valid bits, force ET=1
                        reg_cr0 <= (cr_din & CR0_RW_MASK) | 32'h0000_0010;
                    end
                    CR_2: begin
                        // Only if page fault port isn't writing simultaneously
                        if (!pf_cr2_we)
                            reg_cr2 <= cr_din;
                    end
                    CR_3: reg_cr3 <= cr_din;
                    CR_4: reg_cr4 <= {27'b0, cr_din[4:0]};  // Only bits [4:0] valid on 486
                    default: ; // CR1 is reserved, ignore
                endcase
            end
        end
    end

    // =================================================================
    // EFLAGS Register
    // =================================================================
    // Write priority: eflags_we (microcode) > alu_flags_we (retirement)
    // In practice these never collide (microcode stalls the pipeline).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_eflags <= 32'h0000_0002;  // Bit 1 always 1 on x86
        end else if (eflags_we) begin
            // Masked EFLAGS write (POPF, IRET, CLI, STI)
            reg_eflags <= ((reg_eflags & ~eflags_mask) | (eflags_din & eflags_mask))
                          | 32'h0000_0002;  // Force bit 1
        end else if (alu_flags_we) begin
            // Per-flag masked scatter: only update flags where mask bit is set.
            // This is critical for x86 correctness:
            //   INC/DEC preserve CF, ROL/ROR only touch CF+OF, NOT touches nothing.
            // Pattern from 80x86 Flags.sv update_flags[] and BOOM flag rename.
            if (alu_flags_mask[ALU_FLAG_CF]) reg_eflags[EFLAGS_CF] <= alu_flags_in[ALU_FLAG_CF];
            if (alu_flags_mask[ALU_FLAG_PF]) reg_eflags[EFLAGS_PF] <= alu_flags_in[ALU_FLAG_PF];
            if (alu_flags_mask[ALU_FLAG_AF]) reg_eflags[EFLAGS_AF] <= alu_flags_in[ALU_FLAG_AF];
            if (alu_flags_mask[ALU_FLAG_ZF]) reg_eflags[EFLAGS_ZF] <= alu_flags_in[ALU_FLAG_ZF];
            if (alu_flags_mask[ALU_FLAG_SF]) reg_eflags[EFLAGS_SF] <= alu_flags_in[ALU_FLAG_SF];
            if (alu_flags_mask[ALU_FLAG_OF]) reg_eflags[EFLAGS_OF] <= alu_flags_in[ALU_FLAG_OF];
            // Bit 1 is maintained (not overwritten by ALU scatter)
        end
    end

    // =================================================================
    // Descriptor Table Registers (GDTR, IDTR, LDTR, TR)
    // =================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_gdtr_base  <= 32'h0;
            reg_gdtr_limit <= 16'hFFFF;    // Real-mode IVT
            reg_idtr_base  <= 32'h0;
            reg_idtr_limit <= 16'hFFFF;
            reg_ldtr_sel   <= 16'h0;
            reg_ldtr_cache <= 64'h0;
            reg_tr_sel     <= 16'h0;
            reg_tr_cache   <= 64'h0;
        end else if (dtr_we) begin
            case (dtr_idx)
                DTR_GDTR: begin
                    reg_gdtr_base  <= dtr_base_din;
                    reg_gdtr_limit <= dtr_limit_din;
                end
                DTR_IDTR: begin
                    reg_idtr_base  <= dtr_base_din;
                    reg_idtr_limit <= dtr_limit_din;
                end
                DTR_LDTR: begin
                    reg_ldtr_sel   <= dtr_sel_din;
                    reg_ldtr_cache <= dtr_cache_din;
                end
                DTR_TR: begin
                    reg_tr_sel   <= dtr_sel_din;
                    reg_tr_cache <= dtr_cache_din;
                end
            endcase
        end
    end

    // =================================================================
    // Current Privilege Level (derived from CS selector RPL)
    // =================================================================
    // ao486 pattern (write_register.v:308): CPL is not independent state,
    // it's always CS.RPL. At reset, CS selector is 0 → CPL=0 (ring 0).
    // On far CALL/JMP/IRET/exception, the segment load to CS sets RPL,
    // which automatically updates CPL. No separate write port needed.

    // =================================================================
    // Flush Edge Detection Shadows
    // =================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cr0_prev <= 32'h0000_0010;
            cr4_prev <= 32'h0;
        end else begin
            cr0_prev <= reg_cr0;
            cr4_prev <= reg_cr4;
        end
    end

    // =================================================================
    // Read Ports (combinational)
    // =================================================================
    assign cr0  = reg_cr0;
    assign cr2  = reg_cr2;
    assign cr3  = reg_cr3;
    assign cr4  = reg_cr4;

    // EFLAGS: force bit 1 on read as well
    assign eflags = reg_eflags | 32'h0000_0002;

    assign gdtr_base  = reg_gdtr_base;
    assign gdtr_limit = reg_gdtr_limit;
    assign idtr_base  = reg_idtr_base;
    assign idtr_limit = reg_idtr_limit;
    assign ldtr_sel   = reg_ldtr_sel;
    assign ldtr_cache = reg_ldtr_cache;
    assign tr_sel     = reg_tr_sel;
    assign tr_cache   = reg_tr_cache;
    assign cpl        = cs_sel_in[1:0];  // CPL = CS.RPL (ao486 pattern)

    // =================================================================
    // Derived Convenience Outputs
    // =================================================================
    assign pe_mode     = reg_cr0[0];
    assign pg_mode     = reg_cr0[31] && reg_cr0[0];
    assign v86_mode    = reg_cr0[0] && reg_eflags[EFLAGS_VM];
    assign iopl        = reg_eflags[EFLAGS_IOPL_HI:EFLAGS_IOPL_LO];
    assign iopl_allow  = (iopl == 2'b11);
    assign vme_enabled = reg_cr4[0];
    assign pse_enabled = reg_cr4[4];
    assign wp_enabled  = reg_cr0[16];
    assign default_32  = cs_cache_db;

    // =================================================================
    // Pipeline Flush Outputs (1-cycle pulses)
    // =================================================================
    // CR0: flush on PE or PG change
    assign cr0_write_flush = (reg_cr0[0] != cr0_prev[0]) ||
                             (reg_cr0[31] != cr0_prev[31]);

    // CR3: any write triggers TLB invalidation
    assign cr3_write_flush = cr_we && (cr_idx == CR_3);

    // CR4: flush on any change to bits [4:0]
    assign cr4_write_flush = (reg_cr4[4:0] != cr4_prev[4:0]);

endmodule
