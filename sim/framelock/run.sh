#!/bin/sh
# Frame-lock sims. Runs on the host (like sim/cosim/Makefile); each engine
# step is wrapped in its own container (COMMON.md docker patterns).
#
# tb_frame_lock.v is the reference bench (iverilog): the real nes2hdmi
# against a cycle-exact PPU-timing model over 650 NES frames with a menu
# pause, a core reset and another pause. iverilog is too slow for the full
# run here, so it serves as an elaboration check, and the full 650 frames
# per clock config run under Verilator (fl_top.sv + tb_frame_lock.cpp: the
# same DUT, model and checks, engine only). Verilator 5.052 elaborates the
# real src/ppu.v (array literals and all), so no extraction is needed there.
#
# Usage (repo root): sh sim/framelock/run.sh
# Afterwards (host): python3 sim/framelock/check_audio.py \
#   sim/framelock/build/audio_hdmi_138k.hex sim/framelock/build/tb_138k.log \
#   sim/framelock/build/audio_hdmi_60k.hex sim/framelock/build/tb_60k.log
set -e
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
RTL=../../src
SCN=../scanlines
IV="docker run --rm --name framelock_iv --user $(id -u):$(id -g) -v $ROOT:/w -w /w/sim/framelock tangcore-iv:1"
VLT="docker run --rm --name framelock_vlt --user $(id -u):$(id -g) -e CCACHE_DISABLE=1 -v $PWD:/w -v $ROOT:/r -w /w verilator/verilator:latest"
# (verilator resolves file arguments against -Mdir, so absolute paths)
VSRC=/r/src
VSCN=/r/sim/scanlines
# ClockGen is the real scanline/cycle counter from src/ppu.v, extracted at
# build time (the rest of ppu.v uses array literals iverilog cannot parse).
# Regenerated every run, so it cannot go stale; the greps fail the run if the
# extraction misses.
mkdir -p build
awk '/^module ClockGen/,/^endmodule/' $RTL/ppu.v > build/clockgen_sim.v
grep -q '^module ClockGen' build/clockgen_sim.v
grep -q 'even_frame_toggle' build/clockgen_sim.v
grep -q 'assign short_frame' build/clockgen_sim.v
grep -q "vblank_end_sl   = 9'd260" $RTL/ppu.v
cp $RTL/assets/background.txt build/background.txt
$IV sh -c "iverilog -g2012 -o build/tb_138k.out tb_frame_lock.v $RTL/nes2hdmi.sv build/clockgen_sim.v $RTL/scanlines.v $RTL/video_fx.v $RTL/smooth.v $SCN/hdmi_stub.v"
echo "iverilog elaboration: ok"
$VLT --cc --top-module fl_top --prefix Vfl_top -Mdir build/obj -CFLAGS "-O2" \
  -Wno-PINMISSING -Wno-IMPLICIT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN \
  /w/fl_top.sv $VSRC/nes2hdmi.sv $VSRC/ppu.v $VSRC/scanlines.v $VSRC/video_fx.v $VSRC/smooth.v $VSCN/hdmi_stub.v \
  --exe /w/tb_frame_lock.cpp > build/verilate.log 2>&1 || { cat build/verilate.log; exit 1; }
if grep -E "fl_top|tb_frame_lock" build/verilate.log; then echo "new warnings in sim files:"; cat build/verilate.log; exit 1; fi
docker run --rm --name framelock_make --user "$(id -u):$(id -g)" -v "$PWD:/w" -v "$ROOT:/r" -w /w --entrypoint make verilator/verilator:latest \
  -C build/obj -f Vfl_top.mk -j20 > build/make.log 2>&1 || { tail -30 build/make.log; exit 1; }
# console138k PLL: clk 50*40/93 MHz; console60k PLL: clk 50*49/(2*57) MHz
docker run --rm --name framelock_138k --user "$(id -u):$(id -g)" -v "$PWD:/w" -w /w/build --entrypoint ./obj/Vfl_top verilator/verilator:latest \
  23250 6734 138k || { tail -20 build/tb_138k.log; exit 1; };
grep -q "^tb_frame_lock: PASS" build/tb_138k.log
docker run --rm --name framelock_60k --user "$(id -u):$(id -g)" -v "$PWD:/w" -w /w/build --entrypoint ./obj/Vfl_top verilator/verilator:latest \
  23266 6734 60k || { tail -20 build/tb_60k.log; exit 1; }
grep -q "^tb_frame_lock: PASS" build/tb_60k.log
echo "run.sh: both clock configs PASS"
