Read the project-wide rules first: https://github.com/cassiostp/tangcore/blob/main/AGENTS.md

# nestang — NES core

NES for the Tang Console 138K/60K. Port of `nand2mario/nestang` (cycle-accurate NES, mappers through MMC5/VRC); the README still documents the legacy standalone builds, TangCore is the install path.

## Layout

- Top: `src/nestang_top.sv` (`module nestang_top`), machine `src/nes.v`, PPU `src/ppu.v`, cart `src/cart.sv`, mappers `src/mappers/*.sv`, APU `src/apu.v`.
- Video: scaler `src/nes2hdmi.sv` (720p framebuffer + frame lock) into `src/hdmi2/` (`hdmi.sv`, `serializer.sv`, `tmds_channel.sv`, packet/audio helpers); helpers `src/scanlines.v`, `src/video_fx.v`.
- Memory: `src/sdram_nes.v` (dual-channel CL2 SDRAM, `FREQ 64_800_000`); board wrappers `src/boards/*.v` set `configPackage` (16-bit, ROW 13, COL 9).
- iosys: `src/iosys/iosys_bl616.v` is the build's copy (plus `gowin_dpb_menu.v`, `textdisp.v`, `uart_fixed.v`). `src/iosys/iosys_picorv32.v` exists but is not in `build.tcl`.
- PLLs: `src/pll/` for GW5AST-138 (`gowin_pll_27/33/hdmi/nes`, `pll_12.v`), `src/plla/` for GW5A-25/60K, `src/pllr/` (`rPLL`) for nano20k.

## Building

```tcl
gw_sh build.tcl <device> [<controller>]   # device: nano20k primer25k mega60k mega138k console60k console138k; controller: snes ds2 (default ds2)
```

`console138k` is ds2-only (`src/boards/console138k.v` + `src/boards/console.cst` + `src/pll/*` + `usb_hid_host.v`); `console60k` picks `console.cst` or `console60k_snescontroller.cst` by controller. Mega/nano/primer targets remain in the file but are not the TangCore work.

