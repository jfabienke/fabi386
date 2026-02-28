/*
 * fabi386: Dual 8259A Programmable Interrupt Controller
 * Phase 6: SoC Peripherals
 *
 * Standard PC/AT dual-PIC: master (0x20-0x21), slave (0xA0-0xA1).
 * Slave cascaded on master IR2. Supports ICW1-ICW4, OCW1-OCW3,
 * IRR/ISR/IMR, fixed-priority resolution, edge-triggered mode,
 * specific/non-specific EOI, special mask, polled mode, spurious
 * interrupt detection.
 *
 * Reference: ao486_MiSTer pic.v (Aleksander Osman / Alexey Melnikov)
 */

import f386_pkg::*;

module f386_pic (
    input  logic         clk,
    input  logic         rst_n,
    // I/O bus
    input  logic [15:0]  io_addr,
    input  logic [7:0]   io_wdata,
    output logic [7:0]   io_rdata,
    input  logic         io_wr,
    input  logic         io_rd,
    input  logic         io_cs,       // Chip select (address decoded externally)
    // IRQ inputs (directly from peripherals)
    input  logic [15:0]  irq_lines,   // IRQ0-15
    // Processor interface
    output logic         int_req,     // Interrupt request to CPU
    output logic [7:0]   int_vector,  // Interrupt vector number
    input  logic         int_ack      // CPU acknowledges interrupt
);

    // =========================================================================
    // Address decode
    // A0 selects between command port (0) and data port (1).
    // Master PIC: 0x20 (cmd), 0x21 (data)
    // Slave  PIC: 0xA0 (cmd), 0xA1 (data)
    // =========================================================================
    logic master_cs, slave_cs, a0;
    assign master_cs = io_cs && (io_addr[15:1] == 15'h0010);   // 0x20>>1
    assign slave_cs  = io_cs && (io_addr[15:1] == 15'h0050);   // 0xA0>>1
    assign a0        = io_addr[0];

    // =========================================================================
    // Internal wires between top-level and i8259 instances
    // =========================================================================
    logic [7:0] mas_rdata, sla_rdata, mas_vector, sla_vector;
    logic       sla_int_out, mas_slave_active;

    // Slave PIC is selected when master is acknowledging a cascade on IR2.
    // This steers the vector output and ack routing.
    logic sla_select;
    assign sla_select = mas_slave_active && (mas_vector[2:0] == 3'd2);

    // Master: IRQ0,1 direct; IR2 = slave INT; IRQ3-7 direct
    f386_i8259 u_master (
        .clk(clk), .rst_n(rst_n), .a0(a0),
        .rd(io_rd & master_cs), .wr(io_wr & master_cs),
        .wdata(io_wdata), .rdata(mas_rdata),
        .irq_in({irq_lines[7:3], sla_int_out, irq_lines[1:0]}),
        .slave_active(mas_slave_active),
        .int_out(int_req), .vector_out(mas_vector), .int_ack(int_ack)
    );

    // Slave: IRQ8-15
    f386_i8259 u_slave (
        .clk(clk), .rst_n(rst_n), .a0(a0),
        .rd(io_rd & slave_cs), .wr(io_wr & slave_cs),
        .wdata(io_wdata), .rdata(sla_rdata),
        .irq_in(irq_lines[15:8]),
        .slave_active(),                        // Unused on slave
        .int_out(sla_int_out), .vector_out(sla_vector),
        .int_ack(sla_select & int_ack)          // Ack only when cascaded
    );

    // Vector mux: slave vector when cascade active, else master
    assign int_vector = sla_select ? sla_vector : mas_vector;

    // Read data mux (registered for timing)
    always_ff @(posedge clk) begin
        if (master_cs) io_rdata <= mas_rdata;
        else           io_rdata <= sla_rdata;
    end

endmodule


// =============================================================================
// f386_i8259 -- Single 8259A PIC channel
// Full ICW/OCW protocol, priority resolver with rotation, edge/level IRR,
// ISR with specific/non-specific EOI, special mask, polled mode, spurious
// interrupt detection, and cascade support.
// =============================================================================
module f386_i8259 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        a0,         // 0 = command port, 1 = data port
    input  logic        rd,
    input  logic        wr,
    input  logic [7:0]  wdata,
    output logic [7:0]  rdata,
    input  logic [7:0]  irq_in,     // Interrupt request inputs (active-high)
    output logic        slave_active,
    output logic        int_out,
    output logic [7:0]  vector_out,
    input  logic        int_ack
);

    // ---- Read pulse edge detect (single-cycle read events) ----
    logic rd_last;
    always_ff @(posedge clk) begin
        if (!rst_n)       rd_last <= 1'b0;
        else if (rd_last) rd_last <= 1'b0;
        else              rd_last <= rd;
    end
    wire rd_valid = rd && !rd_last;

    // ---- IRQ edge detection ----
    logic [7:0] irq_last;
    always_ff @(posedge clk) begin
        if (!rst_n) irq_last <= 8'h00;
        else        irq_last <= irq_in;
    end
    wire [7:0] edge_detect = irq_in & ~irq_last;

    // ---- Command word decode ----
    // ICW1: write to A0=0 with D4=1 (starts initialization sequence)
    // ICW2-4: sequential writes to A0=1 during init (vector base, cascade, mode)
    wire icw1_wr = wr && !a0 && wdata[4];
    wire icw2_wr = wr &&  a0 && in_init && (init_step == 3'd2);
    wire icw3_wr = wr &&  a0 && in_init && (init_step == 3'd3);
    wire icw4_wr = wr &&  a0 && in_init && (init_step == 3'd4);

    // OCW1: A0=1, not in init => load IMR
    // OCW2: A0=0, D4:D3=00   => EOI and rotate commands
    // OCW3: A0=0, D4:D3=01   => read register select, special mask, poll
    wire ocw1_wr = !in_init && wr && a0;
    wire ocw2_wr = wr && !a0 && (wdata[4:3] == 2'b00);
    wire ocw3_wr = wr && !a0 && (wdata[4:3] == 2'b01);

    // ---- Initialization state machine ----
    logic       in_init, icw4_needed;
    logic [2:0] init_step;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            in_init <= 1'b0; icw4_needed <= 1'b0; init_step <= 3'd0;
        end else if (icw1_wr) begin
            in_init <= 1'b1; icw4_needed <= wdata[0]; init_step <= 3'd2;
        end else if (icw2_wr)                          init_step <= 3'd3;
        else if (icw3_wr && icw4_needed)               init_step <= 3'd4;
        else if (icw3_wr && !icw4_needed)              in_init   <= 1'b0;
        else if (icw4_wr)                              in_init   <= 1'b0;
    end

    // ---- Configuration registers ----
    logic        ltim;              // Level (1) vs edge (0) trigger
    logic [4:0]  vector_base;       // Upper 5 bits of interrupt vector
    logic [7:0]  cascade_reg;       // ICW3: slave bitmap (master) or ID (slave)
    logic        auto_eoi;          // ICW4 bit 1
    logic        rotate_on_aeoi;    // OCW2 rotate-on-AEOI
    logic [2:0]  lowest_pri;        // For priority rotation
    logic        read_reg_sel;      // 0=IRR, 1=ISR on read
    logic        special_mask;      // Special mask mode
    logic        polled;            // Polled mode

    always_ff @(posedge clk) begin
        if (!rst_n)       ltim <= 1'b0;
        else if (icw1_wr) ltim <= wdata[3];
    end

    always_ff @(posedge clk) begin
        if (!rst_n)       vector_base <= 5'h0E;
        else if (icw2_wr) vector_base <= wdata[7:3];
    end

    always_ff @(posedge clk) begin
        if (!rst_n)       cascade_reg <= 8'h00;
        else if (icw3_wr) cascade_reg <= wdata;
    end

    always_ff @(posedge clk) begin
        if (!rst_n)       auto_eoi <= 1'b0;
        else if (icw1_wr) auto_eoi <= 1'b0;
        else if (icw4_wr) auto_eoi <= wdata[1];
    end

    always_ff @(posedge clk) begin
        if (!rst_n)                              rotate_on_aeoi <= 1'b0;
        else if (icw1_wr)                        rotate_on_aeoi <= 1'b0;
        else if (ocw2_wr && wdata[6:0] == 7'd0) rotate_on_aeoi <= wdata[7];
    end

    always_ff @(posedge clk) begin
        if (!rst_n)                                         lowest_pri <= 3'd7;
        else if (icw1_wr)                                   lowest_pri <= 3'd7;
        else if (ocw2_wr && wdata == 8'hA0)                 lowest_pri <= lowest_pri + 3'd1; // Rotate non-specific EOI
        else if (ocw2_wr && {wdata[7:3], 3'b000} == 8'hC0)  lowest_pri <= wdata[2:0];        // Set priority
        else if (ocw2_wr && {wdata[7:3], 3'b000} == 8'hE0)  lowest_pri <= wdata[2:0];        // Rotate specific EOI
        else if (ack_valid && auto_eoi && rotate_on_aeoi)   lowest_pri <= lowest_pri + 3'd1; // Rotate on AEOI
    end

    always_ff @(posedge clk) begin
        if (!rst_n)                                 read_reg_sel <= 1'b0;
        else if (icw1_wr)                           read_reg_sel <= 1'b0;
        else if (ocw3_wr && !wdata[2] && wdata[1])  read_reg_sel <= wdata[0];
    end

    always_ff @(posedge clk) begin
        if (!rst_n)                                 special_mask <= 1'b0;
        else if (icw1_wr)                           special_mask <= 1'b0;
        else if (ocw3_wr && !wdata[2] && wdata[6])  special_mask <= wdata[5];
    end

    always_ff @(posedge clk) begin
        if (!rst_n)                  polled <= 1'b0;
        else if (polled && rd_valid) polled <= 1'b0;
        else if (ocw3_wr)           polled <= wdata[2];
    end

    // ---- IMR (Interrupt Mask Register) ----
    logic [7:0] imr;
    always_ff @(posedge clk) begin
        if (!rst_n)       imr <= 8'hFF;     // All masked on reset
        else if (icw1_wr) imr <= 8'h00;     // ICW1 clears mask
        else if (ocw1_wr) imr <= wdata;
    end

    // ---- IRR (Interrupt Request Register) ----
    // Edge mode: latch on rising edge, clear on ack. Level mode: follow input.
    logic [7:0] irr;
    always_ff @(posedge clk) begin
        if (!rst_n)         irr <= 8'h00;
        else if (icw1_wr)   irr <= 8'h00;
        else if (ack_valid) irr <= (irr & irq_in & ~irq_vec_bits) | (!ltim ? edge_detect : irq_in);
        else                irr <= (irr & irq_in)                  | (!ltim ? edge_detect : irq_in);
    end

    // ---- ISR (In-Service Register) ----
    logic [7:0] isr;
    wire [7:0] wdata_mask = 8'h01 << wdata[2:0];

    // Non-specific EOI / polling clears highest-priority ISR bit
    wire isr_ns_clear = (polled && rd_valid) ||
                        (ocw2_wr && (wdata == 8'h20 || wdata == 8'hA0));

    always_ff @(posedge clk) begin
        if (!rst_n)                                         isr <= 8'h00;
        else if (icw1_wr)                                   isr <= 8'h00;
        else if (ocw2_wr && {wdata[7:3], 3'b000} == 8'h60)  isr <= isr & ~wdata_mask;    // Specific EOI
        else if (ocw2_wr && {wdata[7:3], 3'b000} == 8'hE0)  isr <= isr & ~wdata_mask;    // Rotate specific EOI
        else if (isr_ns_clear)                              isr <= isr & ~isr_hp_bits;    // Non-specific EOI
        else if (ack_valid && !auto_eoi)                    isr <= isr | irq_vec_bits;    // Set on ack
    end

    // ---- Priority resolver ----
    // Eligible requests: pending in IRR, not masked by IMR, not already in ISR.
    // Both eligible and ISR are barrel-shifted by lowest_pri so the priority
    // encoder always scans from bit 0 upward. With the default fixed-priority
    // setting (lowest_pri=7), IR0 has the highest priority.
    wire [7:0]  eligible     = irr & ~imr & ~isr;
    wire [15:0] elig_shifted = {eligible[0], eligible, eligible[7:1]} >> lowest_pri;
    wire [15:0] isr_shifted  = {isr[0], isr, isr[7:1]}               >> lowest_pri;

    // Highest-priority ISR bit in rotated space (for non-specific EOI)
    logic [2:0] isr_hp_idx;
    always_comb begin
        casez (isr_shifted[7:0])
            8'b???????1: isr_hp_idx = 3'd0;
            8'b??????10: isr_hp_idx = 3'd1;
            8'b?????100: isr_hp_idx = 3'd2;
            8'b????1000: isr_hp_idx = 3'd3;
            8'b???10000: isr_hp_idx = 3'd4;
            8'b??100000: isr_hp_idx = 3'd5;
            8'b?1000000: isr_hp_idx = 3'd6;
            default:     isr_hp_idx = 3'd7;
        endcase
    end

    wire [2:0] isr_hp_abs = lowest_pri + isr_hp_idx + 3'd1;
    wire [7:0] isr_hp_bits = 8'h01 << isr_hp_abs;  // For non-specific EOI

    // Highest-priority eligible request in rotated space
    logic [2:0] elig_idx;
    always_comb begin
        casez (elig_shifted[7:0])
            8'b???????1: elig_idx = 3'd0;
            8'b??????10: elig_idx = 3'd1;
            8'b?????100: elig_idx = 3'd2;
            8'b????1000: elig_idx = 3'd3;
            8'b???10000: elig_idx = 3'd4;
            8'b??100000: elig_idx = 3'd5;
            8'b?1000000: elig_idx = 3'd6;
            default:     elig_idx = 3'd7;
        endcase
    end

    // An IRQ fires when at least one eligible request exists AND the winning
    // request has higher priority than anything currently in service. Special
    // mask mode bypasses the ISR priority check.
    wire irq_active = (eligible != 8'h00) && (special_mask || elig_idx <= isr_hp_idx);

    // Convert rotated index back to absolute IR number
    wire [2:0] irq_num = lowest_pri + elig_idx + 3'd1;

    // One-hot mask of the currently selected vector's IR bit
    wire [7:0] irq_vec_bits = 8'h01 << vector_out[2:0];

    // ---- INT output ----
    // Asserted when irq_active, deasserted on acknowledge or re-initialization.
    always_ff @(posedge clk) begin
        if (!rst_n)        int_out <= 1'b0;
        else if (icw1_wr)  int_out <= 1'b0;
        else if (ack_done) int_out <= 1'b0;
        else               int_out <= irq_active;
    end

    // ---- Vector register ----
    // Continuously tracks the winning IRQ vector = {base[7:3], irq_num[2:0]}.
    // Updated whenever an IRQ is active or INT is already asserted.
    always_ff @(posedge clk) begin
        if (!rst_n)                     vector_out <= 8'h00;
        else if (icw1_wr)               vector_out <= 8'h00;
        else if (irq_active || int_out) vector_out <= {vector_base, irq_num};
    end

    // ---- Spurious interrupt detection ----
    // Spurious: CPU acks an IRQ that has since disappeared. ISR not set;
    // vector 7 (relative to base) is delivered per 8259A spec.
    wire spurious_start = int_out && !int_ack && !irq_active;
    logic spurious;

    always_ff @(posedge clk) begin
        if (!rst_n)                       spurious <= 1'b0;
        else if (icw1_wr)                spurious <= 1'b0;
        else if (spurious_start)         spurious <= 1'b1;
        else if (ack_done || irq_active) spurious <= 1'b0;
    end

    // Acknowledge qualifiers:
    //   ack_valid -- non-spurious ack: updates IRR (clear) and ISR (set).
    //   ack_done  -- any ack (including spurious): clears INT output.
    // Polled mode read also counts as an acknowledge.
    wire ack_valid = (polled && rd_valid) || (int_ack && !spurious);
    wire ack_done  = (polled && rd_valid) || int_ack;

    // ---- Cascade slave_active ----
    // cascade_reg (ICW3) bitmap indicates which IR lines have slaves attached.
    always_ff @(posedge clk) begin
        if (!rst_n)                     slave_active <= 1'b0;
        else if (icw1_wr)              slave_active <= 1'b0;
        else if (ack_done)             slave_active <= 1'b0;
        else if (irq_active || int_out) slave_active <= cascade_reg[irq_num];
    end

    // ---- Read data mux ----
    // Polled: {INT, 4'b0, irq_num}  A0=0/RRS=0: IRR  A0=0/RRS=1: ISR  A0=1: IMR
    always_comb begin
        if (polled)                 rdata = {int_out, 4'b0000, irq_num};
        else if (!a0 && !read_reg_sel) rdata = irr;
        else if (!a0 &&  read_reg_sel) rdata = isr;
        else                        rdata = imr;
    end

endmodule
