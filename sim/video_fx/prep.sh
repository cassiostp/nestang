#!/bin/sh
# Host-side preparation for run.sh: needs python3 and git.
#   vec_*.hex           test vectors from the golden model (model.py gen)
#   build/*_base.*      the scaler before video_fx, from git history ($BASE), with the module
#                       names suffixed _base so that both can be in one simulation
#   build/nes2hdmi_fx.sv  the scaler with video_fx and without smoothing ($FXBASE), as nes2hdmi_fx
set -e
cd "$(dirname "$0")"
BASE=${BASE:-861abbe}       # the last commit without video_fx
FXBASE=${FXBASE:-992bc60}   # the last commit without smoothing
python3 -I model.py selfcheck
python3 -I model.py gen
mkdir -p build
git show $BASE:src/nes2hdmi.sv | sed \
    -e 's/^module nes2hdmi (/module nes2hdmi_base (/' \
    -e 's/^sl_rows sl (/sl_rows_base sl (/' \
    -e 's/^sl_dim dim (/sl_dim_base dim (/' > build/nes2hdmi_base.sv
git show $BASE:src/scanlines.v | sed \
    -e 's/^module sl_rows (/module sl_rows_base (/' \
    -e 's/^module sl_dim (/module sl_dim_base (/' > build/scanlines_base.v
git show $FXBASE:src/nes2hdmi.sv | sed -e 's/^module nes2hdmi (/module nes2hdmi_fx (/' > build/nes2hdmi_fx.sv
grep -q '^module nes2hdmi_fx (' build/nes2hdmi_fx.sv
grep -q '^module nes2hdmi_base (' build/nes2hdmi_base.sv
grep -q '^sl_rows_base sl (' build/nes2hdmi_base.sv
grep -q '^sl_dim_base dim (' build/nes2hdmi_base.sv
grep -q '^module sl_rows_base (' build/scanlines_base.v
grep -q '^module sl_dim_base (' build/scanlines_base.v
echo "prep: vectors and baseline from $BASE ready"
