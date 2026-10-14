// Verilator harness for the frame-lock run: two exact-rate clocks, the
// scenario (power-on, menu pause, core reset, menu pause over ~650 NES
// frames), and the checks. Mirrors tb_frame_lock.v; this is the engine that
// makes 600+ frames affordable.
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
    for (int i = 0; i < 240; i++) wr_last[i] = wr_prev[i] = -1;
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
    t->por_n = 0; t->reset_model = 1; t->pause_tb = 0;
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

        if (rising_clk) {
            // halt monitor
            int halt = t->frame_halt;
            if (reset_model || pause_tb) locked = 0;
            if ((prev_reset != reset_model) || (prev_pause != pause_tb)) { forgive = 1; last_event_frame = frame_idx; }
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
                if (ln >= 0 && ln < 240) { wr_prev[ln] = wr_last[ln]; wr_last[ln] = now_ns; }
            }
        }

        if (rising_pix) {
            int cy = t->cy;
            if (cy == 0 && cy_q != 0 && cy_q >= 0) {
                LOG("hdmi frame %d: min_age_ns=%lld max_age_ns=%lld wait_ns=%lld", frame_idx, (long long)frame_min_age, (long long)frame_max_age, (long long)last_wait);
                if (locked) frames_checked++;
                // steady locked frames must show fresh data everywhere: the
                // oldest line (231) is ~2.1 ms old at its read; anything near
                // a full frame old is a tear, even if under STALE_NS
                if (locked && frame_idx - last_event_frame > 3 && frame_max_age > 3000000) {
                    LOG("FAIL: max age %lld ns in frame %d", (long long)frame_max_age, frame_idx);
                    violations++;
                }
                frame_idx++;
                frame_min_age = INT64_MAX;
                frame_max_age = 0;
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
                    if (age > STALE_NS) { LOG("FAIL: stale read line %d age %lld ns at %lld ns (frame %d)", rd, (long long)age, (long long)now_ns, frame_idx); violations++; }
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
