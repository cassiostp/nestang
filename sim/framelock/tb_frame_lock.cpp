// Verilator harness for the frame-lock run: two exact-rate clocks, the
// scenario (power-on, menu pause, core reset, menu pause over ~650 NES
// frames), and the checks. Mirrors tb_frame_lock.v; this is the engine that
// makes 600+ frames affordable.
//
// argv: <clk_half_ps> <pix_half_ps> <tag> [hz120]  (tag prefixes log/audio files)
// Prints tb_frame_lock: PASS on success (and returns nonzero otherwise).
//
// Without hz120: the standard 720p lock (one HDMI frame per game frame).
// With hz120: the HDMI side runs at 480p120 for BFI: every game frame must
// be read twice (lit pass, then inserted pass), each pass from a single game
// frame (per-line write-frame tags), lit passes stepping by exactly one game
// frame, with the inserted pass all black.
//
// BFI modes (video_config[21:20]) run one per scenario phase: run-in/pause/
// reset phases use mode 1 (black), the 200-frame run uses mode 0 (off), the
// second 200-frame run uses mode 2 (bright), the final 150-frame run uses
// mode 3 (beam). Mode switches coincide with pause/reset edges, inside the
// existing 6-frame settle window. Per-mode pixel checks at the centre
// column (cx 641, all 480 active rows, stimulus has no black entries):
//   mode 0: every settled frame fully lit (all rows nonzero);
//   mode 1: lit passes nonzero, inserted passes all black;
//   mode 2/3 (Lottes HI/LO): the stimulus picture is static, so adjacent
//     settled frames must be exact complements through the
//     sim/framelock/bfi_lottes.hex table (per row and channel the max of the
//     two passes is the table HI and the min is the table LO of one game
//     code), and same-parity frames two apart must be bit-identical.
//     Mode 2 shows the HI side on the same frame for every row (global
//     parity); mode 3 shows it on opposite frames for the top/bottom halves
//     (complementary halves, split at cy 240).
// The phase swap (1800 game frames) never fires inside the run.
#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>
#include "Vfl_top.h"
#include "verilated.h"

static const int64_t NS = 1000;              // ps per ns
static const int64_t STALE_NS = 20000000;    // stale = previous-frame data: over a full NES frame
static const int64_t WAIT_LO_NS = 5000;      // waits must stay in 5..500 us
static const int64_t WAIT_HI_NS = 500000;
static const int AUDIO_MAX_STEP = 4200;      // 440 Hz sine: ~1890/48 kHz step

int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) { fprintf(stderr, "usage: %s clk_half_ps pix_half_ps tag [hz120]\n", argv[0]); return 2; }
    int64_t clk_half = atoll(argv[1]), pix_half = atoll(argv[2]);
    std::string tag = argv[3];
    bool hz120 = (argc == 5 && std::string(argv[4]) == "hz120");
    Verilated::commandArgs(argc, argv);
    Vfl_top *t = new Vfl_top;
    FILE *log = fopen(("tb_" + tag + ".log").c_str(), "w");
    FILE *af = fopen(("audio_hdmi_" + tag + ".hex").c_str(), "w");
