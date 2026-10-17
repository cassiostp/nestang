# NES game-pattern sim (`sim/gamesave`)

The real core, running a battery game. `nestang_top` built for Verilator
(6502, PPU, APU, GameLoader and the MMC1 mapper), fed a ROM that behaves like
The Legend of Zelda at power-on, with a driver that watches the save RAM. It
answers "does a real game's write reach the save RAM and raise the dirty
notice?" without a cartridge or hardware.

```bash
./run.sh       # needs docker (Verilator) and python3; ~1 min
```

`mkrom.py` builds the cartridge: mapper 1 (MMC1), 128 KB PRG, CHR RAM,
battery bit. Its 6502 code resets MMC1 and writes the control, CHR and PRG
registers through the serial port (5 writes each, PRG-RAM enabled), looks for
a signature at `$6000`, and either writes a save (signature, a pattern over
`$6002-$60FF` and `$6102-$61FF`, markers at `$6400` and `$7FFF`) or, finding
the signature, writes only a `$77` marker.

`main.cpp` boots it twice:

1. WRAM blank (0xFF, as the firmware's blank restore leaves it): checks the
   bytes land in the SDRAM model at linear `0x3C0000`, where `sdram_nes`'s
   save channel reads them, and that `save_written` (the strobe iosys turns
   into the 0x0B notice) pulses once per WRAM write: 512 times, and not for the
   MMC1 register writes at `$8000-$FFFF`.
2. WRAM restored from boot 1: the game finds its signature (it read the save
   back) and writes only the marker, announced once.

Build-time notes. Verilator 5 rejects Mapper28's `output prg_allow` port,
which also has a same-named wire (Gowin accepts it); `run.sh` builds from a
copy without the port and checks the diff is that one line.
`game_data_sim.v` replaces `src/game_data.v` so the ROM comes from the command
line. The SDRAM is `src/verilator/sdram_sim.v`, a flat model: the iosys and
`sdram_nes` save channel are covered by `sim/saveram` and `sim/cosim`.

The MMC1 in this core ignores the PRG-RAM enable bit (bit 4 of the PRG
register): `$6000-$7FFF` always routes to WRAM. Writes are therefore never
dropped by a game that disables the RAM, which is the permissive direction.
