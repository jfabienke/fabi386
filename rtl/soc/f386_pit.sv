/*
 * fabi386: 8254 Programmable Interval Timer (PIT)
 * ------------------------------------------------
 * Three independent 16-bit down-counters clocked by a 1.193182 MHz input.
 *   Counter 0: System timer (IRQ0 -> INT 08h, ~18.2 Hz default)
 *   Counter 1: DRAM refresh toggle (legacy; directly modelled as a fast toggle)
 *   Counter 2: PC speaker tone generator
 *
 * I/O ports:
 *   0x40  Counter 0 data (read/write)
 *   0x41  Counter 1 data (read/write)
 *   0x42  Counter 2 data (read/write)
 *   0x43  Control word / read-back command (write-only)
 *
 * Supported modes (minimum for DOS boot):
 *   Mode 0 - Interrupt on terminal count
 *   Mode 2 - Rate generator (periodic, OUT goes low for one clock)
 *   Mode 3 - Square-wave generator (50% duty)
 *
 * BCD counting is accepted at the register level but counting is binary-only
 * (BCD decode is stubbed -- no real-world DOS software uses BCD PIT counting).
 *
 * Behavioural reference: ao486_MiSTer pit.v / pit_counter.v (A. Osman, 2014).
 */

import f386_pkg::*;

