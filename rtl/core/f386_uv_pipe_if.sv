/*
 * fabi386: U/V Pipe Interface
 * ----------------------------
 * Interface between dispatch and execute stages for dual-issue pipeline.
 * Carries instruction pairs and flow-control signals.
 */

import f386_pkg::*;

interface f386_uv_pipe_if;

    instr_info_t u_instr;   // U-pipe instruction
    instr_info_t v_instr;   // V-pipe instruction
    logic        u_ready;   // Execute stage ready to accept
    logic        flush;     // Pipeline flush

    modport dispatcher (
        output u_instr, v_instr, flush,
        input  u_ready
    );

    modport executor (
        input  u_instr, v_instr, flush,
        output u_ready
    );

endinterface
