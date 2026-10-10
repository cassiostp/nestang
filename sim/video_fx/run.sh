#!/bin/sh
# video_fx sims (iverilog). From this directory:  ./run.sh
#   tb_iosys_video_config  iosys command 0x13
#   tb_video_fx     video_fx against the golden model (model.py)
#   tb_nes_regress  nes2hdmi against the scaler before video_fx: identical with no filter on
#   tb_nes_fx       the filters inside nes2hdmi, checked against the model
#   tb_smooth_regress  nes2hdmi against the scaler before smoothing: identical with smoothing off
#   tb_nes_smooth   the smoothing inside nes2hdmi, checked against the model
# prep.sh (python3, git) makes the vectors and the baseline; with a simulator image that has
# neither, run prep.sh on the host first and `python3 -I model.py check nes_fx.log` and
# `python3 -I model.py check_smooth nes_smooth.log nes_src.hex` after.
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    sh prep.sh
fi
test -f vec_case.hex -a -f build/nes2hdmi_base.sv -a -f build/nes2hdmi_fx.sv
: > background.txt          # nes2hdmi loads its frame buffer from this at start

# iosys command 0x13 (a sim copy with the "input reg" port Gowin tolerates softened, like sim/saveram)
sed -e 's/input reg  \[7:0\] kbd_data/input [7:0] kbd_data/' \
    -e 's/^\( *\)kbd_data <= rx_data;/\1;                       \/\/ sim: kbd path idle/' \
    $RTL/iosys/iosys_bl616.v > build/iosys_sim.v
iverilog -g2012 -DSIM -o tb_iosys_video_config.out tb_iosys_video_config.v build/iosys_sim.v $RTL/iosys/uart_fixed.v
vvp tb_iosys_video_config.out

iverilog -g2012 -o tb_video_fx.out tb_video_fx.v $RTL/video_fx.v $RTL/scanlines.v
vvp tb_video_fx.out

iverilog -g2012 -o tb_nes_regress.out tb_nes_regress.v $HDMI $RTL/nes2hdmi.sv $RTL/scanlines.v \
    $RTL/video_fx.v $RTL/smooth.v build/nes2hdmi_base.sv build/scanlines_base.v
vvp tb_nes_regress.out

iverilog -g2012 -o tb_nes_fx.out tb_nes_fx.v $HDMI $RTL/nes2hdmi.sv $RTL/scanlines.v $RTL/video_fx.v $RTL/smooth.v
vvp tb_nes_fx.out

iverilog -g2012 -o tb_smooth_regress.out tb_smooth_regress.v $HDMI $RTL/nes2hdmi.sv $RTL/scanlines.v \
    $RTL/video_fx.v $RTL/smooth.v build/nes2hdmi_fx.sv
vvp tb_smooth_regress.out

iverilog -g2012 -o tb_nes_smooth.out tb_nes_smooth.v $HDMI $RTL/nes2hdmi.sv $RTL/scanlines.v $RTL/video_fx.v $RTL/smooth.v
vvp tb_nes_smooth.out
if command -v python3 >/dev/null 2>&1; then
    python3 -I model.py check nes_fx.log
    python3 -I model.py check_smooth nes_smooth.log nes_src.hex
else
    echo "NOTE: python3 not found, run: python3 -I model.py check nes_fx.log"
    echo "NOTE: and: python3 -I model.py check_smooth nes_smooth.log nes_src.hex"
fi
