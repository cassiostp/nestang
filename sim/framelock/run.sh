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
# Usage: ./run.sh [standard|hz120|both] (default: both).
# The standard run covers the console138k and console60k PLL clocks; the
# hz120 run covers only console138k (the 855-pixel line is too fast for the
# 60K NES clock to lock) and exercises every BFI mode
# (video_config[21:20]): mode 1 in run-in/pause/reset, mode 0 in the first
# 200-frame run, mode 2 in the second, mode 3 (rolling) in the final
# 150-frame run.
#
# Afterwards (host): python3 sim/framelock/check_audio.py \
#   sim/framelock/build-standard/audio_hdmi_138k.hex sim/framelock/build-standard/tb_138k.log \
#   sim/framelock/build-standard/audio_hdmi_60k.hex sim/framelock/build-standard/tb_60k.log
# and for hz120: python3 sim/framelock/check_audio.py \
#   sim/framelock/build-hz120/audio_hdmi_138k-hz120.hex sim/framelock/build-hz120/tb_138k-hz120.log
set -e
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
RTL=../../src
SCN=../scanlines
# Runner: simrun when present (persistent ccache + full-core env), else plain docker.
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")};
# ccache: simrun mounts a persistent /ccache (CCACHE_DIR), so the Verilator
# build caches there; without it there is no cache to keep, so keep the old
# disable. (The generated makefiles already prefix compiles with $(OBJCACHE),
# which defaults to ccache: nothing else to set.)
case "$DOCKER_RUN" in *simrun*) CCACHE_OFF=;; *) CCACHE_OFF="-e CCACHE_DISABLE=1";; esac

run_variant() {
    # $1 = standard | hz120
    V="$1"
    B="build-$V"
    TAG_SFX=""
    EXTRA_ARG=""
    if [ "$V" = hz120 ]; then
        TAG_SFX="-hz120"
        EXTRA_ARG="hz120"
    fi
    IV="$DOCKER_RUN --name ${SIM_PREFIX:-sim$$}_r6hznes_lock_${V}_iv --user $(id -u):$(id -g) -v $ROOT:/w -w /w/sim/framelock tangcore-iv:1"
    VLT="$DOCKER_RUN --name ${SIM_PREFIX:-sim$$}_r6hznes_lock_${V}_vlt --user $(id -u):$(id -g) $CCACHE_OFF -v $PWD:/w -v $ROOT:/r -w /w verilator/verilator:latest"
    # (verilator resolves file arguments against -Mdir, so absolute paths)
    VSRC=/r/src
    VSCN=/r/sim/scanlines
    # ClockGen is the real scanline/cycle counter from src/ppu.v, extracted at
    # build time (the rest of ppu.v uses array literals iverilog cannot parse).
    # Regenerated every run, so it cannot go stale; the greps fail the run if
    # the extraction misses.
    mkdir -p "$B"
    awk '/^module ClockGen/,/^endmodule/' $RTL/ppu.v > "$B/clockgen_sim.v"
    grep -q '^module ClockGen' "$B/clockgen_sim.v"
    grep -q 'even_frame_toggle' "$B/clockgen_sim.v"
    grep -q 'assign short_frame' "$B/clockgen_sim.v"
    grep -q "vblank_end_sl   = 9'd260" $RTL/ppu.v
    cp "$RTL/assets/background.txt" "$B/background.txt"
    $IV sh -c "iverilog -g2012 -I /w/src/variant/$V -o $B/tb_iv.out tb_frame_lock.v /w/src/nes2hdmi.sv $B/clockgen_sim.v /w/src/scanlines.v /w/src/video_fx.v /w/sim/scanlines/hdmi_stub.v"
    echo "iverilog elaboration ($V): ok"
    $VLT --cc --top-module fl_top --prefix Vfl_top -Mdir "$B/obj" -CFLAGS "-O2" \
      "+incdir+$VSRC/variant/$V" \
      -Wno-PINMISSING -Wno-IMPLICIT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN \
      /w/fl_top.sv $VSRC/nes2hdmi.sv $VSRC/ppu.v $VSRC/scanlines.v $VSRC/video_fx.v $VSCN/hdmi_stub.v \
      --exe /w/tb_frame_lock.cpp > "$B/verilate.log" 2>&1 || { cat "$B/verilate.log"; exit 1; }
    if grep -E "fl_top|tb_frame_lock" "$B/verilate.log"; then echo "new warnings in sim files:"; cat "$B/verilate.log"; exit 1; fi
    $DOCKER_RUN --name "${SIM_PREFIX:-sim$$}_r6hznes_lock_${V}_make" --user "$(id -u):$(id -g)" -v "$PWD:/w" -v "$ROOT:/r" -w /w --entrypoint make verilator/verilator:latest \
      -C "$B/obj" -f Vfl_top.mk -j20 > "$B/make.log" 2>&1 || { tail -30 "$B/make.log"; exit 1; }
    run_cfg() {
        # $1 = clk_half_ps, $2 = pix_half_ps, $3 = tag
        $DOCKER_RUN --name "${SIM_PREFIX:-sim$$}_r6hznes_lock_${V}_$3" --user "$(id -u):$(id -g)" -v "$PWD/$B:/w" -w /w --entrypoint ./obj/Vfl_top verilator/verilator:latest \
          "$1" "$2" "$3" $EXTRA_ARG || { tail -20 "$B/tb_$3.log"; exit 1; };
        grep -q "^tb_frame_lock: PASS" "$B/tb_$3.log"
    }
    if [ "$V" = hz120 ]; then
        # console138k PLL: clk 50*40/93 MHz. Pixel clock half-period 9259 ps =
        # 54 MHz (480p120). Only the 138K config runs here: the 855-pixel line
        # is too fast for the 60K NES clock to lock (free-run 60.1379 Hz
        # against 60.1504 Hz needed).
        run_cfg 23250 9259 "138k$TAG_SFX"
        echo "run.sh (hz120): 138K clock config PASS (60K cannot lock this rate)"
    else
        # console138k PLL: clk 50*40/93 MHz; console60k PLL: clk 50*49/(2*57) MHz
        run_cfg 23250 6734 "138k$TAG_SFX"
        run_cfg 23266 6734 "60k$TAG_SFX"
        echo "run.sh (standard): both clock configs PASS"
    fi
}

VAR="${1:-both}"
case "$VAR" in
    standard|hz120) run_variant "$VAR";;
    both) run_variant standard; run_variant hz120;;
    *) echo "usage: $0 [standard|hz120|both]" >&2; exit 2;;
esac
