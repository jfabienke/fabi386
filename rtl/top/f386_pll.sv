/*
 * fabi386: PLL Configuration for DE10-Nano
 * -------------------------------------------
 * Generates required clock domains from the 50 MHz FPGA input clock:
 *   - CPU clock: ~33-40 MHz initially (scale up post-boot)
 *   - Pixel clock: 25.175 MHz (VGA 640x480@60Hz / 640x400@70Hz)
 *   - Memory clock: 100 MHz (for SDRAM/DDRAM interface)
 *
 * Uses Cyclone V ALTPLL megafunction (inferred by Quartus).
 * In MiSTer framework, the actual PLL is usually instantiated in
 * the emu module using the pll template. This module provides the
 * parameterizable wrapper.
 */

module f386_pll (
    input  logic         inclk0,      // 50 MHz input from DE10-Nano oscillator

    output logic         cpu_clk,     // CPU core clock (~33 MHz)
    output logic         pixel_clk,   // VGA pixel clock (25.175 MHz)
    output logic         mem_clk,     // Memory interface clock (100 MHz)
    output logic         locked       // PLL is locked and stable
);

    // For synthesis, Quartus will replace this with actual ALTPLL IP.
    // For simulation, generate approximate clocks.

    `ifdef SYNTHESIS

    // Quartus ALTPLL instantiation placeholder
    // The actual PLL is configured via the MiSTer sys/pll.v framework
    // with parameters set in the .qsf file.
    //
    // Typical MiSTer PLL configuration:
    //   inclk0 = 50 MHz
    //   c0 = 33.333 MHz (CPU)
    //   c1 = 25.175 MHz (VGA pixel)
    //   c2 = 100.000 MHz (memory)

    altera_pll #(
        .fractional_vco_multiplier ("false"),
        .reference_clock_frequency ("50.0 MHz"),
        .operation_mode            ("direct"),
        .number_of_clocks          (3),
        // Integer Hz values — Quartus 17 fitter rejects non-achievable
        // fractional MHz specifications. 25170068 Hz is the nearest
        // realizable value to 25.175 MHz from a 50 MHz reference
        // (VGA spec tolerance is wide enough to accept this).
        .output_clock_frequency0   ("33333333 Hz"),
        .output_clock_frequency1   ("25170068 Hz"),
        .output_clock_frequency2   ("100000000 Hz"),
        .phase_shift0              ("0 ps"),
        .phase_shift1              ("0 ps"),
        .phase_shift2              ("0 ps"),
        .duty_cycle0               (50),
        .duty_cycle1               (50),
        .duty_cycle2               (50)
    ) u_pll (
        .refclk   (inclk0),
        .rst      (1'b0),
        .outclk   ({mem_clk, pixel_clk, cpu_clk}),
        .locked   (locked),
        .fboutclk (),
        .fbclk    (1'b0)
    );

    `else

    // Simulation: simple clock dividers (not cycle-accurate)
    assign locked = 1'b1;

    // CPU clock: ~33 MHz from 50 MHz (divide by 1.5 ≈ toggle every 15ns)
    logic cpu_div;
    initial cpu_div = 0;
    always @(posedge inclk0) cpu_div <= ~cpu_div;
    assign cpu_clk = cpu_div;

    // Pixel clock: ~25 MHz from 50 MHz (divide by 2)
    logic pix_div;
    initial pix_div = 0;
    always @(posedge inclk0) pix_div <= ~pix_div;
    assign pixel_clk = pix_div;

    // Memory clock: same as input for simulation
    assign mem_clk = inclk0;

    `endif

endmodule
