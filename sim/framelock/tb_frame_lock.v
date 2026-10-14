// Frame-lock bench: the real nes2hdmi against a cycle-exact model of the PPU
// write timing (the real ClockGen from src/ppu.v driven by a copy of the
// clock-divider/de-jitter block in src/nes.v, gated by the DUT's frame_halt
// exactly as src/nestang_top.sv gates the NES), over 600+ NES frames.
//
// Checks, for every HDMI read of a visible source line once locked, that the
// data is from the current NES frame (the read never passes the write), and
// logs the lock phase (halt entry/release times, wait per frame, data age).
// Scenarios in one run: power-on reset, a game-menu pause, a core reset
// (DUT resetn stays up, as in hardware), another pause. Fails with $fatal.
//
// Audio: `sample` is a synthetic sine stepped at the CPU rate; the HDMI-side
// words (dut.audio_sample_word at dut.clk_audio) are dumped to a file for the
// host-side check (no clicks/DC from the 38/49 us hold). Fails here if any
// HDMI-side step exceeds twice the largest input step.
//
// Run from the repo root (COMMON.md docker pattern):
//   docker run --rm --name nestear_lock --user $(id -u):$(id -g) -v $PWD:/w \
//     -w /w/sim/framelock tangcore-iv:1 sh run.sh
// run.sh runs the bench twice (console138k and console60k PLL clocks) and the
// host then checks the audio dumps with check_audio.py.
`timescale 1ns/1ps

module tb_frame_lock;

    // set by run.sh (-DCONSOLE60K for the 60K PLL clocks)
`ifdef CONSOLE60K
    localparam real CLK_MHZ = 21.491228;    // 50*49/(2*57), src/plla/gowin_pll_nes.v
