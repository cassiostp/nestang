#!/bin/sh
# NES audio sample-format sim (iverilog). From the repo root:
#   docker run --rm --name <p>_audio --user $(id -u):$(id -g) \
#     -v $PWD:/w -w /w/sim/audio tangcore-iv:1 sh run.sh
# extract.pl (perl, in the image) makes iverilog copies of the real mixer
# modules under build/; the grep gates at the end tie the bench's conversion
# functions to the expressions actually in nes.v / nestang_top.sv.
set -e
cd "$(dirname "$0")"
RTL=../../src
perl extract.pl $RTL
iverilog -g2012 -o tb_audio_format.out tb_audio_format.v build/audio_modules.v
vvp tb_audio_format.out
grep -q "{1'b0, sample_inverted\[15:1\]}" $RTL/nes.v
grep -q "{~sample\[15\], sample\[14:0\]}" $RTL/nestang_top.sv
# ext_audio may list only mappers with a live mixer in cart.sv: selecting
# a mapper with none reads the undriven cart audio bus (0), which the top
# converts to -32768 DC. This bench checks 19 (N163) and 69 (SS5B);
# sim/mappers checks MMC5 (5) and VRC6 (24/26). VRC (24/26/85) is listed
# only on the boards that build it.
grep -q "assign ext_audio = (mapper_flags\[7:0\] == 5) | (mapper_flags\[7:0\] == 19) | (mapper_flags\[7:0\] == 24) | (mapper_flags\[7:0\] == 26) | (mapper_flags\[7:0\] == 69) | (mapper_flags\[7:0\] == 85);" $RTL/nestang_top.sv
grep -q "assign ext_audio = (mapper_flags\[7:0\] == 5) | (mapper_flags\[7:0\] == 19) | (mapper_flags\[7:0\] == 69);" $RTL/nestang_top.sv
echo "run.sh: conversions in nes.v and nestang_top.sv match the bench"
