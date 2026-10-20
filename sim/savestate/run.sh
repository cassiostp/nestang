#!/bin/sh
# Save-state A/B determinism sim (Verilator, via docker). From this directory:
#   ./run.sh              synthetic MMC1 + MMC3 cartridges (mkrom.py)
#   SS_ROM=/path/game.nes SS_FRAMES=... ./run.sh
#                         a real NES ROM instead (hex + outputs stay in
#                         build/, git-ignored; never commit them)
# Output goes to build/. The only docker use is Verilator itself.
set -e
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")};
case "$DOCKER_RUN" in *simrun*) CCACHE_OFF=;; *) CCACHE_OFF="-e CCACHE_DISABLE=1";; esac
mkdir -p "$here/build"
python3 "$here/mkrom.py" "$here/build"
sed -e '/^\toutput       prg_allow,$/d' "$src/src/mappers/generic.sv" > "$here/build/generic_sim.sv"
! grep -q "output       prg_allow," "$here/build/generic_sim.sv"
test $(diff "$src/src/mappers/generic.sv" "$here/build/generic_sim.sv" | grep -c '^[<>]') -eq 1
D=/src/src
$DOCKER_RUN --user "$(id -u):$(id -g)" $CCACHE_OFF \
    -v "$src:/src:ro" -v "$here:/gs:ro" -v "$here/build:/out" -w /out \
    verilator/verilator:latest \
    --cc --exe --build -j "${JOBS:-$(nproc)}" --top-module nestang_top --public-flat-rw \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-CASEOVERLAP -Mdir obj -o savestate_sim \
    -I$D -I$D/variant/standard -CFLAGS -O2 \
    $D/verilator/config.sv $D/verilator/sdram_sim.v $D/apu.v $D/cart.sv $D/compat.v $D/dpram.v \
    $D/EEPROM_24C0x.sv $D/nestang_top.sv $D/nes.v $D/ppu.v \
    $D/t65/T65_Pack.v $D/t65/T65_ALU.v $D/t65/T65_MCode.v $D/t65/T65.v \
    $D/game_loader.v /gs/game_data_sim.v \
    /out/generic_sim.sv $D/mappers/iir_filter.v $D/mappers/JYCompany.sv $D/mappers/misc.sv \
    $D/mappers/MMC1.sv $D/mappers/MMC2.sv $D/mappers/MMC3.sv $D/mappers/MMC5.sv $D/mappers/Namco.sv \
    $D/mappers/Sachen.sv $D/mappers/Sunsoft.sv $D/mappers/VRC.sv $D/verilator/eseopll_stub.v /gs/main.cpp > "$here/build/verilate.log" 2>&1 \
    || { tail -40 "$here/build/verilate.log"; exit 1; }

run_one() {
    name="$1"; hex="$2"; size=$(python3 -c "import os;print(os.path.getsize('$3'))")
    echo "--- $name ($size bytes) ---"
    $DOCKER_RUN --user "$(id -u):$(id -g)" -e SS_TRACE="${SS_TRACE:-}" -v "$here/build:/out" -w /out --entrypoint /out/obj/savestate_sim \
        verilator/verilator:latest +rom=/out/$hex +size=$size
}

if [ -n "${SS_ROM:-}" ]; then
    python3 -c "
import sys
data = open(sys.argv[1], 'rb').read()
with open(sys.argv[2], 'w') as f:
    for b in data: f.write('%02x\n' % b)
" "$SS_ROM" "$here/build/real.hex"
    cp "$SS_ROM" "$here/build/real.nes"
    run_one "real ROM" real.hex "$here/build/real.nes"
else
    run_one "synthetic MMC1" m1.hex "$here/build/m1.nes"
    run_one "synthetic MMC3" m3.hex "$here/build/m3.nes"
fi
echo "run.sh: done"
