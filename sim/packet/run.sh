#!/bin/sh
# packet_assembler (src/hdmi2) with shift registers against the module as it was before,
# built from git history ($BASE, the 720p120 branch tip before the rewrite) as
# packet_assembler_old (needs git; without it run the git/sed lines on the host first).
# From this directory:  ./run.sh
# Verilator, not iverilog: both module versions assign whole parity arrays,
# which Icarus does not support. In the verilator container:
#   docker run --rm --user $(id -u):$(id -g) -e CCACHE_DISABLE=1 -v <repo>:/w \
#     -w /w/sim/packet --entrypoint sh verilator/verilator:latest run.sh
set -e
cd "$(dirname "$0")"
RTL=../../src/hdmi2
BASE=${BASE:-9655c9c}
if command -v git >/dev/null 2>&1; then
    mkdir -p build
    git show $BASE:src/hdmi2/packet_assembler.sv | sed -e 's/^module packet_assembler (/module packet_assembler_old (/' > build/packet_assembler_old.sv
    grep -q '^module packet_assembler_old' build/packet_assembler_old.sv
fi
verilator --binary --timing --top-module tb_packet_assembler -Mdir build/obj \
    -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
    tb_packet_assembler.v build/packet_assembler_old.sv $RTL/packet_assembler.sv
./build/obj/Vtb_packet_assembler
