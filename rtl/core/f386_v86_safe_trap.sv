/*
 * fabi386: V86 Safe-Trap Fast Path Table (v1.0)
 * -----------------------------------------------
 * Marks certain V86-sensitive operations as "safe" — eligible for
 * ~20-30 cycle microcode fast-path instead of full ~200+ cycle
 * hypervisor trap (GPF → ring-0 handler → IRET).
 *
 * Two lookup tables:
 *   1. I/O port safe-list:   16-entry CAM of port addresses known to be
 *      read-only or harmless (VGA status, PIT counter, keyboard status, etc.)
 *   2. INT vector safe-list: 8-entry list of INT numbers that the V86
 *      monitor has pre-approved for fast emulation.
 *
 * When V86 mode is active and the decoder sees IN/OUT/INT, it queries
 * this table.  If "safe", the instruction is routed to a fast microcode
 * entry point (OP_MICROCODE with a special base address) instead of
 * triggering a full #GP exception.
 *
 * The safe-lists are software-programmable via system register writes,
 * allowing the V86 monitor to configure which operations are safe.
 *
 * Latency: 0 cycles (combinational lookup, inline with decode).
 *
 * Reference: Neo-386 Pro V86 Safe-Trap concept
 */

import f386_pkg::*;

module f386_v86_safe_trap (
    input  logic        clk,
    input  logic        rst_n,

    // --- Query (from decoder, combinational) ---
    input  logic        v86_mode,          // Only active in V86 mode
    input  logic        query_io_valid,    // Decoder sees IN/OUT
    input  logic [15:0] query_io_port,     // Port address
    input  logic        query_io_is_write, // OUT vs IN
    input  logic        query_int_valid,   // Decoder sees INT n
    input  logic [7:0]  query_int_vector,  // INT vector number

    // --- Result ---
    output logic        io_is_safe,        // This I/O port is on the safe list
    output logic        int_is_safe,       // This INT vector is on the safe list
    output logic [7:0]  fast_ucode_base,   // Microcode ROM base address for fast handler

    // --- Safe-List Programming (from microcode/supervisor) ---
    input  logic        cfg_we,            // Write enable
    input  logic        cfg_is_int,        // 0 = I/O port entry, 1 = INT entry
    input  logic [3:0]  cfg_slot,          // Slot index (0-15 for IO, 0-7 for INT)
    input  logic [15:0] cfg_port,          // Port address (for IO entries)
    input  logic        cfg_port_allow_wr, // Allow writes to this port?
    input  logic [7:0]  cfg_int_vector,    // INT vector (for INT entries)
    input  logic        cfg_enable         // Enable/disable this slot
);

    // =========================================================================
    // I/O Port Safe-List (16 entries)
    // =========================================================================
    localparam int IO_SAFE_ENTRIES = 16;

    typedef struct packed {
        logic        enabled;
        logic [15:0] port_addr;
        logic        allow_write;   // 1 = OUT allowed, 0 = IN only
    } io_safe_entry_t;

    io_safe_entry_t io_safe [IO_SAFE_ENTRIES];

    // Default safe ports (initialized at reset, can be reconfigured)
    // These are the most commonly trapped V86 I/O ports in DOS:
    localparam logic [15:0] PORT_VGA_STATUS = 16'h03DA;  // VGA input status reg 1
    localparam logic [15:0] PORT_VGA_ATTR_R = 16'h03C1;  // VGA attribute read
    localparam logic [15:0] PORT_PIT_CNT0   = 16'h0040;  // PIT counter 0 read
    localparam logic [15:0] PORT_PIT_CNT2   = 16'h0042;  // PIT counter 2 read
    localparam logic [15:0] PORT_KBD_STATUS = 16'h0064;  // Keyboard status
    localparam logic [15:0] PORT_KBD_DATA   = 16'h0060;  // Keyboard data
    localparam logic [15:0] PORT_PIC1_CMD   = 16'h0020;  // PIC1 command (EOI)
    localparam logic [15:0] PORT_GAME_PORT  = 16'h0201;  // Game port

    // =========================================================================
    // INT Vector Safe-List (8 entries)
    // =========================================================================
    localparam int INT_SAFE_ENTRIES = 8;

    typedef struct packed {
        logic       enabled;
        logic [7:0] vector;
    } int_safe_entry_t;

    int_safe_entry_t int_safe [INT_SAFE_ENTRIES];

    // Default safe INTs: video BIOS, timer, keyboard
    localparam logic [7:0] INT_VIDEO    = 8'h10;  // INT 10h (video BIOS)
    localparam logic [7:0] INT_TIMER    = 8'h08;  // INT 08h (timer)
    localparam logic [7:0] INT_KEYBOARD = 8'h09;  // INT 09h (keyboard)
    localparam logic [7:0] INT_DISK     = 8'h13;  // INT 13h (disk BIOS)
    localparam logic [7:0] INT_DOS      = 8'h21;  // INT 21h (DOS services)

    // =========================================================================
    // Reset and Configuration
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize I/O safe-list with common DOS ports
            for (int i = 0; i < IO_SAFE_ENTRIES; i++) begin
                io_safe[i].enabled    <= 1'b0;
                io_safe[i].port_addr  <= 16'h0;
                io_safe[i].allow_write <= 1'b0;
            end
            // Pre-load first 8 entries with defaults
            io_safe[0]  <= '{1'b1, PORT_VGA_STATUS, 1'b0};  // Read-only
            io_safe[1]  <= '{1'b1, PORT_VGA_ATTR_R, 1'b0};
            io_safe[2]  <= '{1'b1, PORT_PIT_CNT0,   1'b0};
            io_safe[3]  <= '{1'b1, PORT_PIT_CNT2,   1'b0};
            io_safe[4]  <= '{1'b1, PORT_KBD_STATUS,  1'b0};
            io_safe[5]  <= '{1'b1, PORT_KBD_DATA,    1'b0};
            io_safe[6]  <= '{1'b1, PORT_PIC1_CMD,    1'b1};  // Write allowed (EOI)
            io_safe[7]  <= '{1'b1, PORT_GAME_PORT,   1'b0};

            // Initialize INT safe-list
            for (int i = 0; i < INT_SAFE_ENTRIES; i++) begin
                int_safe[i].enabled <= 1'b0;
                int_safe[i].vector  <= 8'h0;
            end
            int_safe[0] <= '{1'b1, INT_VIDEO};
            int_safe[1] <= '{1'b1, INT_TIMER};
            int_safe[2] <= '{1'b1, INT_KEYBOARD};
            int_safe[3] <= '{1'b1, INT_DISK};
            int_safe[4] <= '{1'b1, INT_DOS};
        end else if (cfg_we) begin
            if (!cfg_is_int && cfg_slot < IO_SAFE_ENTRIES[3:0]) begin
                io_safe[cfg_slot].enabled    <= cfg_enable;
                io_safe[cfg_slot].port_addr  <= cfg_port;
                io_safe[cfg_slot].allow_write <= cfg_port_allow_wr;
            end else if (cfg_is_int && cfg_slot < INT_SAFE_ENTRIES[3:0]) begin
                int_safe[cfg_slot].enabled <= cfg_enable;
                int_safe[cfg_slot].vector  <= cfg_int_vector;
            end
        end
    end

    // =========================================================================
    // Combinational Lookup
    // =========================================================================
    // I/O port safe check: CAM match against all entries
    logic io_match;
    always_comb begin
        io_match = 1'b0;
        if (v86_mode && query_io_valid) begin
            for (int i = 0; i < IO_SAFE_ENTRIES; i++) begin
                if (io_safe[i].enabled &&
                    io_safe[i].port_addr == query_io_port &&
                    (!query_io_is_write || io_safe[i].allow_write)) begin
                    io_match = 1'b1;
                end
            end
        end
    end

    // INT vector safe check
    logic int_match;
    always_comb begin
        int_match = 1'b0;
        if (v86_mode && query_int_valid) begin
            for (int i = 0; i < INT_SAFE_ENTRIES; i++) begin
                if (int_safe[i].enabled &&
                    int_safe[i].vector == query_int_vector) begin
                    int_match = 1'b1;
                end
            end
        end
    end

    assign io_is_safe  = io_match;
    assign int_is_safe = int_match;

    // Fast microcode base address: offset into the ROM for safe-trap handlers
    // IO safe-traps start at ROM base 0x80, INT safe-traps at 0xC0
    // Each handler is a short micro-op sequence (4-8 steps)
    always_comb begin
        fast_ucode_base = 8'h00;
        if (io_match)
            fast_ucode_base = 8'h80;  // Safe I/O handler base
        else if (int_match)
            fast_ucode_base = 8'hC0;  // Safe INT handler base
    end

endmodule
