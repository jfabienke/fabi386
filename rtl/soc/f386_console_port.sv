/*
 * fabi386: Diagnostic Console I/O Port
 * -------------------------------------
 * Snoops the peripheral I/O bus for writes to a small set of I/O ports
 * and translates them into framebuffer writes into `f386_vga`. Gives
 * the CPU a way to emit text to the HDMI display without needing the
 * microcoded MOV Sreg instruction required to do `mov es, 0xB800;
 * mov [es:di], al` the normal way.
 *
 * Port map:
 *   0xC000  W   Write character at current cursor → advance cursor by 1
 *   0xC001  W   Set current attribute byte (used for every subsequent char)
 *   0xC002  W   Reset cursor to 0 (top-left)
 *
 * Sequence on a char write (0xC000):
 *   cycle N   : io_wr, io_addr==0xC000 → drive {fb_addr=cursor*2,
 *                                               fb_wdata=char,
 *                                               fb_wr=1, fb_cs=1}
 *   cycle N+1 : drive {fb_addr=cursor*2+1, fb_wdata=attr,
 *                     fb_wr=1, fb_cs=1}; advance cursor
 *   cycle N+2 : idle
 *
 * The f386_vga text framebuffer uses an interleaved {char, attr, char,
 * attr, ...} byte layout, so two writes per cell is the correct pattern.
 *
 * Coordinates default to cursor=0 (top-left of 80×25 text), attribute
 * 0x0F (white on black). Both are reset by any assertion of rst_n.
 */

module f386_console_port (
    input  logic         clk,
    input  logic         rst_n,

    // Snoop on the peripheral I/O bus
    input  logic [15:0]  io_addr,
    input  logic [7:0]   io_wdata,
    input  logic         io_wr,

    // Write port into f386_vga's internal framebuffer
    output logic [15:0]  fb_addr,
    output logic [7:0]   fb_wdata,
    output logic         fb_wr,
    output logic         fb_cs
);

    localparam logic [15:0] PORT_CHAR   = 16'hC000;
    localparam logic [15:0] PORT_ATTR   = 16'hC001;
    localparam logic [15:0] PORT_HOME   = 16'hC002;

    typedef enum logic [1:0] {
        ST_IDLE     = 2'd0,
        ST_WR_CHAR  = 2'd1,   // driving the char byte this cycle
        ST_WR_ATTR  = 2'd2    // driving the attr byte this cycle
    } state_t;

    state_t       state;
    logic [11:0]  cursor;       // byte index pair / 2 — i.e. cell index 0..2047
    logic [7:0]   current_attr; // written by PORT_ATTR, used on every char
    logic [7:0]   pending_char; // latched between ST_WR_CHAR and ST_WR_ATTR

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            cursor        <= 12'd0;
            current_attr  <= 8'h0F;   // white on black
            pending_char  <= 8'h20;   // space
            fb_addr       <= 16'd0;
            fb_wdata      <= 8'd0;
            fb_wr         <= 1'b0;
            fb_cs         <= 1'b0;
        end else begin
            // Default drive
            fb_wr         <= 1'b0;
            fb_cs         <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (io_wr) begin
                        case (io_addr)
                            PORT_ATTR: begin
                                current_attr <= io_wdata;
                            end
                            PORT_HOME: begin
                                cursor <= 12'd0;
                            end
                            PORT_CHAR: begin
                                // Kick off the two-cycle {char, attr} write.
                                pending_char <= io_wdata;
                                fb_addr  <= {3'd0, cursor, 1'b0};  // cursor*2 (even)
                                fb_wdata <= io_wdata;
                                fb_wr    <= 1'b1;
                                fb_cs    <= 1'b1;
                                state    <= ST_WR_ATTR;
                            end
                            default: ;
                        endcase
                    end
                end

                ST_WR_ATTR: begin
                    // Write the attribute byte at cursor*2+1 and advance.
                    fb_addr  <= {3'd0, cursor, 1'b1};  // cursor*2 + 1 (odd)
                    fb_wdata <= current_attr;
                    fb_wr    <= 1'b1;
                    fb_cs    <= 1'b1;
                    cursor   <= cursor + 12'd1;
                    state    <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
