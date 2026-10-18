#!/bin/sh
# Scanline sims (iverilog). Usage: ./run.sh [standard|hz120|both] (default: both).
# Run inside tangcore-iv:1 (see AGENTS.md), e.g.:
#   docker run --rm --name r6hznes_scan --user $(id -u):$(id -g) -v $PWD/../..:/w \
#     -w /w/sim/scanlines tangcore-iv:1 sh run.sh both
#   tb_scanlines     the row generator and the darkening (src/scanlines.v, variant-free)
#   tb_nes_scaler    nes2hdmi whole frames, with a stub for the HDMI part
# The hz120 run also dumps sim frames to frames/hz120_*.ppm.
set -e
cd "$(dirname "$0")"
RTL=../../src
VAR="${1:-both}"
run_variant() {
    # $1 = variant
    iverilog -g2012 -o "tb_scanlines_$1.out" tb_scanlines.v "$RTL/scanlines.v"
    vvp "tb_scanlines_$1.out"
    mkdir -p frames
    iverilog -g2012 -I "$RTL/variant/$1" -o "tb_nes_scaler_$1.out" tb_nes_scaler.v hdmi_stub.v \
        "$RTL/nes2hdmi.sv" "$RTL/scanlines.v" "$RTL/video_fx.v"
    vvp "tb_nes_scaler_$1.out"
}
case "$VAR" in
    standard|hz120) run_variant "$VAR";;
    both) run_variant standard; run_variant hz120;;
    *) echo "usage: $0 [standard|hz120|both]" >&2; exit 2;;
esac
echo "run.sh ($VAR): PASS"
