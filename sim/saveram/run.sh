#!/bin/sh
# Battery-save sims (iverilog). From this directory:
#   ./run.sh              compile and run all four testbenches
# Gowin tolerates the "input reg"/"inout reg" port declarations in the sources;
# iverilog does not, so run.sh compiles sim-only copies with those softened.
set -e
RTL=../../src
sed -e 's/input reg  \[7:0\] kbd_data/input [7:0] kbd_data/' \
    -e 's/^\( *\)kbd_data <= rx_data;/\1;                       \/\/ sim: kbd path idle/' \
    $RTL/iosys/iosys_bl616.v > iosys_sim.v
sed -e 's/inout  reg \[SDRAM_DATA_WIDTH-1:0\] SDRAM_DQ/inout [SDRAM_DATA_WIDTH-1:0] SDRAM_DQ/' \
    $RTL/sdram_nes.v > sdram_nes_sim.v
iverilog -g2012 -DSIM -o tb_saveram.out \
    tb_saveram.v iosys_sim.v $RTL/iosys/uart_fixed.v $RTL/dpram.v
vvp tb_saveram.out
iverilog -g2012 -DSIM -o tb_saveram_sdram.out \
    tb_saveram_sdram.v iosys_sim.v $RTL/iosys/uart_fixed.v
vvp tb_saveram_sdram.out
iverilog -g2012 -DSIM -o tb_sdram_save.out \
    tb_sdram_save.v sdram_nes_sim.v
vvp tb_sdram_save.out
# System test: real iosys + real sdram_nes + NES-like traffic + an MCU model.
# The sim copy shortens iosys's 20 ms joypad rate limit so pad changes are due
# within ~0.5 ms of sim time.
sed -e 's|localparam JOY_UPDATE_INTERVAL = 50_000_000 / 50;|localparam JOY_UPDATE_INTERVAL = 10_000;|' \
    iosys_sim.v > iosys_sys_sim.v
grep -q "JOY_UPDATE_INTERVAL = 10_000" iosys_sys_sim.v
iverilog -g2012 -DSIM -o tb_system_save.out \
    tb_system_save.v sdram_nes_sim.v iosys_sys_sim.v $RTL/iosys/uart_fixed.v
vvp tb_system_save.out
