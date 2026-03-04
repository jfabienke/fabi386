/*
 * fabi386: Memory-System to MiSTer DDRAM Adapter (Draft)
 * ------------------------------------------------------
 * Minimal split-phase, tagged adapter between a core-facing request/response
 * memory contract and MiSTer's DDRAM_* handshake port.
 *
 * This draft intentionally keeps the backend simple:
 *   - Single outstanding request at a time
 *   - Single-beat LD/ST only (burst_len must be 0)
 *   - Unaligned accesses crossing a 64-bit boundary return MISALIGN
 *   - Response carries raw 64-bit DDRAM beat in rdata[63:0]
 *   - Store byte_en/wdata are expected pre-aligned to addr[31:3]
 *
 * It is a bring-up scaffold for introducing the contract, not a final MSHR/L2.
 */

import f386_pkg::*;

module f386_mem_sys_to_ddram (
    input  logic         clk,
    input  logic         rst_n,

    // --- Core-Facing Split-Phase Interface ---
    input  logic         req_valid,
    output logic         req_ready,
    input  mem_req_t     req,

    output logic         rsp_valid,
    input  logic         rsp_ready,
    output mem_rsp_t     rsp,

    // --- MiSTer DDRAM Interface ---
    output logic [28:0]  ddram_addr,       // 64-bit word address
    output logic [7:0]   ddram_burstcnt,   // Burst words
    output logic [63:0]  ddram_din,        // Write data beat
    output logic [7:0]   ddram_be,         // Byte enables for write beat
    output logic         ddram_we,         // Write strobe
    output logic         ddram_rd,         // Read strobe
    input  logic [63:0]  ddram_dout,       // Read data beat
    input  logic         ddram_dout_ready, // Read data valid
    input  logic         ddram_busy        // DDRAM backend busy
);

    typedef enum logic [2:0] {
        ST_IDLE      = 3'd0,
        ST_ISSUE_RD  = 3'd1,
        ST_WAIT_RD   = 3'd2,
        ST_ISSUE_WR  = 3'd3,
        ST_RESP      = 3'd4
    } state_t;

    state_t    state_q, state_d;
    mem_req_t  req_q, req_d;
    mem_rsp_t  rsp_q, rsp_d;

    function automatic logic crosses_64b(input logic [1:0] size, input logic [2:0] ofs);
        logic [3:0] nbytes;
        begin
            case (size)
                2'd0: nbytes = 4'd1;
                2'd1: nbytes = 4'd2;
                2'd2: nbytes = 4'd4;
                default: nbytes = 4'd8;
            endcase
            crosses_64b = ({1'b0, ofs} + nbytes) > 4'd8;
        end
    endfunction

    function automatic mem_rsp_t mk_rsp(
        input logic [CONF_MEM_REQ_ID_W-1:0] id,
        input mem_resp_t                     status,
        input logic [127:0]                  data,
        input logic [2:0]                    beat_idx,
        input logic                          last
    );
        begin
            mk_rsp = '0;
            mk_rsp.id       = id;
            mk_rsp.rdata    = data;
            mk_rsp.beat_idx = beat_idx;
            mk_rsp.last     = last;
            mk_rsp.resp     = status;
        end
    endfunction

    always_comb begin
        // Defaults
        state_d       = state_q;
        req_d         = req_q;
        rsp_d         = rsp_q;

        req_ready     = (state_q == ST_IDLE);
        rsp_valid     = (state_q == ST_RESP);
        rsp           = (state_q == ST_RESP) ? rsp_q : '0;

        ddram_addr     = 29'd0;
        ddram_burstcnt = 8'd1;
        ddram_din      = 64'd0;
        ddram_be       = 8'h00;
        ddram_we       = 1'b0;
        ddram_rd       = 1'b0;

        case (state_q)
            ST_IDLE: begin
                if (req_valid && req_ready) begin
                    req_d = req;

                    // Keep this draft strict for bring-up:
                    // scalar ops are single-beat only and must not cross 64-bit words.
                    if ((req.op == MEM_OP_LD || req.op == MEM_OP_ST) &&
                        (req.burst_len != 3'd0)) begin
                        rsp_d   = mk_rsp(req.id, MEM_RESP_RETRY, 128'd0, 3'd0, 1'b1);
                        state_d = ST_RESP;
                    end else if ((req.op == MEM_OP_LD || req.op == MEM_OP_ST) &&
                                 crosses_64b(req.size, req.addr[2:0])) begin
                        rsp_d   = mk_rsp(req.id, MEM_RESP_MISALIGN, 128'd0, 3'd0, 1'b1);
                        state_d = ST_RESP;
                    end else if (req.op == MEM_OP_ST && req.byte_en == 8'h00) begin
                        rsp_d   = mk_rsp(req.id, MEM_RESP_FAULT, 128'd0, 3'd0, 1'b1);
                        state_d = ST_RESP;
                    end else begin
                        case (req.op)
                            MEM_OP_LD:       state_d = ST_ISSUE_RD;
                            MEM_OP_ST:       state_d = ST_ISSUE_WR;
                            MEM_OP_FENCE: begin
                                rsp_d   = mk_rsp(req.id, MEM_RESP_OK, 128'd0, 3'd0, 1'b1);
                                state_d = ST_RESP;
                            end
                            default: begin
                                // Burst/fill/writeback paths come in follow-up phases.
                                rsp_d   = mk_rsp(req.id, MEM_RESP_RETRY, 128'd0, 3'd0, 1'b1);
                                state_d = ST_RESP;
                            end
                        endcase
                    end
                end
            end

            ST_ISSUE_RD: begin
                if (!ddram_busy) begin
                    ddram_addr     = req_q.addr[31:3];
                    ddram_burstcnt = 8'd1;
                    ddram_rd       = 1'b1;
                    state_d        = ST_WAIT_RD;
                end
            end

            ST_WAIT_RD: begin
                if (ddram_dout_ready) begin
                    rsp_d   = mk_rsp(req_q.id, MEM_RESP_OK, {64'd0, ddram_dout}, 3'd0, 1'b1);
                    state_d = ST_RESP;
                end
            end

            ST_ISSUE_WR: begin
                if (!ddram_busy) begin
                    ddram_addr     = req_q.addr[31:3];
                    ddram_burstcnt = 8'd1;
                    ddram_din      = req_q.wdata;
                    ddram_be       = req_q.byte_en;
                    ddram_we       = 1'b1;
                    rsp_d          = mk_rsp(req_q.id, MEM_RESP_OK, 128'd0, 3'd0, 1'b1);
                    state_d        = ST_RESP;
                end
            end

            ST_RESP: begin
                if (rsp_ready)
                    state_d = ST_IDLE;
            end

            default: state_d = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            req_q   <= '0;
            rsp_q   <= '0;
        end else begin
            state_q <= state_d;
            req_q   <= req_d;
            rsp_q   <= rsp_d;
        end
    end

`ifndef SYNTHESIS
    // Bring-up assertion: scalar stores should carry at least one written lane.
    always_ff @(posedge clk) begin
        if (rst_n && req_valid && req_ready && req.op == MEM_OP_ST) begin
            assert (req.byte_en != 8'h00)
                else $error("f386_mem_sys_to_ddram: MEM_OP_ST with empty byte_en");
        end
    end
`endif

endmodule
