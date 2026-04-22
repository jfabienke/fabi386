/*
 * fabi386: DDRAM ↔ BIOS ROM mux
 * ------------------------------
 * Sits between the L2 cache's DDRAM-facing port and the top-level
 * MiSTer DDRAM pins. Reads to the BIOS region (byte addresses
 * 0xFC000..0xFFFFF → word addresses 0x1F800..0x1FFFF in the 29-bit
 * ddram_addr space) are served from a synchronous BRAM ROM instead
 * of going out to DDRAM. Writes to the same region are silently
 * absorbed (the ROM is read-only).
 *
 * Everything outside the BIOS region is passed through unchanged.
 *
 * L2 side protocol (the part that matters for the intercept):
 *   - ddram_rd pulses for one cycle when L2 wants a 64-bit word
 *   - ddram_busy is monitored by L2 to throttle further requests
 *   - ddram_dout + ddram_dout_ready deliver the response
 *
 * Intercept path timing:
 *   cycle N   : L2 asserts ddram_rd with BIOS addr → mux latches, issues
 *               bios_rd_addr, drives busy=1
 *   cycle N+1 : BRAM has clocked out bios_rd_data → mux forwards as
 *               l2_ddram_dout with l2_ddram_dout_ready=1 (one cycle)
 *   cycle N+2 : mux returns to idle, busy=0
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

    // BIOS region check on the 29-bit word address. BIOS byte range
    // 0xFC000..0xFFFFF in bytes = word indices 0x1F800..0x1FFFF.
    // In 29 bits: bits [28:11] = 18'h3F, bits [10:0] = word offset.
    function automatic logic is_bios_word(input logic [28:0] waddr);
        is_bios_word = (waddr[28:11] == 18'h0003F);
    endfunction

    typedef enum logic [1:0] {
        IDLE       = 2'd0,
        ROM_ISSUE  = 2'd1,  // bios_rd_addr just latched, BRAM clocking
        ROM_RESPOND = 2'd2  // drive l2_ddram_dout + ready this cycle
    } rom_state_t;

    rom_state_t rom_state;
    logic [63:0] rom_data_q;

    // ---- BIOS intercept FSM ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rom_state   <= IDLE;
            rom_data_q  <= 64'd0;
        end else begin
            case (rom_state)
                IDLE: begin
                    if (l2_ddram_rd && is_bios_word(l2_ddram_addr))
                        rom_state <= ROM_ISSUE;
                end
                ROM_ISSUE: begin
                    // bios_rd_data valid now (BRAM synchronous read)
                    rom_data_q <= bios_rd_data;
                    rom_state  <= ROM_RESPOND;
                end
                ROM_RESPOND: begin
                    rom_state <= IDLE;
                end
                default: rom_state <= IDLE;
            endcase
        end
    end

    // ROM read address — registered at the moment L2 asserts rd, then held
    // stable while the BRAM clocks out. Using the live l2_ddram_addr works
    // too because L2 tends to hold address until it sees ddram_busy deassert,
    // but capturing it explicitly is safer.
    logic [10:0] bios_rd_addr_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bios_rd_addr_q <= 11'd0;
        else if (l2_ddram_rd && is_bios_word(l2_ddram_addr) && rom_state == IDLE)
            bios_rd_addr_q <= l2_ddram_addr[10:0];
    end
    assign bios_rd_addr = bios_rd_addr_q;

    // ---- Downstream (real DDRAM) passthrough ----
    // Suppress rd/we when L2 is targeting the BIOS region — we handle those.
    wire bios_hit = is_bios_word(l2_ddram_addr);

    assign ddram_addr     = l2_ddram_addr;
    assign ddram_burstcnt = l2_ddram_burstcnt;
    assign ddram_din      = l2_ddram_din;
    assign ddram_be       = l2_ddram_be;
    assign ddram_we       = l2_ddram_we && !bios_hit;
    assign ddram_rd       = l2_ddram_rd && !bios_hit;

    // ---- Upstream (L2-facing) response muxing ----
    // Forward DDRAM responses unchanged when not serving from ROM.
    // When in ROM_RESPOND, drive dout from the latched ROM data with a
    // one-cycle ready pulse.
    assign l2_ddram_dout       = (rom_state == ROM_RESPOND) ? rom_data_q : ddram_dout;
    assign l2_ddram_dout_ready = (rom_state == ROM_RESPOND) ? 1'b1       : ddram_dout_ready;

    // Mark busy while the ROM access is in flight so L2 doesn't issue
    // a second request on top of the first.
    assign l2_ddram_busy = ddram_busy || (rom_state != IDLE);

endmodule
