/*
 * fabi386: 2-Client Memory Request Arbiter (P2 Step 5a)
 * -------------------------------------------------------
 * Stateless, combinational arbiter between two split-phase memory clients:
 *   Client 0 = LSQ (cacheable loads + all store drains)
 *   Client 1 = IO path (MMIO loads — strongly ordered)
 *
 * Priority: Client 1 (IO) wins on simultaneous request (MMIO loads
 * are latency-sensitive and rare).
 *
 * ID-based response routing: bit [CONF_LSQ_PEND_ID_W] of the response
 * ID selects the client. No registered state needed.
 *
 * Valid/ready discipline: dn_req_valid is purely a function of upstream
 * c*_req_valid + flush. It does NOT depend on dn_req_ready. This is
 * canonical AXI-style behavior.
 */

import f386_pkg::*;

module f386_mem_req_arbiter (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         flush,

    // --- Client 0 (LSQ) ---
    input  logic         c0_req_valid,
    output logic         c0_req_ready,
    input  mem_req_t     c0_req,
    output logic         c0_rsp_valid,
    input  logic         c0_rsp_ready,
    output mem_rsp_t     c0_rsp,

    // --- Client 1 (IO path) ---
    input  logic         c1_req_valid,
    output logic         c1_req_ready,
    input  mem_req_t     c1_req,
    output logic         c1_rsp_valid,
    input  logic         c1_rsp_ready,
    output mem_rsp_t     c1_rsp,

    // --- Downstream (to shim) ---
    output logic         dn_req_valid,
    input  logic         dn_req_ready,
    output mem_req_t     dn_req,
    input  logic         dn_rsp_valid,
    output logic         dn_rsp_ready,
    input  mem_rsp_t     dn_rsp
);

    // =========================================================
    // Client Bit Position in ID
    // =========================================================
    localparam int CLIENT_BIT = CONF_LSQ_PEND_ID_W;  // bit 2

    // =========================================================
    // Selection (independent of dn_req_ready — canonical valid/ready)
    // =========================================================
    wire sel_c1 = c1_req_valid && !flush;
    wire sel_c0 = c0_req_valid && !flush && !c1_req_valid;

    // =========================================================
    // Downstream Request Mux
    // =========================================================
    assign dn_req_valid = sel_c0 || sel_c1;
    assign dn_req       = sel_c1 ? c1_req : c0_req;

    // =========================================================
    // Upstream Ready: selected AND downstream ready
    // =========================================================
    assign c0_req_ready = sel_c0 && dn_req_ready;
    assign c1_req_ready = sel_c1 && dn_req_ready;

    // =========================================================
    // Response Routing by Client Bit
    // =========================================================
    wire rsp_is_c1 = dn_rsp.id[CLIENT_BIT];

    assign c0_rsp_valid = dn_rsp_valid && !rsp_is_c1 && !flush;
    assign c0_rsp       = dn_rsp;
    assign c1_rsp_valid = dn_rsp_valid &&  rsp_is_c1 && !flush;
    assign c1_rsp       = dn_rsp;

    // Response ready: force-consume during flush, else route to client
    assign dn_rsp_ready = flush      ? 1'b1 :
                          rsp_is_c1  ? c1_rsp_ready : c0_rsp_ready;

    // =========================================================
    // Assertions (simulation only)
    // =========================================================
    `ifndef SYNTHESIS
    always_ff @(posedge clk) if (rst_n) begin
        // Both clients should not get ready simultaneously
        assert (!(c0_req_ready && c1_req_ready))
            else $error("ARB: both clients granted simultaneously");
    end
    `endif

endmodule
