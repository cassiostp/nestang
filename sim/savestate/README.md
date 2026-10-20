# Save-state A/B determinism sim

Proves the core save-state implementation (`src/savestate.v` + the `ss_*`
register bus in nes/ppu/apu/t65/cart) by execution identity, modeled on
sim/gamesave: the real `nestang_top` under Verilator with a ROM-driven
loader (`game_data_sim.v`) and a behavioral SDRAM.

    ./run.sh        # synthetic MMC1 + MMC3 cartridges from mkrom.py

Each run boots the cartridge, hashes the PPU color + APU sample stream
per vblank-to-vblank window, saves through the real engine (driven over
its image channel exactly as iosys drives it on hardware), keeps running,
then in a fresh boot loads the image and checks that the following 30
windows hash identically and that CPU-RAM/CIRAM/CARTRAM/CHR match at the
aligned endpoint. A wrong-header load must be rejected without changing
the trajectory. Inputs come from a fixed script indexed by the ROM's own
frame counter, so all runs see the same pads.

The synthetic cartridges (`mkrom.py`) evolve every subsystem per frame:
scrolling, OAM DMA, sprite motion, CHR-RAM writes (MMC1), WRAM writes,
bank switches, MMC3 scanline IRQ, APU square/triangle/noise and (MMC3)
a looping DMC sample.

## Real games

    SS_ROM="/path/to/game.nes" ./run.sh

runs the same proof on a real ROM. The hex conversion and the ROM copy
land in `build/` (git-ignored). Never commit, push or upload a ROM or
anything derived from one.

`SS_TRACE=1` additionally steps fresh A/B sims in lockstep from the
save/load point and dumps CPU/PPU/mapper/SDRAM state at the first
differing tick — the debug tool that localized the SDRAM output-register
restore (`sd_douta/sd_doutb` image bytes + `ss_edge_reset`).
