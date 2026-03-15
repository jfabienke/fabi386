/*
 * fabi386: ETX Display Engine — Memory Hub / SDRAM Arbiter
 * ---------------------------------------------------------
 * Dual-channel SDRAM arbiter with QoS priority FSM.
 * Channel A: scanout prefetch, glyph cache refill, CPU surface write
 * Channel B: RAMFont fetch, command ring read, offscreen blit
 * Request FIFOs buffer accepted requests for SDRAM issue.
 * Resource stub for Quartus estimation.
 */

import f386_pkg::*;

module f386_etx_mem_hub (
    input  logic         clk,
    input  logic         rst_n,

    // --- Channel A requestors ---
    // Port 0: Scanout prefetch
    input  logic         a0_req,
    input  logic [24:0]  a0_addr,
    input  logic         a0_wr,
    input  logic [31:0]  a0_wdata,
    output logic [31:0]  a0_rdata,
    output logic         a0_ack,

    // Port 1: Glyph cache refill
    input  logic         a1_req,
    input  logic [24:0]  a1_addr,
    output logic [31:0]  a1_rdata,
    output logic         a1_ack,

    // Port 2: CPU surface write
    input  logic         a2_req,
    input  logic [24:0]  a2_addr,
    input  logic         a2_wr,
    input  logic [31:0]  a2_wdata,
    output logic         a2_ack,

    // --- Channel B requestors ---
    // Port 0: RAMFont fetch
    input  logic         b0_req,
    input  logic [24:0]  b0_addr,
    output logic [31:0]  b0_rdata,
    output logic         b0_ack,

    // Port 1: Command ring read
    input  logic         b1_req,
    input  logic [24:0]  b1_addr,
    output logic [31:0]  b1_rdata,
    output logic         b1_ack,

    // Port 2: Offscreen blit
    input  logic         b2_req,
    input  logic [24:0]  b2_addr,
    input  logic         b2_wr,
    input  logic [31:0]  b2_wdata,
    output logic [31:0]  b2_rdata,
    output logic         b2_ack,

    // --- SDRAM controller interface (stub) ---
    output logic         sdram_a_req,
    output logic [24:0]  sdram_a_addr,
    output logic         sdram_a_wr,
    output logic [31:0]  sdram_a_wdata,
    input  logic [31:0]  sdram_a_rdata,
    input  logic         sdram_a_ack,

    output logic         sdram_b_req,
    output logic [24:0]  sdram_b_addr,
    output logic         sdram_b_wr,
    output logic [31:0]  sdram_b_wdata,
    input  logic [31:0]  sdram_b_rdata,
    input  logic         sdram_b_ack,

    // QoS hint
    input  logic         scanout_urgent
);

    // =========================================================================
    //  FIFO entry format: {port_id[1:0], wr[1], addr[24:0], wdata[31:0], pad[4:0]} = 64 bits
    // =========================================================================
    localparam int FIFO_DEPTH_W = 4;  // 16 entries
    localparam int FIFO_DATA_W  = 64;

    // Pack/unpack helpers
    function automatic logic [63:0] fifo_pack(
        input logic [1:0]  port_id,
        input logic        wr,
        input logic [24:0] addr,
        input logic [31:0] wdata
    );
        return {port_id, wr, addr, wdata, 4'd0};
    endfunction

    // =========================================================================
    //  Request FIFO — Channel A: 16 x 64-bit → ~1 M10K
    // =========================================================================
    logic [FIFO_DEPTH_W-1:0] fifo_a_wr_ptr, fifo_a_rd_ptr;
    logic [FIFO_DATA_W-1:0]  fifo_a_wr_data, fifo_a_rd_data;
    logic                    fifo_a_wr_en, fifo_a_rd_en;
    logic                    fifo_a_empty, fifo_a_full;

    f386_bram_sdp #(.ADDR_W(FIFO_DEPTH_W), .DATA_W(FIFO_DATA_W)) fifo_a_ram (
        .clk     (clk),
        .wr_addr (fifo_a_wr_ptr),
        .wr_data (fifo_a_wr_data),
        .wr_en   (fifo_a_wr_en),
        .rd_addr (fifo_a_rd_ptr),
        .rd_data (fifo_a_rd_data)
    );

    // =========================================================================
    //  Request FIFO — Channel B: 16 x 64-bit → ~1 M10K
    // =========================================================================
    logic [FIFO_DEPTH_W-1:0] fifo_b_wr_ptr, fifo_b_rd_ptr;
    logic [FIFO_DATA_W-1:0]  fifo_b_wr_data, fifo_b_rd_data;
    logic                    fifo_b_wr_en, fifo_b_rd_en;
    logic                    fifo_b_empty, fifo_b_full;

    f386_bram_sdp #(.ADDR_W(FIFO_DEPTH_W), .DATA_W(FIFO_DATA_W)) fifo_b_ram (
        .clk     (clk),
        .wr_addr (fifo_b_wr_ptr),
        .wr_data (fifo_b_wr_data),
        .wr_en   (fifo_b_wr_en),
        .rd_addr (fifo_b_rd_ptr),
        .rd_data (fifo_b_rd_data)
    );

    // =========================================================================
    //  Channel A — Accept (enqueue) + Drain (SDRAM issue) FSM
    // =========================================================================
    typedef enum logic [2:0] {
        ARB_IDLE,
        ARB_ENQUEUE,
        ARB_FETCH,
        ARB_ISSUE,
        ARB_WAIT_ACK,
        ARB_RESPOND
    } arb_state_t;

    // --- Channel A accept logic (combinational priority mux → FIFO enqueue) ---
    logic        ca_accept;
    logic [63:0] ca_enq_data;

    always_comb begin
        ca_accept  = 1'b0;
        ca_enq_data = '0;
        if (!fifo_a_full) begin
            if (a0_req && scanout_urgent) begin
                ca_accept  = 1'b1;
                ca_enq_data = fifo_pack(2'd0, a0_wr, a0_addr, a0_wdata);
            end else if (a1_req) begin
                ca_accept  = 1'b1;
                ca_enq_data = fifo_pack(2'd1, 1'b0, a1_addr, 32'd0);
            end else if (a0_req) begin
                ca_accept  = 1'b1;
                ca_enq_data = fifo_pack(2'd0, a0_wr, a0_addr, a0_wdata);
            end else if (a2_req) begin
                ca_accept  = 1'b1;
                ca_enq_data = fifo_pack(2'd2, a2_wr, a2_addr, a2_wdata);
            end
        end
    end

    assign fifo_a_wr_en   = ca_accept;
    assign fifo_a_wr_data = ca_enq_data;

    // --- Channel A FIFO pointer management ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_a_wr_ptr <= '0;
            fifo_a_rd_ptr <= '0;
        end else begin
            if (fifo_a_wr_en)
                fifo_a_wr_ptr <= fifo_a_wr_ptr + 1'b1;
            if (fifo_a_rd_en)
                fifo_a_rd_ptr <= fifo_a_rd_ptr + 1'b1;
        end
    end

    assign fifo_a_empty = (fifo_a_wr_ptr == fifo_a_rd_ptr);
    assign fifo_a_full  = ((fifo_a_wr_ptr + 1'b1) == fifo_a_rd_ptr);

    // --- Channel A drain FSM ---
    arb_state_t arb_a_state;
    logic [1:0]  arb_a_winner;
    logic [24:0] arb_a_addr_r;
    logic        arb_a_wr_r;
    logic [31:0] arb_a_wdata_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arb_a_state   <= ARB_IDLE;
            arb_a_winner  <= '0;
            arb_a_addr_r  <= '0;
            arb_a_wr_r    <= 1'b0;
            arb_a_wdata_r <= '0;
            a0_ack <= 1'b0; a1_ack <= 1'b0; a2_ack <= 1'b0;
            a0_rdata <= '0; a1_rdata <= '0;
            fifo_a_rd_en <= 1'b0;
        end else begin
            a0_ack <= 1'b0; a1_ack <= 1'b0; a2_ack <= 1'b0;
            fifo_a_rd_en <= 1'b0;

            case (arb_a_state)
                ARB_IDLE: begin
                    if (!fifo_a_empty) begin
                        fifo_a_rd_en <= 1'b1;  // issue BRAM read
                        arb_a_state  <= ARB_FETCH;
                    end
                end

                ARB_FETCH: begin
                    // 1-cycle BRAM latency — fifo_a_rd_data valid at end of this cycle
                    arb_a_state <= ARB_ISSUE;
                end

                ARB_ISSUE: begin
                    // Unpack FIFO entry
                    arb_a_winner  <= fifo_a_rd_data[63:62];
                    arb_a_wr_r    <= fifo_a_rd_data[61];
                    arb_a_addr_r  <= fifo_a_rd_data[60:36];
                    arb_a_wdata_r <= fifo_a_rd_data[35:4];
                    arb_a_state   <= ARB_WAIT_ACK;
                end

                ARB_WAIT_ACK: begin
                    if (sdram_a_ack)
                        arb_a_state <= ARB_RESPOND;
                end

                ARB_RESPOND: begin
                    case (arb_a_winner)
                        2'd0: begin a0_ack <= 1'b1; a0_rdata <= sdram_a_rdata; end
                        2'd1: begin a1_ack <= 1'b1; a1_rdata <= sdram_a_rdata; end
                        2'd2: begin a2_ack <= 1'b1; end
                    endcase
                    arb_a_state <= ARB_IDLE;
                end

                default: arb_a_state <= ARB_IDLE;
            endcase
        end
    end

    // SDRAM-A outputs (active during ARB_WAIT_ACK, values latched in ARB_ISSUE)
    assign sdram_a_req   = (arb_a_state == ARB_WAIT_ACK);
    assign sdram_a_addr  = arb_a_addr_r;
    assign sdram_a_wr    = arb_a_wr_r;
    assign sdram_a_wdata = arb_a_wdata_r;

    // =========================================================================
    //  Channel B — Accept (enqueue) + Drain (SDRAM issue) FSM
    // =========================================================================

    // --- Channel B accept logic ---
    logic        cb_accept;
    logic [63:0] cb_enq_data;

    always_comb begin
        cb_accept  = 1'b0;
        cb_enq_data = '0;
        if (!fifo_b_full) begin
            if (b0_req) begin
                cb_accept  = 1'b1;
                cb_enq_data = fifo_pack(2'd0, 1'b0, b0_addr, 32'd0);
            end else if (b1_req) begin
                cb_accept  = 1'b1;
                cb_enq_data = fifo_pack(2'd1, 1'b0, b1_addr, 32'd0);
            end else if (b2_req) begin
                cb_accept  = 1'b1;
                cb_enq_data = fifo_pack(2'd2, b2_wr, b2_addr, b2_wdata);
            end
        end
    end

    assign fifo_b_wr_en   = cb_accept;
    assign fifo_b_wr_data = cb_enq_data;

    // --- Channel B FIFO pointer management ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_b_wr_ptr <= '0;
            fifo_b_rd_ptr <= '0;
        end else begin
            if (fifo_b_wr_en)
                fifo_b_wr_ptr <= fifo_b_wr_ptr + 1'b1;
            if (fifo_b_rd_en)
                fifo_b_rd_ptr <= fifo_b_rd_ptr + 1'b1;
        end
    end

    assign fifo_b_empty = (fifo_b_wr_ptr == fifo_b_rd_ptr);
    assign fifo_b_full  = ((fifo_b_wr_ptr + 1'b1) == fifo_b_rd_ptr);

    // --- Channel B drain FSM ---
    arb_state_t arb_b_state;
    logic [1:0]  arb_b_winner;
    logic [24:0] arb_b_addr_r;
    logic        arb_b_wr_r;
    logic [31:0] arb_b_wdata_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arb_b_state   <= ARB_IDLE;
            arb_b_winner  <= '0;
            arb_b_addr_r  <= '0;
            arb_b_wr_r    <= 1'b0;
            arb_b_wdata_r <= '0;
            b0_ack <= 1'b0; b1_ack <= 1'b0; b2_ack <= 1'b0;
            b0_rdata <= '0; b1_rdata <= '0; b2_rdata <= '0;
            fifo_b_rd_en <= 1'b0;
        end else begin
            b0_ack <= 1'b0; b1_ack <= 1'b0; b2_ack <= 1'b0;
            fifo_b_rd_en <= 1'b0;

            case (arb_b_state)
                ARB_IDLE: begin
                    if (!fifo_b_empty) begin
                        fifo_b_rd_en <= 1'b1;
                        arb_b_state  <= ARB_FETCH;
                    end
                end

                ARB_FETCH: begin
                    arb_b_state <= ARB_ISSUE;
                end

                ARB_ISSUE: begin
                    arb_b_winner  <= fifo_b_rd_data[63:62];
                    arb_b_wr_r    <= fifo_b_rd_data[61];
                    arb_b_addr_r  <= fifo_b_rd_data[60:36];
                    arb_b_wdata_r <= fifo_b_rd_data[35:4];
                    arb_b_state   <= ARB_WAIT_ACK;
                end

                ARB_WAIT_ACK: begin
                    if (sdram_b_ack)
                        arb_b_state <= ARB_RESPOND;
                end

                ARB_RESPOND: begin
                    case (arb_b_winner)
                        2'd0: begin b0_ack <= 1'b1; b0_rdata <= sdram_b_rdata; end
                        2'd1: begin b1_ack <= 1'b1; b1_rdata <= sdram_b_rdata; end
                        2'd2: begin b2_ack <= 1'b1; b2_rdata <= sdram_b_rdata; end
                    endcase
                    arb_b_state <= ARB_IDLE;
                end

                default: arb_b_state <= ARB_IDLE;
            endcase
        end
    end

    // SDRAM-B outputs
    assign sdram_b_req   = (arb_b_state == ARB_WAIT_ACK);
    assign sdram_b_addr  = arb_b_addr_r;
    assign sdram_b_wr    = arb_b_wr_r;
    assign sdram_b_wdata = arb_b_wdata_r;

endmodule
