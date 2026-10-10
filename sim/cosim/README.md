# NES co-simulation (`sim/cosim`)

A Verilator model of nestang's real firmware-facing interface logic — the
`iosys_bl616` UART protocol engine (with OSD text) and the `sdram_nes`
controller (with the battery-save client) — for the TangCore firmware
co-simulation (see firmware `host/README.md`, "RTL backend"). No game, no
video, no audio: it exercises firmware↔core interactions (combos and pad
frames during play, battery-save dumps/restores, reset, MODE, core_config
bits) without hardware.

## Layout

- `cosim_top.sv` — the small top: real `iosys_bl616` (as
  `iosys_bl616_cosim`, generated, see below) + real `sdram_nes` wired
  exactly as `nestang_top` wires them, plus sim-only surroundings:
  behavioral SDRAM chip (`sdram_chip.sv`), NES-like CPU/PPU traffic with a
  game WRAM-write hook (`poke_*`, `churn_en`), a ROM byte sink, MODE
  silencing, and a `tx_pending` output so the bridge never jumps over a
  reply owed by the model. Clocks and reset come from C++ (`fclk` = 3×
  `clk`, coincident rising edges; `hclk` tied to `clk`: the render pipeline
  is unobserved, OSD text is snapshotted straight out of the DPB array).
- `sdram_chip.sv` — behavioral 16-bit SDRAM: the exact command subset
  `sdram_nes` issues (ACT, single-word READ/WRITE with auto-precharge,
  DQM-masked writes, CL2 reads; refresh/mode-set/precharge ignored).
  Powers up all-`0xFF`, retains contents across reset (external chip).
- `gowin/` — behavioural stand-ins for Gowin primitives, shared by every
  testbench and cosim target in this core: currently only the DPB behind
  `gowin_dpb_menu` (OSD text buffer; zero-init, render side unmodelled).
  Other cores copy this directory (their DPB/RAM wrappers differ, the
  stand-in shape does not).
- `Makefile` — `make model` (docker Verilator) builds
  `build/obj/Vcosim_top__ALL.a` + `build/runtime/` (Verilator headers) for
  the firmware to link with `-DNESTANG_COSIM_DIR`; `make lint` elaborates
  under iverilog (docker); `make clean`. `build/` is git-ignored.

## Generated sources (build-time, never committed)

`build/gen/` holds mechanical copies of real sources, each verified by the
build (grep checks + printed diff):

- `iosys_bl616_cosim.v` — from `src/iosys/iosys_bl616.v`, with exactly
  three changes: module renamed, the `CORE_ID` parameter deleted and added
  as the `cosim_core_id` input (programming the model answers as the
  programmed core; every reply byte stays DUT-generated), the `tx_data <=
  CORE_ID[7:0]` use pointed at it — plus the two `run.sh`-style softeners
  (`input reg` kbd port, idle kbd path) that non-Gowin tools need.
- `sdram_nes_sim.v`, `uart_fixed_sim.v` — from the same-named sources:
  `inout reg` softening, and the dummy `ASSERTION_ERROR` instances (which
  iverilog discards with the false generate branch but Verilator
  elaborates) replaced by empty begins. No functional change.
- The verilate line waives five style warnings (`-Wno-PINMISSING` etc.)
  that the core's own RTL carries; the log is then grepped for any waived
  warning naming `cosim_top`, `sdram_chip` or `gowin_dpb` (a missing pin in
  our wiring once hid an unconnected `SDRAM_DQM`, which wrote both byte
  lanes on every write — the waivers must never cover our files).

## Tests

- `../saveram/run.sh` (iverilog, docker): the three battery-save unit
  testbenches plus `tb_system_save.v` — real iosys + real sdram_nes with
  NES-like traffic and an MCU model dumping while polling core ID, sending
  HID and pressing pads. It fails on the pre-fix iosys (dropped HID/0x12
  frames, unanswered polls, stalled dumps) and passes after commit
  `36578ba`.
- The firmware `r-*.script` suite (`bash host/run-tests.sh --rtl` over in
  the firmware worktree): menu combo and reset combo during a dump with
  the game writing WRAM, save round trip, core_config bits, MODE — all
  through the real serial link at the real baud.

## Porting to another core (for the SNES/MD/SMS/GBA agent)

Copy this directory, then adjust only what is core-specific (details and
rationale in the co-sim report):

1. `cosim_top.sv`: the iosys parameters (`CORE_ID`, `SAVE_IF`, `SAVE_AW`,
   `SAVE_SYNC`), the SDRAM controller instance and its port map, the
   traffic generator shape, the WRAM window base/width, the `tx_pending`
   hierarchical references (same signal names — verify), the ROM sink.
2. `Makefile`: the `CORE_ID` sed anchor (default value differs), source
   file list, `config.sv` widths.
3. Firmware `host/sim/backend_rtl/model_<core>.cpp` (new, ~120 lines):
   Verilated header names, OSD array path, SDRAM array path, save base,
   clock ratio. `backend_rtl.cpp` stays untouched.
4. `host/run-tests.sh`: an `s-*`/`m-*`/… suite following `r-*` with that
   core's ROM/save fixtures.
