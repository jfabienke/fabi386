/*
 * fabi386: Superscalar Pipeline Interface & Dispatch (v2.0)
 * Phase 4: Integrated Scoreboarding & Hazard Detection.
 * This module decides if two instructions can be issued simultaneously
 * to the U (Primary) and V (Secondary) pipes.
 */

import f386_pkg::*;

module f386_dispatch (
    input  logic         clk,
    input  logic         reset_n,

    // Inputs from Decoders (Pre-fetched and parsed)
    input  instr_info_t  dec_0,
    input  instr_info_t  dec_1,

    // Interface to Execution Stage
    f386_uv_pipe_if.dispatcher pipe_bus,

    // Feedback from Writeback (to clear scoreboard)
    input  logic [2:0]   wb_reg_addr,
    input  logic         wb_reg_we
);

    // --- Register Scoreboard ---
    // Tracks registers currently "In-Flight" (being modified by a pipeline)
    // 1 bit per GPR (EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI)
    logic [7:0] scoreboard;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            scoreboard <= 8'h00;
        end else begin
            // Clear bit on Writeback
            if (wb_reg_we) scoreboard[wb_reg_addr] <= 1'b0;

            // Set bits on Issue (U and V pipes)
            if (pipe_bus.u_ready) begin
                if (pipe_bus.u_instr.is_valid) scoreboard[pipe_bus.u_instr.reg_dest[2:0]] <= 1'b1;
                if (pipe_bus.v_instr.is_valid) scoreboard[pipe_bus.v_instr.reg_dest[2:0]] <= 1'b1;
            end
        end
    end

    // --- Pairing Rules Logic ---
    function automatic logic can_pair(instr_info_t u, instr_info_t v, logic [7:0] sb);
        logic no_data_hazard;
        logic u_is_simple;
        logic v_is_simple;

        // 1. Data Hazard Check (RAW, WAW, WAR)
        // V cannot read what U is writing (RAW)
        // V cannot write what U is writing (WAW)
        // V cannot read what is currently busy in the scoreboard
        no_data_hazard = (u.reg_dest != v.reg_src_a) &&
                         (u.reg_dest != v.reg_src_b) &&
                         (u.reg_dest != v.reg_dest)  &&
                         !(sb[v.reg_src_a[2:0]] || sb[v.reg_src_b[2:0]]);

        // 2. Pentium-style Pairing Rules (Simple ALU only)
        u_is_simple = (u.op_category == OP_ALU_REG || u.op_category == OP_ALU_IMM);
        v_is_simple = (v.op_category == OP_ALU_REG || v.op_category == OP_ALU_IMM);

        // 3. Structural/Complex Constraints
        // Branching instructions must only issue in the U-pipe
        return u.is_valid && v.is_valid &&
               no_data_hazard && u_is_simple && v_is_simple &&
               (u.op_category != OP_BRANCH) && (v.op_category != OP_BRANCH);
    endfunction

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pipe_bus.u_instr <= '0;
            pipe_bus.v_instr <= '0;
            pipe_bus.flush   <= 1'b0;
        end else if (pipe_bus.u_ready) begin
            // Attempt to Issue
            if (dec_0.op_category == OP_MICROCODE) begin
                // Microcode instructions take both pipes or stall V
                pipe_bus.u_instr <= dec_0;
                pipe_bus.v_instr <= '0;
            end
            else if (can_pair(dec_0, dec_1, scoreboard)) begin
                pipe_bus.u_instr <= dec_0;
                pipe_bus.v_instr <= dec_1;
            end
            else begin
                // Issue single instruction to U-pipe
                pipe_bus.u_instr <= dec_0;
                pipe_bus.v_instr <= '0;
            end
        end
    end

endmodule
