# video_fx sims (`sim/video_fx`)

Testbenches for `src/video_fx.v` (colour controls, CRT mask, LCD grid), `src/smooth.v`
(picture smoothing) and their integration in `nes2hdmi`. iverilog; `./run.sh` runs
everything.

| test | what it checks |
| --- | --- |
| `tb_iosys_video_config.v` | iosys command `0x13` through the real UART receiver: sets `video_config` big-endian, leaves `core_config` alone (and the other way round), ignores other commands, reset clears it |
| `tb_video_fx.v` | the module alone, against `model.py`: every brightness / contrast / saturation / gamma, every mask type and strength with the LCD grid off and at its four strengths, and 300 random settings with random pictures, borders, scanline darkening and grid flags |
| `tb_nes_regress.v` | `nes2hdmi` against the scaler before `video_fx` (built from git history by `prep.sh`): with a `video_config` that enables nothing (`0`, the firmware's all-off `0x00012000`, and `0x0003A000` with the grid bit the NES ignores) the rgb stream into the hdmi module is identical clock for clock, two whole frames per scanline mode, with the menu overlay up or not |
| `tb_nes_fx.v` + `model.py check` | the filters running inside `nes2hdmi`: the pixels going in and coming out of `video_fx` are logged with their output position and compared with the model, so the mask lands on the right columns and rows, the scanline darkening follows the colour stage, and the border and the overlay stay untouched |
| `tb_smooth_regress.v` | `nes2hdmi` against the scaler before smoothing (`nes2hdmi_fx`, built from git history by `prep.sh`): with `video_config[19:18]` clear (`0`, or the reserved `3`) and the other filters on or off, the rgb stream into the hdmi module is identical clock for clock, two whole frames per scanline mode; with the menu overlay up it is identical in every smoothing mode |
| `tb_nes_smooth.v` + `model.py check_smooth` | the smoothing running inside `nes2hdmi`, both modes, both geometries (960x720, and 896x672 with scanlines), scanlines and the other filters on or off, overlay up or not: the frame buffer holds a random picture (dumped to `nes_src.hex`), the pixels going into and coming out of `video_fx` are logged with their output position on the top and bottom 50 rows and every 7th, and compared with the model: the blend of the source pixels, the picture window, the border, the scanline flags and the filters acting on the smoothed picture |

`model.py` is the golden model, written from the spec (the `video_config` table in the header of
`video_fx.v`, the definition of the smoothing in the header of `smooth.v`), not from the Verilog; `model.py selfcheck` also compares it with
real-number arithmetic and a few hand-computed values. `tools/video_fx_gamma.py`
generates the gamma tables inside `video_fx.v` (`--check` tells whether the file
is up to date); the model computes the tables itself.

`prep.sh` needs python3 and git (vectors from the model, the baseline scalers
from `$BASE`, the last commit without `video_fx`, and `$FXBASE`, the last without smoothing). The simulator image used on
arm64 (`tangcore-iv:1`) has neither: run `sh prep.sh` on the host, then
`docker run --rm --user $(id -u):$(id -g) -v $PWD/../..:/w -w /w/sim/video_fx tangcore-iv:1 sh run.sh`
and `python3 -I model.py check nes_fx.log` and `python3 -I model.py check_smooth nes_smooth.log nes_src.hex` on the host.