CI (from tangcore's `ci/core-builds` branch):

```sh
gh workflow run cores.yml -R cassiostp/tangcore --ref ci/core-builds -f core=nestang -f ref=<branch> -f board=console138k
```

The artifact is `nestang-<board>/nestang.bin` plus timing/utilisation reports; the build fails on any setup/hold violation.

Build variants: `TANGCORE_VARIANT` unset/empty/`standard` is the normal 720p
build; `TANGCORE_VARIANT=hz120` (console138k only, anything else is an error)
builds the 480p 120 Hz bitstream instead (shipped as `nestang_120hz.bin`).
The variant is printed as `TangCore variant:` in the build log; the RTL
difference is gated on `` `ifdef HZ120 `` (see `src/variant/`). CI:
`-f variant=hz120` (refuses if `build.tcl` has no variant support).

## Clocks and constraints

- One SDC serves every GW5 board: `src/nestang.sdc` constrains at the faster 138K PLL rates (`sys_clk` 50 MHz, `fclk` 64.5161 MHz, `clk = fclk/3` 21.5054 MHz, `hclk5` 371.25 MHz). The 60K/25K PLLs run 0.07% slower, inside the margin. `src/boards/nano20k.sdc` is nano-only.
- There is no `console138k.sdc`/`console60k.sdc` in this repo; `build.tcl` adds `src/nestang.sdc` for all GW5 targets.
- PLLs: `gowin_pll_nes` (`50 MHz -> fclk/clk`), `gowin_pll_27` (`50 -> 27 MHz`), `gowin_pll_hdmi` (`27 -> hclk5`), `pll_12` (12 MHz USB). `IOSYS_FREQ` is 21_505_376 on 138K, 21_491_228 on 60K (`nestang_top.sv`).

## Native-rate lock

HDMI runs at the NES rate, not 60.00 Hz: `NATIVE_LINE = 1647` in `src/nes2hdmi.sv` (74.25 MHz / (1647x750) = 60.1093 Hz). `std_timing = 1` selects the standard 1650-pixel line; `video_std_timing` is tied `1'b0` in `src/nestang_top.sv`, so the build is native-only until a menu option is added.
Halt at NES scanline 240 (`HALT_LINE`), release at HDMI row 647 (`RELEASE_ROW`) in `src/nes2hdmi.sv`; `frame_halt` pauses the CPU/PPU (`nes.v`) once per frame.

## Firmware link

- Core ID 1 (`CORE_ID(1)` in `src/nestang_top.sv`; `core/cores.cpp` in firmware maps 1 to `nestang.bin`).
- Save channel `SAVE_IF=1, SAVE_AW=13, SAVE_SYNC=0`: 8 KB WRAM through SDRAM port 3 (`sv_req`/`sv_ack`, dirty flag `save_written`); UART commands `0x11` restore / `0x12` dump / `0x0A` block / `0x0B` dirty / `0x17` link resync (drops TX state).
- `core_config` bits used: `[17]` menu pause, `[16]` scanlines, `[19:18]` darkness, `[20]` thick, `[21]` scale (0 integer, 1 full); `video_config` drives `src/video_fx.v`.
- `iosys_bl616.v` is one of six divergent copies (`cassiostp/tangcore#30`): a fix to one usually belongs in the others.

## Simulations (`sim/*/README.md` says how to run; iverilog in `tangcore-iv:1`)

Sim scripts use `simrun` when it is on PATH (else `docker run --rm`);
set `SIM_PREFIX` to namespace container names when sharing the machine.
`simrun` is an optional local helper (persistent ccache + full-core env),
not part of the repositories.

- `audio`: mixer silence/DC and `FFFF -> halved` sign handling.
- `cosim`: Verilator model of the real `iosys_bl616`+`sdram_nes` for firmware co-sim, no game/video/audio.
- `framelock`: real `nes2hdmi` vs a cycle-exact clock model over 600+ frames at both console clocks.
  `sim/framelock/run.sh [standard|hz120|both]`: the hz120 run is 138k-only at 2x the rate with per-BFI-mode pixel checks.
- `mappers`: VRC24/VRC6/MMC5 banking, audio and multiplier.
- `saveram`: real iosys+sdram+MCU model: restore/dump, `0x0B` dirty, RX-desync and link-soak cases.
- `scanlines`: `scanlines.v` row/darkening plus whole-frame scaler-vs-model checks.
  `sim/scanlines/run.sh [standard|hz120|both]`; the hz120 run also dumps `frames/hz120_*.ppm` (Integer/Full, scanlines on/off, OSD band).
- `tmds`: 2-stage `tmds_channel` vs the pre-split version over 2.5M clocks.
- `usb`: `usb_hid_host.v` against a behavioural low-speed device (plug/sleepy/stall/drop/kbd/mouse/unplug).
- `video_fx`: `0x13` handling, `video_fx` vs `model.py`, regress-vs-git-history with filters off, FX inside `nes2hdmi` (standard variant only; the 720p baselines predate 480p).

## Traps

- `build.tcl` references `mega60k_snescontroller.v/.cst` and `mega138k_snescontroller.v/.cst`, which do not exist under `src/boards/`; the console `snes` files do.
- The 60K/138K difference is device + PLL family + USB, not logic: VRC support is compiled in for mega/console targets (`NESTANG_VRC`), smaller boards leave it out.
- `buildall.bat` passes a controller arg for nano20k, which `build.tcl` ignores (nano supports both controllers at once).
- The `*.gprj` files still point at old paths (`src/console60k/nestang.cst`, `src/primer25k/nestang.sdc`); `build.tcl` is the source of truth.

Run `sh sim/regress.sh quick both` before handing work back; `quick` is the minimum check. Use `full both` for all benches, `--only bench1,bench2` to select, and `--list` for tiers, variants, images and typical times. At most two benches run together; logs and tables are in `sim/.regress/`. `TANGCORE_ROMS` defaults to `~/tangcore-test-bundle/test roms`; missing ROMs and unsupported variants SKIP. Keep ROM-derived output local.
