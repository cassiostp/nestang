#!/bin/sh
# tmds_channel (src/hdmi2) in three register stages against the module as it was before the
# split, built from git history ($BASE, the last commit before the split) as tmds_channel_old
# (needs git; without it run the git/sed lines on the host first). From this directory:  ./run.sh
set -e
cd "$(dirname "$0")"
RTL=../../src/hdmi2
BASE=${BASE:-a616facf55d5da7c16b666f84d2f3713621103e2}
if command -v git >/dev/null 2>&1; then
    mkdir -p build
    git show $BASE:src/hdmi2/tmds_channel.sv | sed -e 's/^module tmds_channel$/module tmds_channel_old/' > build/tmds_channel_old.sv
    grep -q '^module tmds_channel_old$' build/tmds_channel_old.sv
fi
iverilog -g2012 -o tb_tmds_channel.out tb_tmds_channel.v build/tmds_channel_old.sv $RTL/tmds_channel.sv
vvp tb_tmds_channel.out
