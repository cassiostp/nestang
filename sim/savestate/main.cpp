// Save-state A/B determinism proof: the real nestang core (Verilator) runs
// a test cartridge (mkrom.py: MMC1 or MMC3) whose state evolves every
// frame. This driver hashes the PPU color + APU sample stream per
// vblank-to-vblank window, saves through the real savestate engine
// (src/savestate.v, driven over its image channel exactly as iosys does),
// then in a fresh boot loads the image back and checks that execution
// continues bit-identically: same window hashes and same RAM contents.
// A corrupted-header load must be rejected without disturbing the game.
//
//   Run A: boot, 40 windows, SAVE, continue to save_window+35.
//   Run B: boot, 6 windows, LOAD, continue; windows must match A's from
//          the capture window on, RAMs must match at the aligned endpoint.
//   Run R: boot, corrupt-header LOAD attempt, abort; trajectory must
//          still match A's from the start.
//
// usage: savestate_sim +rom=<hex> +size=<n>   exit 0 = all checks passed
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include <cstdlib>

#include "Vnestang_top.h"
#include "Vnestang_top_nestang_top.h"
#include "Vnestang_top_NES.h"
#include "verilated.h"

static int fails = 0;
static void check(bool ok, const char *what) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) fails++;
}

struct Sim {
    Vnestang_top *top;
    Vnestang_top_nestang_top *r;
    uint64_t hash = 1469598103934665603ull;
    int prev_scanline = -1;
    std::vector<uint64_t> windows;   // completed vblank-to-vblank hashes
    int frame = 0;                   // input-script index (per completed window)

    explicit Sim(Vnestang_top *t) : top(t), r(t->nestang_top) {}

    // Input script: bit 0 of the joypad serial stream, a fixed
    // pseudo-random sequence shared by every run, indexed by the *machine*
    // frame counter (CPU RAM $10, bumped by the ROM's NMI handler) so a
    // loaded run gets the same inputs as the reference run did at the
    // same machine frame.
    void apply_input() {
        static const uint32_t kScript = 0x9E3779B9u;
        uint32_t mf = r->sdram__DOT__mem_cpu[0x380010];
        r->joypad1_data = (uint8_t)(((kScript >> (mf & 31)) ^ (mf >> 3)) & 1u);
    }

