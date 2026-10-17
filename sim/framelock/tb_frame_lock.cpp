// Verilator harness for the frame-lock run: two exact-rate clocks, the
// scenario (power-on, menu pause, core reset, menu pause over ~650 NES
// frames), and the checks. Mirrors tb_frame_lock.v; this is the engine that
// makes 600+ frames affordable. The HDMI side runs at 720p120 for BFI:
// every game frame must be read twice (lit pass, then inserted pass), each
// pass from a single game frame (per-line write-frame tags), lit passes
// stepping by exactly one game frame, with the inserted pass all black.
//
// BFI modes (video_config[21:20]) run one per scenario phase: run-in/pause/
// reset phases use mode 1 (black), the 200-frame run uses mode 0 (off), the
// second 200-frame run uses mode 2 (dim), the final 150-frame run uses mode
// 3 (rolling). Mode switches coincide with pause/reset edges, inside the
// existing 6-frame settle window. Per-mode pixel checks at the centre
// column (cx 641, all 480 active rows, stimulus has no black entries):
//   mode 0: every settled frame fully lit (all rows nonzero);
//   mode 1: lit passes nonzero, inserted passes all black;
//   mode 2: lit passes nonzero, inserted passes the exact per-channel half
//     of the paired lit pass (the inserted pass repeats the lit game frame);
//   mode 3: every settled frame has exactly 240 lit rows, consecutive
//     settled frames are complementary (each row lit in exactly one of the
//     pair), and the band position advances 8 rows per game frame
//     (checked against the release count).
// The phase swap (1800 game frames) never fires inside the run.
//
// argv: <clk_half_ps> <pix_half_ps> <tag>  (tag prefixes log/audio files)
// Prints tb_frame_lock: PASS on success (and returns nonzero otherwise).
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
    if (argc != 4) { fprintf(stderr, "usage: %s clk_half_ps pix_half_ps tag\n", argv[0]); return 2; }
    int64_t clk_half = atoll(argv[1]), pix_half = atoll(argv[2]);
    std::string tag = argv[3];
    Verilated::commandArgs(argc, argv);
    Vfl_top *t = new Vfl_top;
    FILE *log = fopen(("tb_" + tag + ".log").c_str(), "w");
    FILE *af = fopen(("audio_hdmi_" + tag + ".hex").c_str(), "w");
