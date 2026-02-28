/*
 * fabi386: TLB Flush Controller
 * -------------------------------
 * Handles INVLPG instruction and CR3 write flush signaling.
 * Decodes INVLPG from retirement and generates appropriate
 * flush signals to the TLB.
 *
 * This is a thin wrapper — the actual invalidation logic lives
 * in f386_tlb.sv. This module coordinates between the pipeline
 * retirement and TLB control ports.
 */

import f386_pkg::*;

module f386_tlb_flush (
    input  logic         clk,
    input  logic         rst_n,

    // From retirement stage
    input  logic         retire_invlpg,      // INVLPG instruction retired
    input  logic [31:0]  retire_invlpg_addr, // Address operand of INVLPG

    input  logic         cr3_write,          // CR3 was written (MOV CR3, reg)

    // To TLB
    output logic         invlpg_valid,
    output logic [31:0]  invlpg_vaddr,
    output logic         flush_all
);

    // INVLPG: single-entry invalidation
    assign invlpg_valid = retire_invlpg;
    assign invlpg_vaddr = retire_invlpg_addr;

    // CR3 write: full flush (except global pages)
    assign flush_all = cr3_write;

endmodule
