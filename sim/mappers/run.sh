#!/bin/sh
# VRC/MMC5 regression (iverilog). From the repo root:
#   docker run --rm --name <p>_mappers --user $(id -u):$(id -g) \
#     -v $PWD:/w -w /w/sim/mappers tangcore-iv:1 sh run.sh
# The VRC7 OPLL is VHDL, so simulation uses src/verilator/eseopll_stub.v
# (VRC7 FM is silent in sim; the Gowin builds use the real VM2413).
# The grep gates below tie the bench's wiring to cart.sv / build.tcl /
# nestang_top.sv, since Icarus cannot elaborate the full cart.sv.
set -e
cd "$(dirname "$0")"
RTL=../../src
iverilog -g2012 -s tb_cart_vrc_mmc5 -o tb_cart_vrc_mmc5.out \
	tb_cart_vrc_mmc5.v \
	$RTL/verilator/eseopll_stub.v \
	$RTL/mappers/MMC5.sv $RTL/mappers/VRC.sv
vvp tb_cart_vrc_mmc5.out | tee tb_cart_vrc_mmc5.log
grep -q "^PASS tb_cart_vrc_mmc5" tb_cart_vrc_mmc5.log
grep -q "^MMC5 mmc5(" $RTL/cart.sv
grep -q "^VRC24 vrc24(" $RTL/cart.sv
grep -q "^VRC6 vrc6(" $RTL/cart.sv
grep -q "^VRC7 vrc7(" $RTL/cart.sv
grep -q "^vrc6_mixed snd_vrc6" $RTL/cart.sv
grep -q "^vrc7_mixed snd_vrc7" $RTL/cart.sv
grep -q "src/mappers/VRC.sv" ../../build.tcl
grep -q "src/opll/eseopll.vhd" ../../build.tcl
grep -q "mapper_flags\[7:0\] == 5" $RTL/nestang_top.sv
grep -q "mapper_flags\[7:0\] == 85" $RTL/nestang_top.sv
echo "run.sh: cart.sv, build.tcl and nestang_top.sv wiring matches the bench"
