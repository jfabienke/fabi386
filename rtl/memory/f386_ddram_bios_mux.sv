/*
 * fabi386: DDRAM ↔ BIOS ROM mux (burst-aware)
 * --------------------------------------------
 * Sits between f386_l2_cache_sp's DDRAM-facing port and the top-level
 * MiSTer DDRAM pins. Reads to the BIOS region (byte 0xFC000..0xFFFFF,
 * i.e. 29-bit word addresses 0x1F800..0x1FFFF) are served from a
 * synchronous BRAM ROM; writes to the same region are silently absorbed.
 *
 * The L2 cache issues cache-line fills with burstcnt=4 (4 × 64-bit words
 * = 32-byte line). This mux honours that: one `l2_ddram_rd` pulse with
 * burstcnt=N produces N consecutive `l2_ddram_dout_ready` pulses, each
 * delivering the next 64-bit word from the ROM.
 *
 * Timing model (matches MiSTer DDRAM):
 *   cycle 0        : L2 asserts rd, addr=A, burstcnt=N. bios_rd_addr
 *                    is driven combinationally from L2's live addr; BRAM
 *                    latches address A at this edge.
 *   cycle 1        : BRAM output reflects mem[A]. Mux drives dout=mem[A]
 *                    with ready=1. rom_rd_addr_r advances to A+1.
 *   cycle 2..N     : mux drives dout=mem[A+i] with ready=1 every cycle.
 *   cycle N+1      : burst complete, back to IDLE.
 *
 *  l2_ddram_busy is asserted for the entire active window so L2 does not
 *  issue a second request on top of the first.
 *
 * Everything outside the BIOS region passes through unchanged to the
 * real DDRAM pins.
 */

module f386_ddram_bios_mux (
    input  logic        clk,
    input  logic        rst_n,

    // ---- L2-facing (the side that speaks the DDRAM protocol) ----
    input  logic [28:0] l2_ddram_addr,
    input  logic [7:0]  l2_ddram_burstcnt,
    input  logic [63:0] l2_ddram_din,
    input  logic [7:0]  l2_ddram_be,
    input  logic        l2_ddram_we,
    input  logic        l2_ddram_rd,
    output logic [63:0] l2_ddram_dout,
    output logic        l2_ddram_dout_ready,
    output logic        l2_ddram_busy,

    // ---- Real MiSTer DDRAM pins ----
    output logic [28:0] ddram_addr,
    output logic [7:0]  ddram_burstcnt,
    output logic [63:0] ddram_din,
    output logic [7:0]  ddram_be,
    output logic        ddram_we,
    output logic        ddram_rd,
    input  logic [63:0] ddram_dout,
    input  logic        ddram_dout_ready,
    input  logic        ddram_busy,

    // ---- BIOS ROM port ----
    output logic [10:0] bios_rd_addr,
    input  logic [63:0] bios_rd_data
);

    // BIOS region check on the 29-bit word address.
    //
    // fabi386's CPU reset vector is `pc_current = 32'h0000_FFF0` — a LINEAR
    // address at 0xFFF0 in low memory. (Not the canonical x86 0xFFFFFFF0
    // or segmented 0xFFFF0 at the top of 1 MB.) So our BIOS ROM has to
    // back addresses around 0xFFF0, not the traditional 0xFC000 region.
    //
    // ROM window: physical 0xC000..0xFFFF (16 KB).
    //   byte  0xC000..0xFFFF  → word 0x1800..0x1FFF
    //   In a 29-bit word addr, bits [28:11] == 18'h3.
    function automatic logic is_bios_word(input logic [28:0] waddr);
        is_bios_word = (waddr[28:11] == 18'h00003);
    endfunction

    typedef enum logic [0:0] {
        IDLE    = 1'b0,
        DELIVER = 1'b1    // consecutive ready pulses driving each beat
    } state_t;

    state_t     state;
    logic [10:0] rom_rd_addr_r;    // next ROM index to fetch
    logic [3:0]  beats_left;        // beats still to drive as ready

    wire bios_hit = is_bios_word(l2_ddram_addr);

    // In IDLE, bios_rd_addr tracks L2's live request address so the BRAM
    // latches the first beat's index on the same cycle L2 issues rd.
    // In DELIVER, bios_rd_addr comes from the advancing registered index.
    assign bios_rd_addr = (state == IDLE) ? l2_ddram_addr[10:0] : rom_rd_addr_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= IDLE;
            rom_rd_addr_r  <= 11'd0;
            beats_left     <= 4'd0;
        end else begin
            case (state)
                IDLE: begin
                    if (l2_ddram_rd && bios_hit) begin
                        // Next BRAM index for the second beat (if any).
                        rom_rd_addr_r <= l2_ddram_addr[10:0] + 11'd1;
                        // DDRAM convention: burstcnt=1 is one beat; 0 is
                        // illegal but treat as 1 defensively.
                        beats_left <= (l2_ddram_burstcnt == 8'd0)
                                    ? 4'd1
                                    : l2_ddram_burstcnt[3:0];
                        state <= DELIVER;
                    end
                end

                DELIVER: begin
                    // The BRAM data for rom_rd_addr_r (latched last cycle
                    // from IDLE or previous DELIVER) is valid this cycle.
                    // We drive dout_ready combinationally below; here we
                    // advance state.
                    if (beats_left == 4'd1) begin
                        state <= IDLE;
                    end else begin
                        rom_rd_addr_r <= rom_rd_addr_r + 11'd1;
                    end
                    beats_left <= beats_left - 4'd1;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // ---- Downstream (real DDRAM) passthrough ----
    // Suppress rd/we to DDRAM when the access falls in the BIOS range —
    // we serve those internally.
    assign ddram_addr     = l2_ddram_addr;
    assign ddram_burstcnt = l2_ddram_burstcnt;
    assign ddram_din      = l2_ddram_din;
    assign ddram_be       = l2_ddram_be;
    assign ddram_we       = l2_ddram_we && !bios_hit;
    assign ddram_rd       = l2_ddram_rd && !bios_hit;

    // ---- Upstream (L2-facing) response muxing ----
    wire delivering_now = (state == DELIVER);

    assign l2_ddram_dout       = delivering_now ? bios_rd_data     : ddram_dout;
    assign l2_ddram_dout_ready = delivering_now ? 1'b1             : ddram_dout_ready;
    assign l2_ddram_busy       = ddram_busy || delivering_now || (l2_ddram_rd && bios_hit);

endmodule