module f386_pit (
    input  logic         clk,
    input  logic         rst_n,

    // PIT oscillator input (directly 1.193182 MHz, or a toggle enable at
    // that rate derived from a higher system clock).
    input  logic         pit_clk_in,

    // I/O bus interface (directly active-high qualified by io_cs)
    input  logic [15:0]  io_addr,
    input  logic [7:0]   io_wdata,
    output logic [7:0]   io_rdata,
    input  logic         io_wr,
    input  logic         io_rd,
    input  logic         io_cs,

    // Interrupt output (active-high, directly from counter 0)
    output logic         irq0,

    // PC speaker (counter 2 output ANDed with speaker enable)
    output logic         speaker_out
);

    // =========================================================================
    //  Local address decode (only the low two bits matter once cs is asserted)
    // =========================================================================
    wire [1:0] port_sel = io_addr[1:0];

    wire wr_active = io_cs & io_wr;
    wire rd_active = io_cs & io_rd;

    // Per-counter qualifiers
    wire cnt0_wr = wr_active & (port_sel == 2'd0);
    wire cnt1_wr = wr_active & (port_sel == 2'd1);
    wire cnt2_wr = wr_active & (port_sel == 2'd2);
    wire ctrl_wr = wr_active & (port_sel == 2'd3);

    wire cnt0_rd = rd_active & (port_sel == 2'd0);
    wire cnt1_rd = rd_active & (port_sel == 2'd1);
    wire cnt2_rd = rd_active & (port_sel == 2'd2);

    // =========================================================================
    //  PIT clock edge detect
    // =========================================================================
    logic pit_clk_d;
    always_ff @(posedge clk) pit_clk_d <= pit_clk_in;

    wire pit_clk_rise = ~pit_clk_d &  pit_clk_in;
    wire pit_clk_fall =  pit_clk_d & ~pit_clk_in;

    // =========================================================================
    //  Control word decode (port 0x43 writes)
    // =========================================================================
    // Control word format:
    //   [7:6] SC  - Select Counter (00=0, 01=1, 10=2, 11=read-back)
    //   [5:4] RW  - Access mode (00=latch, 01=LSB, 10=MSB, 11=LSB then MSB)
    //   [3:1] M   - Operating mode (0-5)
    //   [0]   BCD - 0=binary, 1=BCD (stubbed)

    wire [1:0] cw_sc  = io_wdata[7:6];
    wire [1:0] cw_rw  = io_wdata[5:4];

    // Counter-specific control signals derived from control word writes
    wire set_mode_0  = ctrl_wr & (cw_sc == 2'b00) & (cw_rw != 2'b00);
    wire set_mode_1  = ctrl_wr & (cw_sc == 2'b01) & (cw_rw != 2'b00);
    wire set_mode_2  = ctrl_wr & (cw_sc == 2'b10) & (cw_rw != 2'b00);

    // Counter latch commands: either a direct latch (SC=xx, RW=00) or a
    // read-back command with the count bit set (bit 5 = 0 -> latch count).
    wire latch_cnt_0 = ctrl_wr & (
        (cw_sc == 2'b00 & cw_rw == 2'b00) |
        (io_wdata[7:5] == 3'b110 & io_wdata[1])
    );
    wire latch_cnt_1 = ctrl_wr & (
        (cw_sc == 2'b01 & cw_rw == 2'b00) |
        (io_wdata[7:5] == 3'b110 & io_wdata[2])
    );
    wire latch_cnt_2 = ctrl_wr & (
        (cw_sc == 2'b10 & cw_rw == 2'b00) |
        (io_wdata[7:5] == 3'b110 & io_wdata[3])
    );

    // Status latch (read-back with bit 4 = 0 -> latch status)
    wire latch_sts_0 = ctrl_wr & (cw_sc == 2'b11) & ~io_wdata[4] & io_wdata[1];
    wire latch_sts_1 = ctrl_wr & (cw_sc == 2'b11) & ~io_wdata[4] & io_wdata[2];
    wire latch_sts_2 = ctrl_wr & (cw_sc == 2'b11) & ~io_wdata[4] & io_wdata[3];

    // =========================================================================
    //  Counter channel instances
    // =========================================================================
    wire [7:0] rdata_0, rdata_1, rdata_2;
    wire       out_0, out_2;

    f386_pit_counter u_cnt0 (
        .clk            (clk),
        .rst_n          (rst_n),
        .pit_clk_rise   (pit_clk_rise),
        .pit_clk_fall   (pit_clk_fall),
        .gate           (1'b1),             // Counter 0 gate always enabled
        .data_in        (io_wdata),
        .set_control    (set_mode_0),
        .latch_count    (latch_cnt_0),
        .latch_status   (latch_sts_0),
        .wr_pulse       (cnt0_wr),
        .rd_pulse       (cnt0_rd),
        .data_out       (rdata_0),
        .out            (out_0)
    );

    // Counter 1: DRAM refresh -- output left unconnected (modelled as simple
    // toggle in ao486 reference; we instantiate a real counter for accuracy).
    f386_pit_counter u_cnt1 (
        .clk            (clk),
        .rst_n          (rst_n),
        .pit_clk_rise   (pit_clk_rise),
        .pit_clk_fall   (pit_clk_fall),
        .gate           (1'b1),
        .data_in        (io_wdata),
        .set_control    (set_mode_1),
        .latch_count    (latch_cnt_1),
        .latch_status   (latch_sts_1),
        .wr_pulse       (cnt1_wr),
        .rd_pulse       (cnt1_rd),
        .data_out       (rdata_1),
        .out            ()                  // Not connected
    );

    // Counter 2: PC speaker tone
    // Gate is controlled by port 61h bit 0 (speaker_gate_reg).
    logic speaker_gate_reg;
    logic speaker_en_reg;

    f386_pit_counter u_cnt2 (
        .clk            (clk),
        .rst_n          (rst_n),
        .pit_clk_rise   (pit_clk_rise),
        .pit_clk_fall   (pit_clk_fall),
        .gate           (speaker_gate_reg),
        .data_in        (io_wdata),
        .set_control    (set_mode_2),
        .latch_count    (latch_cnt_2),
        .latch_status   (latch_sts_2),
        .wr_pulse       (cnt2_wr),
        .rd_pulse       (cnt2_rd),
        .data_out       (rdata_2),
        .out            (out_2)
    );

    // =========================================================================
    //  IRQ0 and speaker outputs
    // =========================================================================
    assign irq0        = out_0;
    assign speaker_out = out_2 & speaker_en_reg;

    // =========================================================================
    //  Port 0x61 (NMI Status and Control) -- speaker gate/enable bits
    //  Only bits [1:0] are modelled here (the rest live in the chipset).
    //    bit 0: speaker gate  (counter 2 gate input)
    //    bit 1: speaker data  (enable speaker output)
    // =========================================================================
    // Note: Port 0x61 is external to this module in the fabi386 I/O bus.
    // The top-level SoC should wire these two registers from port 0x61 writes.
    // For self-contained simulation we provide default-off regs that can be
    // overridden by the integrator.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            speaker_gate_reg <= 1'b0;
            speaker_en_reg   <= 1'b0;
        end
        // No local writes -- driven by parent module or port 61h handler
    end

    // =========================================================================
    //  Read data mux (active on io_rd cycle)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            io_rdata <= 8'h00;
        end else if (rd_active) begin
            case (port_sel)
                2'd0: io_rdata <= rdata_0;
                2'd1: io_rdata <= rdata_1;
                2'd2: io_rdata <= rdata_2;
                2'd3: io_rdata <= 8'h00;   // Control register is write-only
            endcase
        end
    end

endmodule


// =============================================================================
//  f386_pit_counter -- Single PIT Channel Counter
// =============================================================================
//  Implements a single 8254 counter channel with modes 0, 2, and 3.
//  Modes 1, 4, 5 accept programming but fall through to mode 0 behaviour
//  (sufficient for DOS compatibility).
//
//  All counter operations are synchronous to `clk`.  The external PIT clock
//  is represented by edge-detect strobes (pit_clk_rise / pit_clk_fall).
// =============================================================================

module f386_pit_counter (
    input  logic        clk,
    input  logic        rst_n,

    // PIT oscillator edge strobes (derived in parent)
    input  logic        pit_clk_rise,
    input  logic        pit_clk_fall,

    // Gate input (active high)
    input  logic        gate,

    // Data bus
    input  logic [7:0]  data_in,
    input  logic        set_control,    // Control word write (port 0x43)
    input  logic        latch_count,    // Counter latch command
    input  logic        latch_status,   // Read-back status latch
    input  logic        wr_pulse,       // Data write (port 0x4x)
    input  logic        rd_pulse,       // Data read  (port 0x4x)
    output logic [7:0]  data_out,

    // Counter output
    output logic        out
);

    // -------------------------------------------------------------------------
    //  Edge detection on I/O and gate signals
    // -------------------------------------------------------------------------
    logic wr_d, rd_d, gate_d;
    always_ff @(posedge clk) begin
        wr_d   <= wr_pulse;
        rd_d   <= rd_pulse;
        gate_d <= gate;
    end

    wire wr_done   = wr_d & ~wr_pulse;   // Falling edge of write strobe
    wire rd_done   = rd_d & ~rd_pulse;    // Falling edge of read strobe
    wire gate_rise = ~gate_d &  gate;
    wire gate_fall =  gate_d & ~gate;

    // -------------------------------------------------------------------------
    //  Mode / access registers (programmed via control word)
    // -------------------------------------------------------------------------
    logic        bcd_mode;   // 0 = binary, 1 = BCD (stubbed)
    logic [2:0]  mode;       // Operating mode 0-5
    logic [1:0]  rw_mode;    // Access mode: 1=LSB, 2=MSB, 3=LSB/MSB

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bcd_mode <= 1'b0;
            mode     <= 3'd2;   // Default: rate generator (matches BIOS init)
            rw_mode  <= 2'd1;   // Default: LSB only
        end else if (set_control) begin
            bcd_mode <= data_in[0];
            mode     <= data_in[3:1];
            rw_mode  <= data_in[5:4];
        end
    end

    // -------------------------------------------------------------------------
    //  Write sequencing (LSB/MSB toggle for rw_mode 3)
    // -------------------------------------------------------------------------
    logic wr_msb_next;  // 0 = expecting LSB, 1 = expecting MSB
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n | set_control)
            wr_msb_next <= 1'b0;
        else if (wr_done & (rw_mode == 2'd3))
            wr_msb_next <= ~wr_msb_next;
    end

    wire wr_seq_done = wr_done & (rw_mode != 2'd3 | wr_msb_next);

    wire wr_is_lsb = wr_pulse & (rw_mode != 2'd2) & ~wr_msb_next;
    wire wr_is_msb = wr_pulse & (rw_mode == 2'd2 |  wr_msb_next);

    // -------------------------------------------------------------------------
    //  Read sequencing (LSB/MSB toggle for rw_mode 3)
    // -------------------------------------------------------------------------
    logic rd_msb_next;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n | set_control)
            rd_msb_next <= 1'b0;
        else if (rd_done & (rw_mode == 2'd3) & ~status_latched)
            rd_msb_next <= ~rd_msb_next;
    end

    wire rd_seq_done = rd_done & (rw_mode != 2'd3 | rd_msb_next);

    // -------------------------------------------------------------------------
    //  Count register (CR) -- written by software
    // -------------------------------------------------------------------------
    logic [7:0] cr_lo, cr_hi;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cr_lo <= 8'd0;
        end else if (wr_pulse & (rw_mode == 2'd2)) begin
            cr_lo <= 8'd0;                   // MSB-only: clear low byte
        end else if (wr_is_lsb) begin
            cr_lo <= data_in;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cr_hi <= 8'd0;
        end else if (wr_pulse & (rw_mode == 2'd1)) begin
            cr_hi <= 8'd0;                   // LSB-only: clear high byte
        end else if (wr_is_msb) begin
            cr_hi <= data_in;
        end
    end

    // -------------------------------------------------------------------------
    //  Output latch (OL) -- snapshot of counter for CPU reads
    // -------------------------------------------------------------------------
    logic [7:0] ol_lo, ol_hi;
    logic       ol_latched;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ol_lo <= 8'd0;
            ol_hi <= 8'd0;
        end else if (~ol_latched) begin
            ol_lo <= counter[7:0];
            ol_hi <= counter[15:8];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n | set_control)
            ol_latched <= 1'b0;
        else if (latch_count)
            ol_latched <= 1'b1;
        else if (rd_seq_done)
            ol_latched <= 1'b0;
    end

    // -------------------------------------------------------------------------
    //  Status latch (read-back command)
    // -------------------------------------------------------------------------
    logic [7:0] status_reg;
    logic       status_latched;
    logic       null_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            status_reg <= 8'd0;
        end else if (latch_status & ~status_latched) begin
            status_reg <= {out, null_count, rw_mode, mode, bcd_mode};
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n | set_control)
            status_latched <= 1'b0;
        else if (latch_status)
            status_latched <= 1'b1;
        else if (rd_done)
            status_latched <= 1'b0;
    end

    // Null count: set when a new count is written, cleared when loaded into CE
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            null_count <= 1'b0;
        else if (set_control | wr_seq_done)
            null_count <= 1'b1;
        else if (do_load)
            null_count <= 1'b0;
    end

    // -------------------------------------------------------------------------
    //  Data out mux: status -> MSB -> LSB priority
    // -------------------------------------------------------------------------
    assign data_out = status_latched                   ? status_reg :
                      (rw_mode == 2'd2 | rd_msb_next)  ? ol_hi      :
                                                         ol_lo;

    // -------------------------------------------------------------------------
    //  Write-done flag (sampled on PIT clock rising edge)
    // -------------------------------------------------------------------------
    logic written_flag, written_sampled;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n | set_control)
            written_flag <= 1'b0;
        else if (wr_seq_done & ~mode[0] & ~(mode[1] & loaded))
            written_flag <= 1'b1;           // Modes 0, 2, 3, 4 only
        else if (do_load)
            written_flag <= 1'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n | set_control)
            written_sampled <= 1'b0;
        else if (pit_clk_rise)
            written_sampled <= written_flag;
    end

    // -------------------------------------------------------------------------
    //  Trigger logic (gate rising edge -- modes 1, 2, 3, 5)
    // -------------------------------------------------------------------------
    logic armed, trigger_ff, trigger_sampled;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n | set_control)
            armed <= 1'b0;
        else if (wr_seq_done & (mode[1:0] == 2'b01))
            armed <= 1'b1;                  // Arm in modes 1, 5
    end

    wire trigger_allowed = (armed  & (mode[1:0] == 2'b01)) |
                           (loaded &  mode[1]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n | set_control)
            trigger_ff <= 1'b0;
        else if (gate_rise & trigger_allowed)
            trigger_ff <= 1'b1;
        else if (pit_clk_rise)
            trigger_ff <= 1'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n | set_control)
            trigger_sampled <= 1'b0;
        else if (pit_clk_rise)
            trigger_sampled <= trigger_ff;
    end

    // -------------------------------------------------------------------------
    //  Gate level sample (modes 0, 2, 3, 4)
    // -------------------------------------------------------------------------
    logic gate_sampled;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            gate_sampled <= 1'b0;
        else if (pit_clk_rise)
            gate_sampled <= gate;
    end

    // -------------------------------------------------------------------------
    //  Output signal generation
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out <= 1'b1;
        end else if (set_control) begin
            // Setting a mode resets OUT: high for modes > 0, low for mode 0
            out <= (data_in[3:1] > 3'd0);
        end else begin
            case (mode)
                3'd0: begin // Terminal count
                    if (wr_done & ~wr_msb_next)
                        out <= 1'b0;
                    else if (counter == 16'd1 & counting_en)
                        out <= 1'b1;
                end
                3'd1: begin // Hardware one-shot (fallback)
                    if (do_load)
                        out <= 1'b0;
                    else if (counter == 16'd1 & counting_en)
                        out <= 1'b1;
                end
                3'd2, 3'd6: begin // Rate generator
                    if (do_load | gate_fall)
                        out <= 1'b1;
                    else if (counter == 16'd2 & counting_en)
                        out <= 1'b0;
                end
                3'd3, 3'd7: begin // Square wave
                    if (gate_fall)
                        out <= 1'b1;
                    else if (do_load & loaded & ~trigger_sampled)
                        out <= ~out;
                end
                3'd4, 3'd5: begin // Software/hardware strobe (fallback)
                    if (counter == 16'd1 & counting_en)
                        out <= 1'b0;
                    else if (counter == 16'd0 & counting_en)
                        out <= 1'b1;
                end
                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    //  Counter (re)load logic
    // -------------------------------------------------------------------------
    wire load_written  = pit_clk_fall & written_sampled;
    wire load_trigger  = pit_clk_fall & trigger_sampled;

    // Terminal count detection for periodic modes 2 and 3
    logic term_count;
    always_ff @(posedge clk) begin
        // Mode 2: terminal at 1.  Mode 3: terminal depends on odd count & out.
        term_count <= (counter == {14'b0, ~(cr_lo[0] & out) & mode[0], ~mode[0]});
    end

    wire load_terminal = pit_clk_fall & mode[1] & term_count & loaded & gate_sampled;
    wire do_load       = load_written | load_trigger | load_terminal;

    logic loaded;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n | set_control)
            loaded <= 1'b0;
        else if (do_load)
            loaded <= 1'b1;
    end

    // -------------------------------------------------------------------------
    //  Count enable
    // -------------------------------------------------------------------------
    wire counting_en = pit_clk_fall
        & ~do_load
        & ((mode[1:0] == 2'b01) | loaded)
        & ((mode[1:0] == 2'b01) | gate_sampled)
        & ~(mode == 3'd0 & wr_msb_next);

    // -------------------------------------------------------------------------
    //  Counting Element (CE) -- 16-bit down-counter
    // -------------------------------------------------------------------------
    logic [15:0] counter;

    // Load value: in mode 3 the LSB of the count register is masked to 0
    wire [15:0] load_value = {cr_hi, cr_lo[7:1], cr_lo[0] & (mode[1:0] != 2'd3)};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter <= 16'd0;
        end else if (do_load) begin
            counter <= load_value;
        end else if (counting_en) begin
            // Mode 3 decrements by 2 (square wave); others by 1
            counter <= counter - 16'd1 - {15'd0, mode[1:0] == 2'd3};
        end
    end

endmodule