    void tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            apply_input();
            top->sys_clk = 0;
            top->eval();
            top->sys_clk = 1;
            top->eval();
            observe();
        }
    }

    // Optional per-tick stream recording for one window (SS_TRACE=1):
    // packed {scanline[8:0], color[5:0], sample[15:0]} per master clock.
    int trace_window = -1;
    std::vector<uint32_t> trace;

    void observe() {
        int sl = r->scanline;
        if (!r->ss_freeze && trace_window == (int)windows.size())
            trace.push_back(((uint32_t)sl << 22) | ((uint32_t)r->color << 16) |
                            (uint16_t)r->sample);
        if (!r->ss_freeze) {
            uint64_t v = (uint64_t)r->color | ((uint64_t)(uint16_t)r->sample << 6) |
                         ((uint64_t)(sl & 1) << 22);
            hash ^= v;
            hash *= 1099511628211ull;
            if (sl == 241 && prev_scanline != 241) {
                windows.push_back(hash);
                hash = 1469598103934665603ull;
                frame++;
            }
        }
        prev_scanline = sl;
    }

    void run_windows(int count) {
        size_t target = windows.size() + (size_t)count;
        uint64_t guard = 0;
        while (windows.size() < target && guard++ < 400000000ull)
            tick();
    }

    // ---- savestate engine driving (image channel, as iosys does) ----
    uint8_t status_byte(int k) {
        return (uint8_t)(r->ss_status[k >> 2] >> ((k & 3) * 8));
    }
    int status_state() { return status_byte(15) & 7; }
    bool status_error() { return status_byte(1) & 2; }
    bool status_supported() { return status_byte(0) & 1; }
    int status_total_bytes() {
        return ((int)status_byte(4) | ((int)status_byte(5) << 8)) * 512;
    }

    void op(int code) {
        r->ss_op_h = (uint8_t)code;
        r->ss_op_stb_h = 1;
        tick(3);
        r->ss_op_stb_h = 0;
        tick(3);
    }

    bool wait_state(int want, uint64_t max_ticks = 80000000ull) {
        for (uint64_t i = 0; i < max_ticks; i++) {
            if (status_state() == want) return true;
            if (status_error()) return false;
            tick();
        }
        return false;
    }

    bool read_byte(uint32_t addr, uint8_t *out) {
        r->ss_img_raddr_h = addr;
        r->ss_img_rd_stb_h = 1;
        tick(2);
        r->ss_img_rd_stb_h = 0;
        for (int i = 0; i < 200000; i++) {
            if (r->ss_img_rdy) {
                *out = r->ss_img_q;
                r->ss_img_taken_h = 1;
                tick(2);
                r->ss_img_taken_h = 0;
                tick(1);
                return true;
            }
            tick();
        }
        return false;
    }

    void write_byte(uint32_t addr, uint8_t v) {
        r->ss_img_waddr_h = addr;
        r->ss_img_wdin_h = v;
        r->ss_img_wr_stb_h = 1;
        tick(2);
        r->ss_img_wr_stb_h = 0;
        // SDRAM-section writes queue one deep in the engine; pace like the
        // UART would (~100 master cycles per byte at 2 Mbaud).
        tick(100);
    }

    bool save_image(std::vector<uint8_t> *image, int *freeze_window) {
        op(1);                                   // begin-save
        if (!wait_state(2)) return false;        // S_SAVE
        *freeze_window = (int)windows.size();    // capture is in this window
        int total = status_total_bytes();
        if (total < 1024) return false;
        image->resize((size_t)total);
        for (uint32_t a = 0; a < (uint32_t)total; a++)
            if (!read_byte(a, &(*image)[a])) return false;
        op(3);                                   // end
        for (int i = 0; i < 100000 && r->ss_freeze; i++) tick();
        return !r->ss_freeze;
    }

    // Returns: 1 loaded, 0 rejected at header (game untouched), -1 broken.
    int load_image(const std::vector<uint8_t> &image) {
        op(2);                                   // begin-load
        if (!wait_state(3, 2000000)) { op(4); return -1; }   // S_HDR
        for (uint32_t a = 0; a < 512; a++)
            write_byte(a, image[a]);
        // The engine now accepts (reset, then S_LOAD=5) or rejects (error).
        for (uint64_t i = 0; i < 80000000ull; i++) {
            if (status_error()) {
                op(4);
                for (int j = 0; j < 100000 && r->ss_freeze; j++) tick();
                return r->ss_freeze ? -1 : 0;
            }
            if (status_state() == 5) break;
            tick();
            if (i + 1 == 80000000ull) { op(4); return -1; }
        }
        for (uint32_t a = 512; a < image.size(); a++)
            write_byte(a, image[a]);
        op(3);                                   // end
        for (int i = 0; i < 100000 && r->ss_freeze; i++) tick();
        return r->ss_freeze ? -1 : 1;
    }

    std::vector<uint8_t> sdram_region(uint32_t base, uint32_t len) {
        std::vector<uint8_t> out(len);
        for (uint32_t i = 0; i < len; i++)
            out[i] = r->sdram__DOT__mem_cpu[base + i];
        return out;
    }
};

struct Boot {
    Vnestang_top *top;
    Sim *sim;
};

static Boot boot_blank(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vnestang_top *top = new Vnestang_top;
    Boot b{top, new Sim(top)};
    auto *r = b.sim->r;
    for (uint32_t i = 0; i < 0x2000; i++)
        r->sdram__DOT__mem_cpu[0x3C0000 + i] = 0xFF;   // blank battery RAM
    return b;
}

static void teardown(Boot &b) {
    b.top->final();
    delete b.sim;
    delete b.top;
}

static bool regions_equal(Sim *a, Sim *b, const char *what) {
    static const struct { uint32_t base, len; } kRegions[] = {
        {0x380000, 0x800},    // CPU RAM
        {0x300000, 0x800},    // CIRAM
        {0x3C0000, 0x2000},   // CARTRAM (first 8 KB; both test ROMs)
        {0x200000, 0x2000},   // CHR window head (CHR RAM on m1)
    };
    for (auto &rg : kRegions) {
        auto va = a->sdram_region(rg.base, rg.len);
        auto vb = b->sdram_region(rg.base, rg.len);
        if (va != vb) {
            printf("  FAIL %s: SDRAM region %06x differs\n", what, rg.base);
            fails++;
            return false;
        }
    }
    printf("  ok   %s: CPU-RAM/CIRAM/CARTRAM/CHR identical\n", what);
    return true;
}

