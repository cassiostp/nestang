// NES clocks. One SDC serves every board, so constrain at the faster 138K
// PLL rates: fclk 50*40/31 = 64.5161 Mhz, clk = fclk/3 = 21.5054 Mhz. The
// 60K/25K PLLs run 0.07% slower (64.4737 / 21.4912 Mhz), inside this margin.
create_clock -name sys_clk -period 20 [get_nets {sys_clk}]       // 50 Mhz
create_clock -name fclk -period 15.50 [get_nets {fclk}]          // 64.5161 Mhz (138K)
create_generated_clock -name clk -source [get_nets {fclk}] -divide_by 3 [get_nets {clk}] // 21.5054 Mhz (138K)

// HDMI clocks (hz120 variant: hclk5 is the 270 MHz x5 clock of the 54 MHz pixel clock)
create_clock -name hclk5 -period 3.7037 [get_nets {hclk5}]       // 270 Mhz (hz120 480p120)

// NES/iosys to SDRAM, 3 fclk cycles
set_multicycle_path 3 -end -setup -from [get_clocks {clk}] -to [get_clocks {fclk}]
set_multicycle_path 2 -end -hold -from [get_clocks {clk}] -to [get_clocks {fclk}]

// SDRAM to NES/iosys, 2 fclk cycles
set_multicycle_path 2 -start -setup -from [get_clocks {fclk}] -to [get_clocks {clk}]
set_multicycle_path 1 -start -hold -from [get_clocks {fclk}] -to [get_clocks {clk}]

# report_timing -hold -from_clock [get_clocks {clk*}] -to_clock [get_clocks {clk*}] -max_paths 25 -max_common_paths 1
# report_timing -setup -from_clock [get_clocks {clk*}] -to_clock [get_clocks {clk*}] -max_paths 25 -max_common_paths 1
