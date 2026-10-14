#!/bin/sh
# Frame-lock sims.
#
# tb_frame_lock.v is the reference bench (iverilog): the real nes2hdmi
# against a cycle-exact PPU-timing model over 650 NES frames with a menu
# pause, a core reset and another pause. iverilog is too slow for the full
# run here, so run.sh uses it as an elaboration check, and runs the full 650
# frames per clock config under Verilator (fl_top.sv + tb_frame_lock.cpp: the
# same DUT, model and checks, engine only).
#
# From the repo root (COMMON.md docker patterns):
#   docker run --rm --name nestear_lock --user $(id -u):$(id -g) \
#     -v $PWD:/w -w /w/sim/framelock tangcore-iv:1 sh run.sh
# Afterwards (host): python3 check_audio.py build/audio_hdmi_138k.hex \
#   build/audio_hdmi_60k.hex
set -e
cd "$(dirname "$0")"
RTL=../../src
SCN=../scanlines
# ClockGen is the real scanline/cycle counter from src/ppu.v, extracted at
# build time (the rest of ppu.v uses array literals iverilog cannot parse).
# Regenerated every run, so it cannot go stale; the greps fail the run if the
# extraction misses.
mkdir -p build
awk '/^module ClockGen/,/^endmodule/' $RTL/ppu.v > build/clockgen_sim.v
grep -q '^module ClockGen' build/clockgen_sim.v
grep -q 'even_frame_toggle' build/clockgen_sim.v
grep -q 'assign short_frame' build/clockgen_sim.v
grep -q 'vblank_end_sl   = 9._d260' $RTL/ppu.v
cp $RTL/assets/background.txt build/background.txt
common="$RTL/nes2hdmi.sv build/clockgen_sim.v $RTL/scanlines.v $RTL/video_fx.v $RTL/smooth.v $SCN/hdmi_stub.v"
iverilog -g2012 -o build/tb_138k.out tb_frame_lock.v $common
echo "iverilog elaboration: ok"
VLT="docker run --rm --user $(id -u):$(id -g) -e CCACHE_DISABLE=1 -v $PWD:/w -w /w verilator/verilator:latest"
$VLT --cc --top-module fl_top --prefix Vfl_top -Mdir build/obj -CFLAGS "-O2" \
  -Wno-PINMISSING -Wno-IMPLICIT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN \
  fl_top.sv $RTL/nes2hdmi.sv $RTL/ppu.v $RTL/scanlines.v $RTL/video_fx.v $RTL/smooth.v $SCN/hdmi_stub.v \
  --exe tb_frame_lock.cpp > build/verilate.log 2>&1 || { cat build/verilate.log; exit 1; }
if grep -E "fl_top|tb_frame_lock" build/verilate.log; then echo "new warnings in sim files:"; cat build/verilate.log; exit 1; fi
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/w" -w /w --entrypoint make verilator/verilator:latest \
  -C build/obj -f Vfl_top.mk -j20 > build/make.log 2>&1 || { tail -30 build/make.log; exit 1; }
# console138k PLL: clk 50*40/93 MHz; console60k PLL: clk 50*49/(2*57) MHz
(cd build && ./obj/Vfl_top 23250 6734 138k) || { tail -20 build/tb_138k.log; exit 1; }
grep -q "^tb_frame_lock: PASS" build/tb_138k.log
(cd build && ./obj/Vfl_top 23266 6734 60k) || { tail -20 build/tb_60k.log; exit 1; }
grep -q "^tb_frame_lock: PASS" build/tb_60k.log
echo "run.sh: both clock configs PASS"
