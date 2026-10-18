// Sim-only top for the Verilator frame-lock run: the real nes2hdmi, the real
// ClockGen from src/ppu.v driven by a copy of the clock-divider/de-jitter
// block in src/nes.v (gated by the DUT's frame_halt exactly as
// src/nestang_top.sv gates the NES), synthetic picture/audio stimuli, and
// taps for the C++ harness. No delays, no file IO: Verilator-clean.
//
// With HZ120 the DUT runs the 480p120 timing with a runtime BFI mode input
// (bfi_mode_tb, video_config[21:20] equivalent, set per scenario phase) and
// extra taps for the harness's per-mode pixel checks; otherwise the ports
// exist but are tied (bfi_mode_tb is unused, the taps read zero).
`timescale 1ns/1ps

`include "variant.vh"

module fl_top (
    input clk,
    input clk_pixel,
    input por_n,            // power-on reset (DUT resetn): once only
    input reset_model,      // reset_nes equivalent (game reload pulses this)
    input pause_tb,         // core_config[17] equivalent
    input [1:0] bfi_mode_tb,    // video_config[21:20] equivalent, set per scenario phase
    output frame_halt,
    output [8:0] scanline,
    output [8:0] nes_cycle,
    output [9:0] cy,
    output [10:0] cx,
    output bfi_ins,
    output [9:0] roll_beam,     // unused (kept for harness shape; mode 3 is static halves now)
    output [23:0] rgb_out,
    output memA_we,
    output [15:0] memA_addr,
    output [15:0] memB_addr,
    output clk_audio,
    output [15:0] audio_word0,
    output [15:0] audio_word1
);

    wire pause_eff = pause_tb | frame_halt;

    reg [4:0] div_cpu = 5'd1;
    reg [2:0] div_ppu = 3'd1;
    reg [1:0] ppu_tick = 0;
    reg freeze_clocks = 0;
    reg [4:0] faux_pixel_cnt = 0;
    wire cpu_ce = (div_cpu == 5'd12) && !pause_eff;
    wire ppu_ce = (div_ppu == 3'd4) && !pause_eff;
    wire ppu_short_frame;
    wire [8:0] ppu_cycle_raw;
    assign nes_cycle = (freeze_clocks && faux_pixel_cnt < 6) ? 9'd340 : ppu_cycle_raw;

    // exact copy of the divider/de-jitter block in src/nes.v:208-240
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
        .sys_type(2'b0), .is_rendering(1'b1),
        .scanline(scanline), .cycle(ppu_cycle_raw),
        .is_in_vblank(), .end_of_line(), .at_last_cycle_group(),
        .exiting_vblank(), .entering_vblank(), .is_pre_render(),
        .short_frame(ppu_short_frame), .is_vbe_sl()
    );

`ifdef HZ120
    // synthetic picture: each line its own palette index (33..44: all
    // non-black, so every lit row reads nonzero at the probe column);
    // synthetic audio: a full-scale 440 Hz sine stepped at the CPU rate
    reg [5:0] pix_color = 0;
    always @(posedge clk)
        pix_color <= 6'd33 + (scanline[3:0] % 12);
`else
    // synthetic picture: each line its own palette index; synthetic audio: a
    // full-scale 440 Hz sine stepped at the CPU rate
    reg [5:0] pix_color = 0;
    always @(posedge clk)
        pix_color <= scanline[5:0] + 6'd8;
`endif
    reg [15:0] phase_acc = 0;
    reg [15:0] sample_tb = 0;
    always @(posedge clk)
        if (cpu_ce) begin
            phase_acc <= phase_acc + 16'd16;        // 440 Hz at 1.79 MHz cpu_ce
            sample_tb <= $rtoi(32767.0 * $sin(6.2831853 * phase_acc / 65536.0));
        end

    wire [2:0] tmds_d_p, tmds_d_n;
    wire tmds_clk_p, tmds_clk_n;
    wire [7:0] overlay_x, overlay_y;
    nes2hdmi dut (
        .clk(clk), .resetn(por_n),
        .color(pix_color), .cycle(nes_cycle), .scanline(scanline),
        .sample(sample_tb), .aspect_8x7(1'b0),
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(1'b0),
        .video_config(32'd0),
`ifdef HZ120
        .std_timing(1'b0),      // native NES rate x2, as in hardware
        .bfi_mode(bfi_mode_tb),
`else
        .std_timing(1'b0),      // native NES rate, as in hardware
`endif
        .overlay(1'b0), .overlay_x(overlay_x), .overlay_y(overlay_y),
        .overlay_color(15'd0),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
        .frame_halt(frame_halt),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p),
        .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // taps for the harness
    assign cy = dut.cy;
`ifdef HZ120
    assign cx = dut.cx;
    assign bfi_ins = dut.bfi_ins;
    assign roll_beam = 10'd0;
    assign rgb_out = dut.rgb;
`else
    assign cx = 11'd0;
    assign bfi_ins = 1'b0;
    assign roll_beam = 10'd0;
    assign rgb_out = 24'd0;
`endif
    assign memA_we = dut.mem_portA_we;
    assign memA_addr = dut.mem_portA_addr;
    assign memB_addr = dut.mem_portB_addr;
    assign clk_audio = dut.clk_audio;
    assign audio_word0 = dut.audio_sample_word[0];
    assign audio_word1 = dut.audio_sample_word[1];

endmodule