`else
    localparam real CLK_MHZ = 21.505376;    // 50*40/93, src/pll/gowin_pll_nes.v
`endif
    localparam real CLK_HALF_NS = 500.0 / CLK_MHZ;
    localparam real PIX_HALF_NS = 500.0 / 74.25;    // hclk5/5, both boards

    reg clk = 0, clk_pixel = 0;
    always #(CLK_HALF_NS) clk = ~clk;
    always #(PIX_HALF_NS) clk_pixel = ~clk_pixel;

    // NES-side model: ClockGen + the nes.v divider, gated like nestang_top
    reg por_n = 1'b0;           // power-on reset (DUT resetn): once only
    reg reset_model = 1'b1;     // reset_nes equivalent (game reload pulses this)
    reg pause_tb = 1'b0;        // core_config[17] equivalent
    wire frame_halt;
    wire pause_eff = pause_tb | frame_halt;

    reg [4:0] div_cpu = 5'd1;
    reg [2:0] div_ppu = 3'd1;
    reg [1:0] ppu_tick = 0;
    reg freeze_clocks = 0;
    reg [4:0] faux_pixel_cnt = 0;
    wire cpu_ce = (div_cpu == 5'd12) && !pause_eff;
    wire ppu_ce = (div_ppu == 3'd4) && !pause_eff;
    wire ppu_short_frame;
    wire [8:0] ppu_scanline, ppu_cycle_raw;
    wire [8:0] nes_cycle = (freeze_clocks && faux_pixel_cnt < 6) ? 9'd340 : ppu_cycle_raw;

    // exact copy of the divider/de-jitter block in src/nes.v:208-240
    // (div_sys/SDRAM scheduling omitted: unobserved here)
    always @(posedge clk) begin
        if ((~freeze_clocks | ~(div_ppu == 3'd3)) && !pause_eff) begin
            div_cpu <= cpu_ce || (ppu_ce && div_cpu > 5'd12) ? 5'd1 : div_cpu + 5'd1;
            div_ppu <= ppu_ce ? 3'd1 : div_ppu + 3'd1;
            if (cpu_ce)
                ppu_tick <= 0;
            else if (ppu_ce)
                ppu_tick <= ppu_tick + 2'd1;
        end
        if (faux_pixel_cnt == 3)
            freeze_clocks <= 1'b0;
        if (|faux_pixel_cnt)
            faux_pixel_cnt <= faux_pixel_cnt - 5'd1;
        if (ppu_short_frame && (faux_pixel_cnt == 0)) begin
            freeze_clocks <= 1'b1;
            faux_pixel_cnt <= 5'd7;
        end
        if (reset_model) begin
            div_cpu <= 5'd1;
            div_ppu <= 3'd1;
            ppu_tick <= 0;
            freeze_clocks <= 1'b0;
            faux_pixel_cnt <= 0;
        end
    end

    ClockGen ppu_timing (
        .clk(clk), .ce(ppu_ce), .reset(reset_model),
        .sys_type(2'b0), .is_rendering(1'b1),       // NTSC game rendering
        .scanline(ppu_scanline), .cycle(ppu_cycle_raw),
        .is_in_vblank(), .end_of_line(), .at_last_cycle_group(),
        .exiting_vblank(), .entering_vblank(), .is_pre_render(),
        .short_frame(ppu_short_frame), .is_vbe_sl()
    );

    // synthetic picture: each line its own palette index; synthetic audio: a
    // full-scale 440 Hz sine stepped at the CPU rate
    reg [5:0] pix_color;
    always @(posedge clk)
        pix_color <= ppu_scanline[5:0] + 6'd8;
    reg [15:0] phase_acc = 0;
    reg [15:0] sample_tb = 0;
    always @(posedge clk)
        if (cpu_ce) begin
            phase_acc <= phase_acc + 16'd806;       // 440 Hz at 1.79 MHz cpu_ce
            sample_tb <= $rtoi(32767.0 * $sin(6.2831853 * phase_acc / 65536.0));
        end
    reg [15:0] max_in_step = 0;
    reg [15:0] prev_sample = 0;
    always @(posedge clk)
        if (cpu_ce && !reset_model) begin
            if (prev_sample >= sample_tb) begin
                if (prev_sample - sample_tb > max_in_step) max_in_step <= prev_sample - sample_tb;
            end else begin
                if (sample_tb - prev_sample > max_in_step) max_in_step <= sample_tb - prev_sample;
            end
            prev_sample <= sample_tb;
        end

    wire [2:0] tmds_d_p, tmds_d_n;
    wire tmds_clk_p, tmds_clk_n;
    wire [7:0] overlay_x, overlay_y;
    nes2hdmi dut (
        .clk(clk), .resetn(por_n),
        .color(pix_color), .cycle(nes_cycle), .scanline(ppu_scanline),
        .sample(sample_tb), .aspect_8x7(1'b0),
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(1'b0),
        .video_config(32'd0),
        .overlay(1'b0), .overlay_x(overlay_x), .overlay_y(overlay_y),
        .overlay_color(15'd0),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
        .frame_halt(frame_halt),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p),
        .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // write timestamps (ns) per source line, from the DUT's own port A
    time wr_last [0:239], wr_prev [0:239];
    integer i;
    initial for (i = 0; i < 240; i = i + 1) begin wr_last[i] = -1; wr_prev[i] = -1; end
    always @(posedge clk)
        if (dut.mem_portA_we) begin
            wr_prev[dut.mem_portA_addr >> 8] <= wr_last[dut.mem_portA_addr >> 8];
            wr_last[dut.mem_portA_addr >> 8] <= $time;
        end

    // the invariant: every HDMI read of a visible line must see current-frame
    // data. The data age (read time minus the freshest preceding write) must
    // be well under one NES frame; stale (previous-frame) data is the tear.
    // Checked on each read-line change, once locked.
    reg locked = 0;
    integer violations = 0;
    integer frames_checked = 0;
    integer frame_idx = 0;
    time frame_min_age = 64'h7FFF_FFFF_FFFF_FFFF, run_min_age = 64'h7FFF_FFFF_FFFF_FFFF;
    reg [7:0] rd_line_q = 8'd0;
    reg [9:0] cy_q = 10'd0;
    wire [7:0] rd_line = dut.mem_portB_addr >> 8;
    time w_use, w_age;
    always @(posedge clk_pixel) begin
        cy_q <= dut.cy;
        if (dut.cy == 10'd0 && cy_q != 10'd0) begin
            $display("hdmi frame %0d: min_age_ns=%0d wait_ns=%0d", frame_idx, frame_min_age/1000, last_wait/1000);
            if (locked) frames_checked <= frames_checked + 1;
            frame_idx <= frame_idx + 1;
            frame_min_age <= 64'h7FFF_FFFF_FFFF_FFFF;
        end
        if (rd_line != rd_line_q) begin
            rd_line_q <= rd_line;
            if (rd_line >= 8 && rd_line < 232 && locked) begin
                if (wr_last[rd_line] >= 0 && wr_last[rd_line] < $time)
                    w_use = wr_last[rd_line];
                else
                    w_use = wr_prev[rd_line];
                if (w_use < 0)
                    w_age = 64'h7FFF_FFFF_FFFF_FFFF;
                else
                    w_age = $time - w_use;
                if (w_age < frame_min_age) frame_min_age = w_age;
                if (w_age < run_min_age) run_min_age = w_age;
                if (w_age > 20000) begin     // one NES frame is ~16.6 ms
                    $display("FAIL: stale read line %0d age %0d ns at %0d ns (frame %0d)",
                             rd_line, w_age/1000, $time/1000, frame_idx);
                    violations = violations + 1;
                end
            end
        end
    end

    // lock-phase log: halt entry (with cy) and release (with wait). A release
    // after a scenario event is forgiven a long wait (late arrival waits for
    // the next HDMI frame); any other long/short wait fails. `locked` covers
    // reads only between a nominal release and the next scenario event.
    integer halt_entered = 0, released = 0;
    time t_enter = 0, last_wait = 0;
    reg halt_q = 0, forgive = 1;
    reg reset_q = 1, pause_q = 0;
    always @(posedge clk) begin
        halt_q <= frame_halt;
        reset_q <= reset_model;
        pause_q <= pause_tb;
        if (reset_model || pause_tb) locked <= 0;
        if ((reset_q != reset_model) || (pause_q != pause_tb)) forgive <= 1;
        if (frame_halt && !halt_q) begin
            t_enter = $time;
            halt_entered = halt_entered + 1;
            $display("halt #%0d enter at %0d ns (scanline=%0d cy=%0d)", halt_entered, t_enter/1000, ppu_scanline, dut.cy);
        end
        if (!frame_halt && halt_q) begin
            last_wait = $time - t_enter;
            released = released + 1;
            $display("halt #%0d release wait=%0d ns (cy=%0d)", released, last_wait/1000, dut.cy);
            if (!reset_model && !pause_tb) begin
                if (last_wait < 5000) begin
                    $display("FAIL: short wait %0d ns (frame %0d)", last_wait/1000, frame_idx);
                    violations = violations + 1;
                end else if (last_wait > 500000 && !forgive) begin
                    $display("FAIL: long wait %0d ns (frame %0d)", last_wait/1000, frame_idx);
                    violations = violations + 1;
                end
                // every release pins the phase to the HDMI edge, so reads
                // after it are exact; reads during a long wait were unchecked
                locked <= 1;
                forgive <= 0;
            end
        end
    end

    // HDMI-side audio dump for the host-side click check
    integer af;
`ifdef CONSOLE60K
    initial af = $fopen("audio_hdmi_60k.hex", "w");
`else
    initial af = $fopen("audio_hdmi_138k.hex", "w");
`endif
    always @(posedge dut.clk_audio)
        if (por_n) $fwrite(af, "%d\n", $signed(dut.audio_sample_word[0]));
    reg [15:0] max_hdmi_step = 0;
    reg [15:0] prev_hw = 0;
    reg hw_first = 1;
    always @(posedge dut.clk_audio)
        if (por_n) begin
            if (!hw_first) begin
                if (prev_hw >= dut.audio_sample_word[0]) begin
                    if (prev_hw - dut.audio_sample_word[0] > max_hdmi_step)
                        max_hdmi_step <= prev_hw - dut.audio_sample_word[0];
                end else begin
                    if (dut.audio_sample_word[0] - prev_hw > max_hdmi_step)
                        max_hdmi_step <= dut.audio_sample_word[0] - prev_hw;
                end
            end
            hw_first <= 0;
            prev_hw <= dut.audio_sample_word[0];
        end

    task wait_frames(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
                while (!(ppu_scanline == 9'd240 && ppu_ce)) @(posedge clk);
            end
        end
    endtask

    // scenario: power-on, menu pause, core reset, menu pause; ~650 NES frames
    initial begin
        #1000;
        por_n = 1;
        reset_model = 0;
        wait_frames(100);
        $display("scenario: menu pause on at %0d ns", $time/1000);
        pause_tb = 1;
        #500000000;                     // 30 HDMI frames frozen
        pause_tb = 0;
        $display("scenario: menu pause off at %0d ns", $time/1000);
        wait_frames(200);
        $display("scenario: core reset at %0d ns", $time/1000);
        reset_model = 1;                // DUT resetn stays up, as in hardware
        #1000000;
        reset_model = 0;
        wait_frames(200);
        $display("scenario: menu pause on at %0d ns", $time/1000);
        pause_tb = 1;
        #170000000;                     // 10 HDMI frames frozen
        pause_tb = 0;
        $display("scenario: menu pause off at %0d ns", $time/1000);
        wait_frames(150);
        $display("done: halted=%0d released=%0d frames_checked=%0d violations=%0d",
                 halt_entered, released, frames_checked, violations);
        $display("audio: max_in_step=%0d max_hdmi_step=%0d", max_in_step, max_hdmi_step);
        $display("run_min_age_ns=%0d", run_min_age/1000);
        if (max_hdmi_step > 2 * max_in_step + 16) begin
            $display("FAIL: HDMI audio step %0d > 2x input step %0d", max_hdmi_step, max_in_step);
            $fatal(1, "tb_frame_lock: audio FAIL");
        end
        if (violations != 0) $fatal(1, "tb_frame_lock: FAIL");
        if (released < 600) $fatal(1, "tb_frame_lock: too few frames");
        $display("tb_frame_lock: PASS");
        $finish;
    end

    initial begin
        #14000000000;   // 14 s cap
        $fatal(1, "tb_frame_lock: timeout");
    end
endmodule
