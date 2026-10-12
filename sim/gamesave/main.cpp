// Headless NES game-pattern sim: the real nestang core (nestang_top built for
// Verilator: 6502, PPU, APU, the MMC1 mapper, GameLoader) runs a small battery
// game (mkrom.py) from the ROM image, and this driver watches what its save RAM
// does: the save_written strobe nestang_top hands to iosys (-> the 0x0B notice),
// and the SDRAM model's bytes at the WRAM window (linear 0x3C0000), where the
// save channel reads them.
//
//   boot 1: blank WRAM (0xFF, as the firmware's blank restore leaves it):
//           the game finds no signature and writes its save.
//   boot 2: WRAM restored from boot 1's image: the game finds the signature
//           (reads the save back) and writes only its $77 marker.
//
// usage: gamesave +rom=<hex> +size=<n>     exit status 0 = all checks passed
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "Vnestang_top.h"
#include "Vnestang_top_nestang_top.h"
#include "verilated.h"

static const uint32_t WRAM = 0x3C0000;      // where the mappers put $6000-$7FFF
static const uint32_t WRAM_SIZE = 0x2000;

struct Run {
    uint64_t writes = 0;                    // save_written rising edges (= CPU writes to $6000-$7FFF)
    uint64_t strobe_cycles = 0;
    std::vector<uint8_t> wram;
};

// One boot of the cartridge. `image` is the WRAM content at power-on.
static Run boot(int argc, char **argv, const std::vector<uint8_t> &image, uint64_t cycles) {
    Verilated::commandArgs(argc, argv);
    Vnestang_top *top = new Vnestang_top;
    auto *r = top->nestang_top;
    Run run;
    for (uint32_t i = 0; i < WRAM_SIZE; i++)
        r->sdram__DOT__mem_cpu[WRAM + i] = image[i];

    bool prev = false;
    for (uint64_t t = 0; t < cycles; t++) {
        top->sys_clk = 0;
        top->eval();
        top->sys_clk = 1;
        top->eval();
        bool sw = r->save_written;
        if (sw && !prev)
            run.writes++;
        if (sw)
            run.strobe_cycles++;
        prev = sw;
    }
    run.wram.resize(WRAM_SIZE);
    for (uint32_t i = 0; i < WRAM_SIZE; i++)
        run.wram[i] = r->sdram__DOT__mem_cpu[WRAM + i];
    top->final();
    delete top;
    return run;
}

static int fails = 0;
static void check(bool ok, const char *what) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok)
        fails++;
}

int main(int argc, char **argv) {
    const uint64_t CYCLES = 8000000;        // 0.37 s of NES time: load + init, with room to spare
    std::vector<uint8_t> blank(WRAM_SIZE, 0xFF);

    printf("boot 1: blank save RAM\n");
    Run a = boot(argc, argv, blank, CYCLES);
    printf("  save_written: %llu writes (%llu strobe cycles)\n",
           (unsigned long long)a.writes, (unsigned long long)a.strobe_cycles);
    check(a.wram[0] == 0x5A && a.wram[1] == 0xA5, "signature written to $6000-$6001");
    bool pat = true;
    for (int x = 2; x < 256; x++)
        pat = pat && a.wram[x] == (uint8_t)(x ^ 0x3C) && a.wram[0x100 + x] == (uint8_t)(x ^ 0x3C);
    check(pat, "pattern written to $6002-$60FF and $6102-$61FF, in SDRAM at 0x3C0000");
    check(a.wram[0x400] == 0x11 && a.wram[0x1FFF] == 0x11, "$6400 marker and $7FFF written");
    check(a.wram[0x300] == 0xFF && a.wram[0x1000] == 0xFF, "untouched WRAM stays as restored");
    // 2 signature bytes + 2 x 254 pattern bytes + $6400 + $7FFF = 512 writes
    check(a.writes == 512, "save_written pulsed once per WRAM write (512), and not for the MMC1 register writes");

    printf("boot 2: save restored from boot 1\n");
    Run b = boot(argc, argv, a.wram, CYCLES);
    printf("  save_written: %llu writes\n", (unsigned long long)b.writes);
    check(b.wram[0x400] == 0x77, "the game read its save back (found the signature: $77 marker)");
    check(memcmp(b.wram.data(), a.wram.data(), 0x400) == 0 &&
          memcmp(b.wram.data() + 0x401, a.wram.data() + 0x401, WRAM_SIZE - 0x401) == 0,
          "the restored save is otherwise untouched");
    check(b.writes == 1, "only the marker write was announced");

    printf(fails ? "FAILED (%d)\n" : "all passed\n", fails);
    return fails ? 1 : 0;
}
