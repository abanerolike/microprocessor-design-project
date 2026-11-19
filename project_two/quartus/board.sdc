create_clock -name CLOCK_50 -period 20 [get_ports CLOCK_50]

# VGA_CLK is a register toggled by CLOCK_50 and driven out of the chip. The DAC takes RGB and BLANK on
# its rising edge. Data registers load only when that register goes low, so the data is launched one
# CLOCK_50 period before the next rising edge of VGA_CLK. VGA_CLK has no fast output register, so k
# stays one register (a copy in the output cell would give the clock two sources).
create_generated_clock -name vga_k -source [get_ports CLOCK_50] -divide_by 2 [get_registers {screen:vg|vga:tm|k}]
create_generated_clock -name vga_clk -source [get_registers {screen:vg|vga:tm|k}] [get_ports VGA_CLK]
derive_clock_uncertainty

# ADV7123: setup 0.5 ns (5 V, 0.2 ns at 3.3 V; the larger is used), hold 1.5 ns; 0.5 ns is an
# assumed allowance for board trace skew
set_output_delay -clock vga_clk -max 1.0 [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_BLANK}]
set_output_delay -clock vga_clk -min -2.0 [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_BLANK}]

# Setup: the default check (launch one CLOCK_50 period before the VGA_CLK edge) is the real one.
# Hold: data never changes on the edge where VGA_CLK rises, so the next launch is one CLOCK_50 later.
set_multicycle_path -hold -start 1 -from [get_clocks CLOCK_50] -to [get_clocks vga_clk]

# HS and VS go to the connector without the DAC; the monitor only needs them within a pixel or so
set_false_path -to [get_ports {VGA_HS VGA_VS}]
