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
# a sim copy of the ACR packet with its counter width as a plain constant
# (Verilator cannot fold the real-typed cast; values are the bench's
# 148.5 MHz / 48 kHz ones: IDEAL = 148500, width = clog2(148500 * 1.1) = 18)
sed -e "s/^localparam bit \[19:0\] CYCLE_TIME_STAMP_COUNTER_IDEAL.*/localparam bit [19:0] CYCLE_TIME_STAMP_COUNTER_IDEAL = 20'd148500;/" \
    -e "s/^localparam int CYCLE_TIME_STAMP_COUNTER_WIDTH.*/localparam int CYCLE_TIME_STAMP_COUNTER_WIDTH = 18;/" \
    $RTL/audio_clock_regeneration_packet.sv > build/audio_clock_regeneration_packet_sim.sv
grep -q "20'd148500" build/audio_clock_regeneration_packet_sim.sv
verilator --binary --timing --top-module tb_hdmi_packets -Mdir build/obj_hdmi \
    -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN \
    -Wno-CASEINCOMPLETE -Wno-PINMISSING -Wno-IMPLICIT -Wno-REALCVT -Wno-ALWCOMBORDER -Wno-COMBDLY \
    tb_hdmi_packets.v $RTL/hdmi.sv $RTL/packet_picker.sv $RTL/packet_assembler.sv \
    $RTL/tmds_channel.sv $RTL/serializer.sv build/audio_clock_regeneration_packet_sim.sv \
    $RTL/audio_sample_packet.sv $RTL/audio_info_frame.sv \
    $RTL/auxiliary_video_information_info_frame.sv $RTL/source_product_description_info_frame.sv
./build/obj_hdmi/Vtb_hdmi_packets
