/*
 * fabi386: Model Specific Register (MSR) File
 * Phase 5: The Runtime Bridge
 * Provides the software interface to the OOB Debugger, HGU, and AAR Engine.
 * Accessed via RDMSR (0F 32) and WRMSR (0F 30).
 */

import f386_pkg::*;

module f386_msr_file (
    input  logic         clk,
    input  logic         reset_n,

    // Interface to Execution Unit (RDMSR / WRMSR)
    input  logic [31:0]  msr_idx,
    input  logic [63:0]  msr_din,
    input  logic         msr_we,
    input  logic         msr_re,
    output logic [63:0]  msr_dout,
    output logic         msr_ack,

    // Hardware Control Outputs
    output logic [31:0]  guard_start,
    output logic [31:0]  guard_end,
    output logic         guard_en,

    output logic [31:0]  thermal_base,
    output logic         telemetry_en,

    output logic [31:0]  host_debug_pc_0,
    output logic [31:0]  host_debug_pc_1,
    output logic [31:0]  host_debug_pc_2,
    output logic [31:0]  host_debug_pc_3,
    output logic [3:0]   host_debug_en,
    output logic         host_debug_unlock,

    // Performance Counter Interface (Pentium extensions)
    input  logic         rob_commit_pulse,  // Pulse from ROB on each retired instruction
    output logic [63:0]  perfctr0_out,      // Cycle counter (for RDPMC ECX=0)
    output logic [63:0]  perfctr1_out       // Retired insn counter (for RDPMC ECX=1)
);

    // Performance Counter Registers (Intel standard MSR addresses)
    logic [63:0] reg_perfctr0;   // 0x000000C1 — free-running cycle counter
    logic [63:0] reg_perfctr1;   // 0x000000C2 — retired instruction counter
    assign perfctr0_out = reg_perfctr0;
    assign perfctr1_out = reg_perfctr1;

    // Internal Register Storage
    logic [31:0] reg_guard_start;
    logic [31:0] reg_guard_end;
    logic        reg_guard_en;
    logic [31:0] reg_thermal_base;
    logic        reg_telemetry_en;
    logic [31:0] reg_debug_pc [0:3];
    logic [3:0]  reg_debug_en;
    logic        reg_debug_unlock;

    // Output assignments
    assign guard_start  = reg_guard_start;
    assign guard_end    = reg_guard_end;
    assign guard_en     = reg_guard_en;
    assign thermal_base = reg_thermal_base;
    assign telemetry_en = reg_telemetry_en;
    assign host_debug_en = reg_debug_en;
    assign host_debug_unlock = reg_debug_unlock;
    assign host_debug_pc_0 = reg_debug_pc[0];
    assign host_debug_pc_1 = reg_debug_pc[1];
    assign host_debug_pc_2 = reg_debug_pc[2];
    assign host_debug_pc_3 = reg_debug_pc[3];

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reg_guard_start  <= 32'h0;
            reg_guard_end    <= 32'h0;
            reg_guard_en     <= 1'b0;
            reg_thermal_base <= 32'h0F000000; // Default mapping
            reg_telemetry_en <= 1'b0;
            reg_debug_unlock <= 1'b0;
            reg_debug_en     <= 4'b0;
            reg_perfctr0     <= 64'h0;
            reg_perfctr1     <= 64'h0;
            msr_ack <= 1'b0;
        end else begin
            // Free-running performance counters
            reg_perfctr0 <= reg_perfctr0 + 64'd1;
            if (rob_commit_pulse)
                reg_perfctr1 <= reg_perfctr1 + 64'd1;

            msr_ack <= 1'b0;
            msr_dout <= 64'h0;

            if (msr_we) begin
                msr_ack <= 1'b1;
                case (msr_idx)
                    32'hC000_1000: begin
                        reg_guard_en    <= msr_din[32];
                        reg_guard_start <= msr_din[31:0];
                    end
                    32'hC000_1001: reg_guard_end <= msr_din[31:0];
                    32'hC000_1002: begin
                        reg_telemetry_en <= msr_din[32];
                        reg_thermal_base <= msr_din[31:0];
                    end
                    32'hC000_1010: reg_debug_unlock <= (msr_din[31:0] == 32'hDEADBEEF); // Unlock Key
                    32'hC000_1011: reg_debug_pc[0] <= msr_din[31:0];
                    32'hC000_1012: reg_debug_pc[1] <= msr_din[31:0];
                    32'hC000_1015: reg_debug_en <= msr_din[3:0];
                    // Performance counters (Intel standard addresses)
                    32'h0000_00C1: reg_perfctr0 <= msr_din;
                    32'h0000_00C2: reg_perfctr1 <= msr_din;
                    default: ;
                endcase
            end
            else if (msr_re) begin
                msr_ack <= 1'b1;
                case (msr_idx)
                    32'hC000_1000: msr_dout <= {31'h0, reg_guard_en, reg_guard_start};
                    32'hC000_1001: msr_dout <= {32'h0, reg_guard_end};
                    32'hC000_1002: msr_dout <= {31'h0, reg_telemetry_en, reg_thermal_base};
                    32'hC000_1010: msr_dout <= {63'h0, reg_debug_unlock};
                    32'hC000_1011: msr_dout <= {32'h0, reg_debug_pc[0]};
                    32'hC000_1015: msr_dout <= {60'h0, reg_debug_en};
                    // Performance counters (Intel standard addresses, RDMSR/RDPMC)
                    32'h0000_00C1: msr_dout <= reg_perfctr0;
                    32'h0000_00C2: msr_dout <= reg_perfctr1;
                    default: ;
                endcase
            end
        end
    end

endmodule
