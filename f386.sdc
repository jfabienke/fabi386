# fabi386: Timing Constraints for DE10-Nano (MiSTer)
# ===================================================

# Input clock: 50 MHz from DE10-Nano oscillator
create_clock -name CLK_50M -period 20.000 [get_ports CLK_50M]

# PLL-generated clocks (derived automatically by Quartus from PLL)
# These are informational — Quartus derives them from the PLL IP.
# If using a manual PLL, uncomment and adjust:
# create_generated_clock -name cpu_clk   -source [get_ports CLK_50M] -divide_by 3 -multiply_by 2 [get_pins pll_inst|*|clk[0]]
# create_generated_clock -name pixel_clk -source [get_ports CLK_50M] -divide_by 2 -multiply_by 1 [get_pins pll_inst|*|clk[1]]
# create_generated_clock -name mem_clk   -source [get_ports CLK_50M] -divide_by 1 -multiply_by 2 [get_pins pll_inst|*|clk[2]]

# CPU clock domain (~33.333 MHz, period = 30 ns)
# Target: 140 MHz post-optimization = 7.14 ns. Start conservative.
derive_pll_clocks
derive_clock_uncertainty

# False paths between clock domains
set_false_path -from [get_clocks {pll_inst|*|clk[0]}] -to [get_clocks {pll_inst|*|clk[1]}]
set_false_path -from [get_clocks {pll_inst|*|clk[1]}] -to [get_clocks {pll_inst|*|clk[0]}]

# DDRAM interface timing (relaxed — HPS bridge handles synchronization)
set_false_path -from * -to [get_ports DDRAM_*]
set_false_path -from [get_ports DDRAM_*] -to *

# VGA output timing (directly active in pixel clock domain)
set_output_delay -clock [get_clocks {pll_inst|*|clk[1]}] -max 5.0 [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS VGA_DE}]
set_output_delay -clock [get_clocks {pll_inst|*|clk[1]}] -min 0.0 [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS VGA_DE}]

# Multicycle paths for slow peripherals (optional, helps Fmax)
# PIT divider chain: 2-cycle path
# set_multicycle_path -setup 2 -from [get_registers {pit|*counter*}] -to [get_registers {pit|*counter*}]