int main(int argc, char **argv) {
    // ---------- Run A: reference trajectory + save ----------
    printf("run A: boot, save mid-run, continue\n");
    Boot a = boot_blank(argc, argv);
    a.sim->run_windows(40);
    check(a.sim->status_supported(), "mapper reports savestate support");
    check(a.sim->windows.size() >= 40, "run A reached 40 windows");
    std::vector<uint8_t> image;
    int w = -1;
    check(a.sim->save_image(&image, &w), "run A: save completed");
    printf("  info image %zu bytes, captured in window %d\n", image.size(), w);
    check(image.size() >= 5632 && image[0] == 'T' && image[1] == 'C' &&
          image[2] == 'S' && image[3] == 'S', "image header magic + size");
    a.sim->run_windows(35);
    // Snapshot A's RAMs at the aligned endpoint (window w+35 completed ==
    // windows.size() - (40-... ): save happened after 40 windows, freeze in
    // window w (the 41st, index 40 if no window closed during the wait).
    std::vector<uint64_t> hashes_a = a.sim->windows;
    Sim *sim_a = a.sim;

    // ---------- Run B: load and continue ----------
    printf("run B: boot, load, continue\n");
    Boot b = boot_blank(argc, argv);
    b.sim->run_windows(6);
    int lr = b.sim->load_image(image);
    check(lr == 1, "run B: load accepted");
    // Sharp restore check: save again immediately and compare images. Any
    // differing byte is a restore-side bug in that section; identical
    // images with a diverging trajectory means state lives outside the
    // image (an unsaved register somewhere).
    {
        std::vector<uint8_t> image2;
        int w2 = -1;
        check(b.sim->save_image(&image2, &w2), "run B: re-save after load");
        // Informational only: the re-save captures at a different vblank
        // instant after a brief resume, so phase/state-advanced bytes
        // (dividers, sprite shifters, decay timers, anything the resumed
        // cycles touched) legitimately differ. The proof is the window /
        // RAM identity below, not byte identity of a later capture.
        if (image2.size() == image.size()) {
            int diffs = 0, shown = 0;
            for (size_t i = 0; i < image.size(); i++) {
                if (image2[i] != image[i]) {
                    diffs++;
                    if (shown++ < 8)
                        printf("  info image diff @%zu (reg %zu): %02x -> %02x\n",
                               i, i >= 512 ? i - 512 : 0, image[i], image2[i]);
                }
            }
            printf("  info re-save differs in %d byte(s) (capture-point jitter)\n", diffs);
        }
    }
    // First B window after load is the partial capture window; compare the
    // 30 full windows after it against A's from w+1.
    size_t b0 = b.sim->windows.size();
    b.sim->run_windows(31);
    bool hashes_ok = (w >= 0) && (b.sim->windows.size() >= b0 + 31) &&
                     (hashes_a.size() >= (size_t)w + 31);
    if (hashes_ok) {
        for (int i = 0; i < 30; i++) {
            if (b.sim->windows[b0 + 1 + i] != hashes_a[(size_t)w + 1 + i]) {
                printf("  FAIL window %d hash: A=%016llx B=%016llx\n", i,
                       (unsigned long long)hashes_a[(size_t)w + 1 + i],
                       (unsigned long long)b.sim->windows[b0 + 1 + i]);
                hashes_ok = false;
                break;
            }
        }
    }
    check(hashes_ok, "30 post-load windows identical (video+audio stream)");
    // Align RAM compare: B is now at A's window w+31 endpoint only if A also
    // stopped there; A ran 35 past save, so compare after rolling B to the
    // same count and A is already there only when w+31 == 40+35-5... The
    // robust compare: roll B to (w + 35) equivalent = b0+1 + (35 - (w-40))
    // windows total; both sims are live, so just advance B by the delta.
    int a_total = (int)hashes_a.size();          // 40 + 35 (+ maybe 1 in save)
    int b_equiv = (int)b0 + 1 + (a_total - (w + 1));
    if ((int)b.sim->windows.size() < b_equiv)
        b.sim->run_windows(b_equiv - (int)b.sim->windows.size());
    regions_equal(sim_a, b.sim, "run A vs B at aligned endpoint");
    teardown(b);

    // ---------- Run R: corrupted header must not disturb ----------
    printf("run R: corrupted-header load is rejected cleanly\n");
    std::vector<uint8_t> bad = image;
    if (bad.size() > 8) bad[8] ^= 0xFF;          // mapper_flags byte 0
    Boot c = boot_blank(argc, argv);
    c.sim->run_windows(6);
    int rr = c.sim->load_image(bad);
    check(rr == 0, "run R: load rejected at header");
    c.sim->run_windows(14);
    bool r_ok = c.sim->windows.size() >= 20 && hashes_a.size() >= 20;
    if (r_ok)
        for (int i = 0; i < 20; i++)
            if (c.sim->windows[i] != hashes_a[i]) { r_ok = false; break; }
    check(r_ok, "run R: trajectory unchanged after rejected load");
    teardown(c);
    teardown(a);

    // Optional divergence localisation: step fresh A/B sims in lockstep
    // from the save/load point and dump machine state at the first tick
    // whose (scanline, color, sample) stream differs.
    if (getenv("SS_TRACE")) {
        Boot a2 = boot_blank(argc, argv);
        a2.sim->run_windows(40);
        std::vector<uint8_t> img2;
        int w2 = -1;
        a2.sim->save_image(&img2, &w2);
        Boot b2 = boot_blank(argc, argv);
        b2.sim->run_windows(6);
        b2.sim->load_image(img2);
        auto pack = [](Sim *s) {
            return ((uint32_t)s->r->scanline << 22) | ((uint32_t)s->r->color << 16) |
                   (uint16_t)s->r->sample;
        };
        auto dump = [](const char *tag, Sim *s) {
            auto *n = s->r->nes;
            printf("%s PC=%04x A=%02x X=%02x Y=%02x S=%04x P=%02x IR=%02x MCyc=%u divcpu=%u divppu=%u loopy=%04x loopy_v=%04x loopy_t=%04x "
                   "ppucyc=%u chraout=%06x chr0=%02x chr1=%02x chr2=%02x chr3=%02x chr4=%02x chr5=%02x "
                   "banksel=%u invert=%u irqcnt=%02x latch=%02x a12ctr=%u pipe1=%04x vdin=%02x\n",
                   tag, n->cpu__DOT__PC, n->cpu__DOT__ABC & 0xFF, n->cpu__DOT__X & 0xFF,
                   n->cpu__DOT__Y & 0xFF, n->cpu__DOT__S, n->cpu__DOT__P, n->cpu__DOT__IR,
                   n->cpu__DOT__MCycle, n->div_cpu, n->div_ppu,
                   n->ppu__DOT__loopy, n->ppu__DOT__loopy0__DOT__loopy_v,
                   n->ppu__DOT__loopy0__DOT__loopy_t, n->ppu__DOT__cycle,
                   n->multi_mapper__DOT__chr_aout,
                   n->multi_mapper__DOT__mmc3__DOT__chr_bank_0, n->multi_mapper__DOT__mmc3__DOT__chr_bank_1,
                   n->multi_mapper__DOT__mmc3__DOT__chr_bank_2, n->multi_mapper__DOT__mmc3__DOT__chr_bank_3,
                   n->multi_mapper__DOT__mmc3__DOT__chr_bank_4, n->multi_mapper__DOT__mmc3__DOT__chr_bank_5,
                   n->multi_mapper__DOT__mmc3__DOT__bank_select, n->multi_mapper__DOT__mmc3__DOT__chr_a12_invert,
                   n->multi_mapper__DOT__mmc3__DOT__counter, n->multi_mapper__DOT__mmc3__DOT__irq_latch,
                   n->multi_mapper__DOT__mmc3__DOT__a12_ctr,
                   n->ppu__DOT__bg_painter__DOT__playfield_pipe_1, n->ppu__DOT__vram_din);
            auto *r = s->r;
            printf("%s-sd doutB=%02x preB=%02x oeB=%u oeB_d=%u port=%u addrB=%06x edgerst=%u clkref=%u freeze=%u\n",
                   tag, r->sdram__DOT__doutB, r->sdram__DOT__doutB_pre,
                   r->sdram__DOT__oeB, r->sdram__DOT__oeB_d, r->sdram__DOT__port,
                   r->sdram__DOT__addrB, r->ss_edge_reset, r->clkref, r->ss_freeze);
        };
        printf("trace: state at lockstep start:\n");
        dump("A0", a2.sim);
        dump("B0", b2.sim);
        size_t target_a = a2.sim->windows.size() + 3;
        uint64_t tickno = 0;
        bool diffed = false;
        while (a2.sim->windows.size() < target_a) {
            a2.sim->tick();
            b2.sim->tick();
            tickno++;
            auto cpu_state = [](Sim *s) {
                auto *n = s->r->nes;
                return ((uint64_t)n->cpu__DOT__PC << 16) | ((uint64_t)n->cpu__DOT__IR << 8) |
                       n->cpu__DOT__MCycle;
            };
            if (pack(a2.sim) != pack(b2.sim) || cpu_state(a2.sim) != cpu_state(b2.sim)) {
                printf("trace: first diff at lockstep tick %llu (A window %zu)\n",
                       (unsigned long long)tickno, a2.sim->windows.size());
                dump("A", a2.sim);
                dump("B", b2.sim);
                diffed = true;
                break;
            }
        }
        if (!diffed)
            printf("trace: lockstep identical for %llu ticks\n", (unsigned long long)tickno);
        teardown(b2);
        teardown(a2);
    }

    printf(fails ? "FAILED (%d)\n" : "all passed\n", fails);
    return fails ? 1 : 0;
}
