#!/bin/sh
# Headless NES game-pattern sim (Verilator, via docker). From this directory:
#   ./run.sh      build the real core with a test loader, run the battery game
# Output goes to build/ (git-ignored). The only docker use is Verilator itself.
set -e
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../.." && pwd)
# Runner: simrun when present (persistent ccache + full-core env), else plain docker.
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")};
# ccache: simrun mounts a persistent /ccache (CCACHE_DIR), so the Verilator
# build caches there; without it there is no cache to keep, so keep the old
# disable. (The generated makefiles already prefix compiles with $(OBJCACHE),
# which defaults to ccache: nothing else to set.)
case "$DOCKER_RUN" in *simrun*) CCACHE_OFF=;; *) CCACHE_OFF="-e CCACHE_DISABLE=1";; esac
mkdir -p "$here/build"
python3 "$here/mkrom.py" "$here/build/game.hex" "$here/build/game.nes"
size=$(wc -c < "$here/build/game.nes")
# Verilator 5 rejects Mapper28's stray `output prg_allow` port, which also has a
# wire of the same name (Gowin accepts it). Sim copy without the port; the
# diff is the only change.
sed -e '/^\toutput       prg_allow,$/d' "$src/src/mappers/generic.sv" > "$here/build/generic_sim.sv"
! grep -q "output       prg_allow," "$here/build/generic_sim.sv"
test $(diff "$src/src/mappers/generic.sv" "$here/build/generic_sim.sv" | grep -c '^[<>]') -eq 1
D=/src/src
$DOCKER_RUN --user "$(id -u):$(id -g)" $CCACHE_OFF \
    -v "$src:/src:ro" -v "$here:/gs:ro" -v "$here/build:/out" -w /out \
    verilator/verilator:latest \
    --cc --exe --build -j "${JOBS:-$(nproc)}" --top-module nestang_top --public-flat-rw \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-CASEOVERLAP -Mdir obj -o gamesave \
    -I$D -CFLAGS -O2 \
    $D/verilator/config.sv $D/verilator/sdram_sim.v $D/apu.v $D/cart.sv $D/compat.v $D/dpram.v \
    $D/EEPROM_24C0x.sv $D/nestang_top.sv $D/nes.v $D/ppu.v \
    $D/t65/T65_Pack.v $D/t65/T65_ALU.v $D/t65/T65_MCode.v $D/t65/T65.v \
    $D/game_loader.v /gs/game_data_sim.v \
    /out/generic_sim.sv $D/mappers/iir_filter.v $D/mappers/JYCompany.sv $D/mappers/misc.sv \
    $D/mappers/MMC1.sv $D/mappers/MMC2.sv $D/mappers/MMC3.sv $D/mappers/MMC5.sv $D/mappers/Namco.sv \
    $D/mappers/Sachen.sv $D/mappers/Sunsoft.sv /gs/main.cpp > "$here/build/verilate.log" 2>&1 \
    || { tail -40 "$here/build/verilate.log"; exit 1; }
    $DOCKER_RUN --user "$(id -u):$(id -g)" -v "$here/build:/out" -w /out --entrypoint /out/obj/gamesave \
    verilator/verilator:latest +rom=/out/game.hex +size=$size