#define LOG(...) do { fprintf(log, __VA_ARGS__); fputc('\n', log); } while (0)

    int64_t now = 0, next_clk = clk_half, next_pix = pix_half;
    int64_t wr_last[240], wr_prev[240];
    int wr_frame[240];
    for (int i = 0; i < 240; i++) { wr_last[i] = wr_prev[i] = -1; wr_frame[i] = -1; }
    int game_wr = 0;                 // game frame currently being written
    int pass_fmin = 0, pass_fmax = -1, pass_ins = 0, last_lit = -1;
    int lit_nonzero = 0, ins_nonzero = 0, stale_in_frame = 0;
    // centre-column row values for the current HDMI frame (cy 0..479)
    static const int ROWS = 480, PROBE_CX = 641;
    std::vector<uint32_t> cur_rgb(ROWS, 0), lit_rgb(ROWS, 0);
    int bfi_mode = 1, prev_mode = 1;  // video_config[21:20] equivalent
    bool prev_settled = false;
    int prev_pass = -1;
    // mode-3 band tracking: per-pass anchors (beam, releases); the beam
    // must advance exactly 8 rows per release
    long anchor_beam[2] = {-1, -1}, anchor_rel[2] = {0, 0};
    bool have_anchor[2] = {false, false};
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
    t->por_n = 0; t->reset_model = 1; t->pause_tb = 0; t->bfi_mode_tb = 1;
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
                game_wr++;           // writes from here belong to the next game frame
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
        // one BFI mode per scenario phase (switches land on pause/reset
        // edges, inside the 6-frame settle window)
        {
            int want = (phase == 2) ? 0 : (phase == 4) ? 2 : (phase == 6) ? 3 : 1;
            if (want != bfi_mode) { bfi_mode = want; LOG("scenario: bfi mode %d at %lld ns", bfi_mode, (long long)now_ns); }
        }
        t->bfi_mode_tb = bfi_mode;

        if (rising_clk) {
            // halt monitor
            int halt = t->frame_halt;
            if (reset_model || pause_tb) locked = 0;
            if ((prev_reset != reset_model) || (prev_pause != pause_tb)) { forgive = 1; last_event_frame = frame_idx; last_lit = -1; }
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
                if (ln >= 0 && ln < 240) { wr_prev[ln] = wr_last[ln]; wr_last[ln] = now_ns; wr_frame[ln] = game_wr; }
            }
        }

        if (rising_pix) {
            int cy = t->cy;
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
            if (cy == 0 && cy_q != 0 && cy_q >= 0) {
                LOG("hdmi frame %d: ins=%d game=%d..%d min_age_ns=%lld max_age_ns=%lld wait_ns=%lld", frame_idx, pass_ins, pass_fmin, pass_fmax, (long long)frame_min_age, (long long)frame_max_age, (long long)last_wait);
                if (locked) frames_checked++;
                bool settled = locked && frame_idx - last_event_frame > 6;
                // each pass must come from a single game frame; lit passes
                // step by one game frame; the inserted pass repeats the lit one
                if (settled && pass_fmax >= 0) {
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
                    } else if (bfi_mode == 2) {
                        if (!pass_ins && !lit_nonzero) { LOG("FAIL: mode-2 lit hdmi frame %d all black at centre", frame_idx); violations++; }
                        // dim: the inserted pass is the exact per-channel
                        // half of the paired lit pass (same game frame data)
                        if (pass_ins && !ins_nonzero) { LOG("FAIL: mode-2 inserted hdmi frame %d all black at centre", frame_idx); violations++; }
                        if (pass_ins && prev_settled && prev_pass == 0 && prev_mode == 2) {
                            for (int r = 0; r < ROWS; r++) {
                                uint32_t want = ((lit_rgb[r] & 0xFEFEFEu) >> 1);
                                if (cur_rgb[r] != want) { LOG("FAIL: mode-2 row %d 0x%06x, want half of lit 0x%06x, in frame %d", r, cur_rgb[r], lit_rgb[r], frame_idx); violations++; break; }
                            }
                        }
                    } else {
                        // rolling: half the rows lit, complementary pairs,
                        // band rolling 8 rows per game frame pair
                        if (lit_rows != ROWS / 2) { LOG("FAIL: mode-3 frame %d has %d/480 lit rows", frame_idx, lit_rows); violations++; }
                        if (prev_settled && prev_mode == 3 && prev_pass != pass_ins) {
                            // within a pair the beam is fixed, so an
                            // even->odd step is an exact complement; an
                            // odd->even step carries the +8 advance, which
                            // flips exactly the 16-row trailing-edge band
                            int nmis = 0;
                            for (int r = 0; r < ROWS; r++) {
                                bool a = cur_rgb[r] != 0, b = lit_rgb[r] != 0;
                                if (a != b) nmis++;
                            }
                            if (pass_ins) {
                                if (nmis != ROWS) { LOG("FAIL: mode-3 %d/480 rows differ in frame %d, want exact complement", nmis, frame_idx); violations++; }
                            } else {
                                // the two 8-row groups that legitimately
                                // agree across the +8 step
                                long beam_prev = ((long)t->roll_beam - 8 + ROWS) % ROWS;
                                bool ok = (nmis == ROWS - 16);
                                for (int k = 0; ok && k < 8; k++) {
                                    int r1 = (int)((beam_prev + k) % ROWS);
                                    int r2 = (int)((beam_prev + 240 + k) % ROWS);
                                    if (((cur_rgb[r1] != 0) != (lit_rgb[r1] != 0)) ||
                                        ((cur_rgb[r2] != 0) != (lit_rgb[r2] != 0))) ok = false;
                                }
                                if (!ok) { LOG("FAIL: mode-3 advance band wrong in frame %d (nmis=%d want 464, groups at %ld/%ld)", frame_idx, nmis, beam_prev, (beam_prev + 240) % ROWS); violations++; }
                            }
                            // band cadence: exactly +8 rows per release
                            // (per pass: the frame-start step and the
                            // mid-frame release stay 1:1 through pauses)
                            int ap = pass_ins ? 1 : 0;
                            long beam_now = (long)t->roll_beam, rel_now = (long)released;
                            if (!have_anchor[ap]) {
                                anchor_beam[ap] = beam_now; anchor_rel[ap] = rel_now;
                                have_anchor[ap] = true;
                            } else {
                                long d = (beam_now - 8 * rel_now) - (anchor_beam[ap] - 8 * anchor_rel[ap]);
                                d %= ROWS; if (d < 0) d += ROWS;
                                if (d != 0) { LOG("FAIL: mode-3 beam %ld at %ld releases, anchor %ld at %ld, in frame %d", beam_now, rel_now, anchor_beam[ap], anchor_rel[ap], frame_idx); violations++; }
                            }
                        }
                    }
                    if (frame_max_age > 17000000) { LOG("FAIL: max age %lld ns in frame %d", (long long)frame_max_age, frame_idx); violations++; }
                    if (stale_in_frame) { LOG("FAIL: %d stale reads in frame %d", stale_in_frame, frame_idx); violations++; }
                }
                frame_idx++;
                frame_min_age = INT64_MAX;
                frame_max_age = 0;
                if (settled && pass_fmax >= 0) { lit_rgb = cur_rgb; prev_settled = true; }
                else prev_settled = false;
                prev_pass = pass_ins; prev_mode = bfi_mode;
                pass_fmin = 0; pass_fmax = -1; lit_nonzero = 0; ins_nonzero = 0; stale_in_frame = 0;
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
                    // stale reads during acquisition (before the settle
                    // window after an event) are the forgiven transient;
                    // count them per frame and judge at frame end
                    if (age > STALE_NS) stale_in_frame++;
                    if (wr_frame[rd] >= 0) {
                        if (pass_fmax < 0 || wr_frame[rd] < pass_fmin) pass_fmin = wr_frame[rd];
                        if (wr_frame[rd] > pass_fmax) pass_fmax = wr_frame[rd];
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
    LOG("audio: max_hdmi_step=%d (bound %d)", max_hdmi_step, AUDIO_MAX_STEP);
    LOG("run_min_age_ns=%lld", (long long)run_min_age);
    if (max_hdmi_step > AUDIO_MAX_STEP) { LOG("FAIL: HDMI audio step %d", max_hdmi_step); violations++; }
    if (violations != 0) { LOG("tb_frame_lock: FAIL"); fclose(log); fclose(af); return 1; }
    if (released < 600) { LOG("tb_frame_lock: FAIL: too few frames"); fclose(log); fclose(af); return 1; }
    LOG("tb_frame_lock: PASS");
    fclose(log); fclose(af);
    return 0;
}