#define LOG(...) do { fprintf(log, __VA_ARGS__); fputc('\n', log); } while (0)

    int64_t now = 0, next_clk = clk_half, next_pix = pix_half;
    int64_t wr_last[240], wr_prev[240];
    for (int i = 0; i < 240; i++) wr_last[i] = wr_prev[i] = -1;
    // hz120-only: per-line write game-frame tags and per-HDMI-frame pass tracking
    int wr_frame[240];
    for (int i = 0; i < 240; i++) wr_frame[i] = -1;
    int game_wr = 0;                 // game frame currently being written
    int pass_fmin = 0, pass_fmax = -1, pass_ins = 0, last_lit = -1;
    int lit_nonzero = 0, ins_nonzero = 0, stale_in_frame = 0;
    // centre-column row values for the current HDMI frame (cy 0..479)
    static const int ROWS = 480, PROBE_CX = 641;
    std::vector<uint32_t> cur_rgb(ROWS, 0), lit_rgb(ROWS, 0);
    int bfi_mode = hz120 ? 1 : 0, prev_mode = bfi_mode;  // video_config[21:20] equivalent
    bool prev_settled = false;
    int prev_pass = -1;
    // modes 2/3 (Lottes HI/LO): forward table from bfi_lottes.hex ("HHLL"
    // per input code) plus the reverse membership map; the settled-frame
    // history (static stimulus: complements adjacent, identical 2 apart).
    uint8_t THI[256], TLO[256];
    bool valid_pair[256][256];
    std::vector<uint32_t> hist0(ROWS, 0), hist1(ROWS, 0);
    int have_hist = 0;
    int nchk[4] = {0, 0, 0, 0};   // settled frames with pixel checks, per mode
    if (hz120) {
        for (int i = 0; i < 256; i++) for (int j = 0; j < 256; j++) valid_pair[i][j] = false;
        FILE *hf = fopen("bfi_lottes.hex", "r");
        if (!hf) { fprintf(stderr, "need bfi_lottes.hex beside the log (run.sh copies it)\n"); return 1; }
        for (int i = 0; i < 256; i++) {
            unsigned h = 0, l = 0;
            if (fscanf(hf, "%02x%02x", &h, &l) != 2) { fprintf(stderr, "short bfi_lottes.hex\n"); return 1; }
            THI[i] = (uint8_t)h; TLO[i] = (uint8_t)l;
            valid_pair[h][l] = true;
        }
        fclose(hf);
    }
    auto eval = [&]() { t->eval(); };

    // scenario, counted in NES frames (scanline-240 entries with the model running)
    int phase = 0;               // 0 run-in, 1 pause1, 2 run, 3 reset, 4 run, 5 pause2, 6 run, 7 done
    int frames_in_phase = 0;
    int64_t frozen_until = 0;
    bool reset_model = true, pause_tb = false, por_n = false;
    bool prev240 = false;
    auto at240 = [&]() { return t->scanline == 240; };

    int locked = 0, forgive = 1, violations = 0;
    int halt_entered = 0, released = 0, frames_checked = 0, frame_idx = 0;
    int last_event_frame = 0;   // power-on counts as an event (startup settle)
    int64_t t_enter = 0, last_wait = 0;
    int64_t frame_min_age = INT64_MAX, run_min_age = INT64_MAX, frame_max_age = 0;
    int halt_q = 0, prev_reset = 1, prev_pause = 0;
    int rd_q = -1, cy_q = -1;
    int16_t prev_hw = 0;
    bool hw_first = true;
    int max_hdmi_step = 0;
    const int64_t T_CAP = (int64_t)14e12;    // 14 s cap

    t->clk = 0; t->clk_pixel = 0;
    t->por_n = 0; t->reset_model = 1; t->pause_tb = 0; t->bfi_mode_tb = bfi_mode;
    eval();

    while (now < T_CAP) {
        bool is_clk = next_clk <= next_pix;
        now = is_clk ? next_clk : next_pix;
        if (is_clk) next_clk += clk_half; else next_pix += pix_half;
        int64_t now_ns = now / NS;

        if (is_clk) { t->clk = !t->clk; eval(); } else { t->clk_pixel = !t->clk_pixel; eval(); }
        bool rising_clk = is_clk && t->clk;
        bool rising_pix = !is_clk && t->clk_pixel;

        // scenario edges (checked on clk edges only, like the RTL world)
        if (rising_clk) {
            if (phase == 0 && !por_n && now_ns > 1000) { por_n = true; reset_model = false; }
            bool is240 = at240();
            if (is240 && !prev240) {
                if (hz120) game_wr++;           // writes from here belong to the next game frame
                frames_in_phase++;
                if ((phase == 0 && frames_in_phase >= 100) ||
                    (phase == 2 && frames_in_phase >= 200) ||
                    (phase == 4 && frames_in_phase >= 200) ||
                    (phase == 6 && frames_in_phase >= 150)) {
                    frames_in_phase = 0;
                    phase++;
                    if (phase == 1 || phase == 5) { pause_tb = true; LOG("scenario: menu pause on at %lld ns", (long long)now_ns); }
                    if (phase == 3) { reset_model = true; LOG("scenario: core reset at %lld ns", (long long)now_ns); }
                    if (phase == 7) break;
                }
            }
            prev240 = is240;
            if ((phase == 1 || phase == 5) && frozen_until == 0) frozen_until = now + (phase == 1 ? (int64_t)500e9 : (int64_t)170e9);
            if (phase == 3 && frozen_until == 0) frozen_until = now + (int64_t)1e9;
        }
        if (frozen_until && now >= frozen_until) {
            frozen_until = 0;
            if (phase == 1 || phase == 5) { pause_tb = false; LOG("scenario: menu pause off at %lld ns", (long long)now_ns); phase++; }
            else if (phase == 3) { reset_model = false; phase++; }
        }
        t->por_n = por_n; t->reset_model = reset_model; t->pause_tb = pause_tb;
        if (hz120) {
            // one BFI mode per scenario phase (switches land on pause/reset
            // edges, inside the 6-frame settle window)
            int want = (phase == 2) ? 0 : (phase == 4) ? 2 : (phase == 6) ? 3 : 1;
            if (want != bfi_mode) { bfi_mode = want; LOG("scenario: bfi mode %d at %lld ns", bfi_mode, (long long)now_ns); }
        }
        t->bfi_mode_tb = bfi_mode;

        if (rising_clk) {
            // halt monitor
            int halt = t->frame_halt;
            if (reset_model || pause_tb) locked = 0;
            if ((prev_reset != reset_model) || (prev_pause != pause_tb)) {
                forgive = 1; last_event_frame = frame_idx;
                if (hz120) last_lit = -1;
            }
            prev_reset = reset_model; prev_pause = pause_tb;
            if (halt && !halt_q) {
                t_enter = now_ns; halt_entered++;
                LOG("halt #%d enter at %lld ns (scanline=%d cy=%d)", halt_entered, (long long)t_enter, (int)t->scanline, (int)t->cy);
            }
            if (!halt && halt_q) {
                last_wait = now_ns - t_enter; released++;
                LOG("halt #%d release wait=%lld ns (cy=%d)", released, (long long)last_wait, (int)t->cy);
                if (!reset_model && !pause_tb) {
                    if (last_wait < WAIT_LO_NS) { LOG("FAIL: short wait %lld ns (frame %d)", (long long)last_wait, frame_idx); violations++; }
                    else if (last_wait > WAIT_HI_NS && !forgive) { LOG("FAIL: long wait %lld ns (frame %d)", (long long)last_wait, frame_idx); violations++; }
                    locked = 1;
                    forgive = 0;
                }
            }
            halt_q = halt;
            // write timestamps from port A
            if (t->memA_we) {
                int ln = t->memA_addr >> 8;
                if (ln >= 0 && ln < 240) {
                    wr_prev[ln] = wr_last[ln]; wr_last[ln] = now_ns;
                    if (hz120) wr_frame[ln] = game_wr;
                }
            }
        }

        if (rising_pix) {
            int cy = t->cy;
            if (hz120) {
                if (cy == 100 && cy_q != 100) pass_ins = t->bfi_ins;
                // BFI checks: centre-column sample on every active line
                if (t->cx == PROBE_CX && cy >= 0 && cy < ROWS) {
                    uint32_t rgb = t->rgb_out;
                    cur_rgb[cy] = rgb;
                    if (locked) {
                        if (pass_ins) { if (rgb != 0) ins_nonzero++; }
                        else if (rgb != 0) lit_nonzero++;
                    }
                }
            }
            if (cy == 0 && cy_q != 0 && cy_q >= 0) {
                if (hz120) {
                    LOG("hdmi frame %d: ins=%d game=%d..%d min_age_ns=%lld max_age_ns=%lld wait_ns=%lld", frame_idx, pass_ins, pass_fmin, pass_fmax, (long long)frame_min_age, (long long)frame_max_age, (long long)last_wait);
                } else {
                    LOG("hdmi frame %d: min_age_ns=%lld max_age_ns=%lld wait_ns=%lld", frame_idx, (long long)frame_min_age, (long long)frame_max_age, (long long)last_wait);
                }
                if (locked) frames_checked++;
                bool settled = false;
                if (hz120) {
                    settled = locked && frame_idx - last_event_frame > 6;
                    // each pass must come from a single game frame; lit passes
                    // step by one game frame; the inserted pass repeats the lit one
                    if (settled && pass_fmax >= 0) {
                        nchk[bfi_mode]++;
                        if (pass_fmin != pass_fmax) { LOG("FAIL: mixed game frames %d..%d in hdmi frame %d (ins=%d)", pass_fmin, pass_fmax, frame_idx, pass_ins); violations++; }
                        else if (!pass_ins) {
                            if (last_lit >= 0 && pass_fmin != last_lit + 1) { LOG("FAIL: lit game frame %d after %d in hdmi frame %d", pass_fmin, last_lit, frame_idx); violations++; }
                            last_lit = pass_fmin;
                        } else if (last_lit >= 0 && pass_fmin != last_lit) {
                            LOG("FAIL: inserted game frame %d, lit was %d, in hdmi frame %d", pass_fmin, last_lit, frame_idx); violations++;
                        }
                        int lit_rows = 0;
                        for (int r = 0; r < ROWS; r++) if (cur_rgb[r] != 0) lit_rows++;
                        if (bfi_mode == 0) {
                            // off: both refreshes show the frame
                            if (lit_rows != ROWS) { LOG("FAIL: mode 0 frame %d has %d/480 lit rows", frame_idx, lit_rows); violations++; }
                        } else if (bfi_mode == 1) {
                            if (pass_ins && ins_nonzero) { LOG("FAIL: %d non-black centre samples in inserted hdmi frame %d", ins_nonzero, frame_idx); violations++; }
                            if (!pass_ins && !lit_nonzero) { LOG("FAIL: lit hdmi frame %d all black at centre", frame_idx); violations++; }
                        } else if (bfi_mode == 2 || bfi_mode == 3) {
                            // Lottes HI/LO: the stimulus picture is static,
                            // so this frame must be the exact complement of
                            // the previous settled frame through the hex
                            // table (per row/channel: max = HI, min = LO of
                            // one game code), and identical to the settled
                            // frame two back. Mode 2 carries HI on the same
                            // frame for every row; mode 3 flips it per half
                            // (top rows cy<240 vs bottom rows).
                            if (prev_settled && prev_mode == bfi_mode && prev_pass != pass_ins) {
                                int side_top = -1, side_bot = -1;  // 1: cur holds HI
                                for (int r = 0; r < ROWS; r++) {
                                    uint32_t a = cur_rgb[r], b = lit_rgb[r];
                                    for (int k = 0; k < 3; k++) {
                                        int ca = (a >> (8 * k)) & 0xff, cb = (b >> (8 * k)) & 0xff;
                                        int mx = ca > cb ? ca : cb, mn = ca < cb ? ca : cb;
                                        if (!valid_pair[mx][mn]) {
                                            LOG("FAIL: mode-%d row %d ch %d 0x%02x/0x%02x not a table pair, in frame %d",
                                                bfi_mode, r, k, ca, cb, frame_idx);
                                            violations++;
                                            r = ROWS;
                                            break;
                                        }
                                        if (mx != mn) {
                                            int side = (ca == mx) ? 1 : 0;
                                            int &slot = (r < ROWS / 2) ? side_top : side_bot;
                                            if (slot < 0) slot = side;
                                            else if (slot != side) {
                                                LOG("FAIL: mode-%d row %d ch %d HI side flips mid-half, in frame %d",
                                                    bfi_mode, r, k, frame_idx);
                                                violations++;
                                                r = ROWS;
                                                break;
                                            }
                                        }
                                    }
                                }
                                if (side_top < 0 || side_bot < 0) {
                                    LOG("FAIL: mode-%d frame %d has no discriminating row (all HI==LO)", bfi_mode, frame_idx);
                                    violations++;
                                } else if (bfi_mode == 2 && side_top != side_bot) {
                                    LOG("FAIL: mode-2 frame %d top/bottom HI sides differ (%d/%d)", frame_idx, side_top, side_bot);
                                    violations++;
                                } else if (bfi_mode == 3 && side_top == side_bot) {
                                    LOG("FAIL: mode-3 frame %d top/bottom HI sides agree (%d)", frame_idx, side_top);
                                    violations++;
                                }
                                if (have_hist >= 2) {
                                    for (int r = 0; r < ROWS; r++) {
                                        if (cur_rgb[r] != hist1[r]) {
                                            LOG("FAIL: mode-%d row %d 0x%06x != same-parity frame 0x%06x, in frame %d",
                                                bfi_mode, r, cur_rgb[r], hist1[r], frame_idx);
                                            violations++;
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                        if (frame_max_age > 17000000) { LOG("FAIL: max age %lld ns in frame %d", (long long)frame_max_age, frame_idx); violations++; }
                        if (stale_in_frame) { LOG("FAIL: %d stale reads in frame %d", stale_in_frame, frame_idx); violations++; }
                    }
                } else {
                    // steady locked frames must show fresh data everywhere: the
                    // oldest line (231) is ~2.1 ms old at its read; anything near
                    // a full frame old is a tear, even if under STALE_NS
                    if (locked && frame_idx - last_event_frame > 3 && frame_max_age > 3000000) {
                        LOG("FAIL: max age %lld ns in frame %d", (long long)frame_max_age, frame_idx);
                        violations++;
                    }
                }
                frame_idx++;
                frame_min_age = INT64_MAX;
                frame_max_age = 0;
                if (hz120) {
                    if (settled && pass_fmax >= 0) {
                        if (prev_mode != bfi_mode) have_hist = 0;
                        hist1 = lit_rgb; lit_rgb = cur_rgb; prev_settled = true;
                        have_hist++;
                    }
                    else { prev_settled = false; have_hist = 0; }
                    prev_pass = pass_ins; prev_mode = bfi_mode;
                    pass_fmin = 0; pass_fmax = -1; lit_nonzero = 0; ins_nonzero = 0; stale_in_frame = 0;
                }
            }
            cy_q = cy;
            int rd = t->memB_addr >> 8;
            if (rd != rd_q) {
                rd_q = rd;
                if (rd >= 8 && rd < 232 && locked) {
                    int64_t w = (wr_last[rd] >= 0 && wr_last[rd] < now_ns) ? wr_last[rd] : wr_prev[rd];
                    int64_t age = (w < 0) ? INT64_MAX : now_ns - w;
                    if (age < frame_min_age) frame_min_age = age;
                    if (age > frame_max_age) frame_max_age = age;
                    if (age < run_min_age) run_min_age = age;
                    if (hz120) {
                        // stale reads during acquisition (before the settle
                        // window after an event) are the forgiven transient;
                        // count them per frame and judge at frame end
                        if (age > STALE_NS) stale_in_frame++;
                        if (wr_frame[rd] >= 0) {
                            if (pass_fmax < 0 || wr_frame[rd] < pass_fmin) pass_fmin = wr_frame[rd];
                            if (wr_frame[rd] > pass_fmax) pass_fmax = wr_frame[rd];
                        }
                    } else {
                        if (age > STALE_NS) { LOG("FAIL: stale read line %d age %lld ns at %lld ns (frame %d)", rd, (long long)age, (long long)now_ns, frame_idx); violations++; }
                    }
                }
            }
            // audio: sample words at the DUT's audio tick
            static int prev_ca = 0;
            int ca = t->clk_audio;
            if (ca && !prev_ca && por_n) {
                int16_t w0 = (int16_t)t->audio_word0;
                fprintf(af, "%d\n", w0);
                if (!hw_first) {
                    int d = prev_hw >= w0 ? prev_hw - w0 : w0 - prev_hw;
                    if (d > max_hdmi_step) max_hdmi_step = d;
                }
                hw_first = false; prev_hw = w0;
            }
            prev_ca = ca;
        }
    }

    LOG("done: halted=%d released=%d frames_checked=%d violations=%d", halt_entered, released, frames_checked, violations);
    if (hz120) LOG("mode checked frames: off=%d black=%d bright=%d beam=%d", nchk[0], nchk[1], nchk[2], nchk[3]);
    LOG("audio: max_hdmi_step=%d (bound %d)", max_hdmi_step, AUDIO_MAX_STEP);
    LOG("run_min_age_ns=%lld", (long long)run_min_age);
    if (max_hdmi_step > AUDIO_MAX_STEP) { LOG("FAIL: HDMI audio step %d", max_hdmi_step); violations++; }
    if (violations != 0) { LOG("tb_frame_lock: FAIL"); fclose(log); fclose(af); return 1; }
    if (released < 600) { LOG("tb_frame_lock: FAIL: too few frames"); fclose(log); fclose(af); return 1; }
    LOG("tb_frame_lock: PASS");
    fclose(log); fclose(af);
    return 0;
}
