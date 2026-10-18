// NES video and sound to HDMI converter
// nand2mario, 2022.9

`timescale 1ns / 1ps

`include "variant.vh"

module nes2hdmi (
	input clk,      // nes clock
	input resetn,

    // nes video signals
    input [5:0] color,
    input [8:0] cycle,
    input [8:0] scanline,
    input [15:0] sample,
    input aspect_8x7,       // 1: 8x7 pixel aspect ratio mode
    input scanlines,        // core_config[16]: scanlines on
    input [1:0] sl_darkness,// core_config[19:18]: 25, 50, 75, 100 % dark
    input sl_thick,         // core_config[20]: thick lines
    input sl_out,           // core_config[21]: scale, 0 = integer, 1 = full
    input [31:0] video_config,  // colour controls and CRT mask, see video_fx.v (the LCD grid is unused)

    // overlay interface
    input overlay,
    output [7:0] overlay_x,
    output [7:0] overlay_y,
    input [14:0] overlay_color, // BGR5

	// video clocks
	input clk_pixel,
	input clk_5x_pixel,

    // 1: standard 60.00 Hz 720p; 0: native NES rate (1647-pixel lines)
    input std_timing,
`ifdef HZ120
    // BFI mode (video_config[21:20] in hardware, runtime-switchable):
    // 0 off (every console frame shown twice, both refreshes lit),
    // 1 black inserted refresh,
    // 2 bright (Lottes-style: full average brightness, per-pixel clarity),
    // 3 beam (same budgets, complementary top/bottom halves: softer flicker).
    // The game menu (overlay) is lit on every refresh in every mode.
    input [1:0] bfi_mode,
`endif

    // frame lock: halt request for the NES (clk domain), see below
    output frame_halt,

    // output [7:0] led,

	// output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

// NES generates 256x240. We assume the center 256x224 is visible and scale that to 4:3 aspect ratio.
// https://www.nesdev.org/wiki/Overscan

`ifdef HZ120
localparam FRAMEWIDTH = 720;
localparam FRAMEHEIGHT = 480;
localparam TOTALWIDTH = 858;
localparam TOTALHEIGHT = 525;
localparam SCALE = 5;
localparam VIDEOID = 48;            // 480p120: the 480p60 totals at 54 MHz, for BFI
localparam VIDEO_REFRESH = 120.0;   // the audio clock regeneration only: the line is NATIVE below
// 54 MHz / (855x525) = 120.3008 Hz, twice 60.1504 Hz: the largest
// whole-pixel line at or above twice the NES 60.0988 Hz that the console138k
// NES clock can still lock (free-run 60.1775 Hz, 7.5 us halt); the 856 line
// would run 60.0816 Hz, below native, and 855 is too fast for console60k
// (free-run 60.1379 Hz), so the hz120 variant is console138k-only
// (21.477272 MHz / 4 / 89341.5 dots)
localparam NATIVE_LINE = 855;
`else
localparam FRAMEWIDTH = 1280;
localparam FRAMEHEIGHT = 720;
localparam TOTALWIDTH = 1650;
localparam TOTALHEIGHT = 750;
localparam SCALE = 5;
localparam VIDEOID = 4;
localparam VIDEO_REFRESH = 60.0;    // the audio clock regeneration only: the line is NATIVE below
// 74.25 MHz / (1647x750) = 60.1093 Hz: the largest whole-pixel line at or
// above the NES 60.0988 Hz (21.477272 MHz / 4 / 89341.5 dots)
localparam NATIVE_LINE = 1647;
`endif

// localparam IDIV_SEL_X5 = 3;
// localparam FBDIV_SEL_X5 = 54;
// localparam ODIV_SEL_X5 = 2;
// localparam DUTYDA_SEL_X5 = "1000";
// localparam DYN_SDIV_SEL_X5 = 2;
  
`ifdef HZ120
localparam CLKFRQ = 54000;
`else
localparam CLKFRQ = 74250;
`endif

localparam COLLEN = 80;
localparam AUDIO_BIT_WIDTH = 16;

localparam POWERUPNS = 100000000.0;
localparam CLKPERNS = (1.0/CLKFRQ)*1000000.0;
localparam int POWERUPCYCLES = $rtoi($ceil( POWERUPNS/CLKPERNS ));

// video stuff
wire [9:0] cy, frameHeight;
wire [10:0] cx, frameWidth;

//
// BRAM frame buffer
//
localparam MEM_DEPTH=256*240;
localparam MEM_ABITS=16;

logic [5:0] mem [0:256*240-1];
logic [15:0] mem_portA_addr;
logic [5:0] mem_portA_wdata;
logic mem_portA_we;

wire [15:0] mem_portB_addr;
logic [5:0] mem_portB_rdata;

// BRAM port A read/write
always_ff @(posedge clk) begin
    if (mem_portA_we) begin
        mem[mem_portA_addr] <= mem_portA_wdata;
    end
end

// BRAM port B read
always_ff @(posedge clk_pixel) begin
    mem_portB_rdata <= mem[mem_portB_addr];
end

initial begin
    $readmemb("background.txt", mem);
end


// 
// Data input and initial background loading
//
logic [8:0] r_scanline;
logic [8:0] r_cycle;
always @(posedge clk) begin
    r_scanline <= scanline;
    r_cycle <= cycle;
    mem_portA_we <= 1'b0;
    if ((r_scanline != scanline || r_cycle != cycle) && scanline < 9'd240 && ~cycle[8]) begin
        mem_portA_addr <= {scanline[7:0], cycle[7:0]};
        mem_portA_wdata <= color;
        mem_portA_we <= 1'b1;
    end
end

`ifdef HZ120
//
// Frame lock: halt the NES once per game frame so the PPU frame stays ahead
// of the HDMI read and the single framebuffer never tears. The HDMI output
// runs at twice the game rate for black frame insertion (BFI): each game
// frame is read out twice, once lit and once as the inserted (black or
// dimmed) frame, so the lock releases the NES once per two HDMI frames.
//
// The NES frame (60.1775 Hz on console138k from the board PLL, 262 lines of
// 341 PPU dots) is shorter than two native-rate 480p120 HDMI frames
// (120.3008 Hz at 855 pixels per line, the largest line at or above twice
// the NES 60.0988 Hz that still locks). Halting the whole machine for the
// difference (about 7.5 us) once per game frame locks the NES to exactly
// half the HDMI rate, 0.086 % fast, with a fixed phase.
//
// Phase: the NES waits at the first vblank scanline (240, all of lines 0-239
// are written by then) and runs again when HDMI reaches RELEASE_ROW in an
// even frame. The reader is faster per line than the writer, so the release
// row has to leave the writer most of the inserted frame plus the rest of
// the lit frame to stay ahead of the next lit read, while the inserted
// read (of the frame just lit) runs ahead of the writer overwriting it.
// The release is edge-triggered (one toggle per two HDMI frames over a
// synchroniser) so a late arrival waits for the next pair and the phase is
// exact after at most two game frames, including after reset, game reload
// and menu pause.
//
// LCD image retention: BFI at half the refresh rate always shows the image
// on frames of the same LCD polarity, leaving a DC bias. Every
// BFI_SWAP_FRAMES game frames (~30 s) the lit/inserted assignment flips,
// so the image averages to zero DC over minutes. The flip is armed at a
// release and takes effect at the next frame start, so one boundary shows
// two lits or two blacks in a row (alternating); the release cadence never
// moves, so there is no tear and no audio gap, just one 8 ms duplicate per
// swap. The menu overlay is exempt from darkening, so the menu itself stays
// steady while the game behind it keeps alternating.
//
localparam HALT_LINE = 240;       // NES scanline at which to wait
localparam RELEASE_ROW = 453;     // HDMI row whose start releases the NES (even frames)
localparam BFI_SWAP_FRAMES = 1800;  // game frames between lit/inserted swaps (~30 s)

// HDMI frame parity (toggles every frame) and the BFI phase: the inserted
// (darkened) frame is bfi_ins ^ bfi_phase, while releases stay on even
// frames so the game timing never shifts at a swap.
reg bfi_ins = 1'b1;
reg bfi_phase = 1'b0;
reg [15:0] bfi_swap_cnt = 16'd0;
reg bfi_swap_pending = 1'b0;
// Mode 2-3 (Lottes-style brightness-preserving BFI): in linear light each
// pixel's content-frame budget (2x its value, gain 1.0: unchanged average
// brightness, cf. the Blur Busters / Lottes CRT beam simulator at 2 subframes)
// is carried as HI = min(1, budget) on one refresh and LO = the remainder on
// the other, through the precomputed NES_PALETTE_HI/LO tables below (exact
// sRGB piecewise pair, GAMMA=2.4; worst average-light error 0.37 % of full
// white, see tools/bfi_lottes.py). Dark and mid pixels (v <= 0.5: every NES
// colour but the brightest) land wholly in one refresh, i.e. full 50 %
// clarity; only bright pixels spill over. Mode 2 shows HI on every lit
// refresh (global parity); mode 3 flips the parity per screen half (top rows
// HI on lit refreshes, bottom rows HI on inserted ones), so the 60 Hz flicker
// has no whole-frame flash, at the same per-pixel brightness and clarity.
// Refresh pairs stay complementary and every pixel alternates HI/LO, so the
// phase swap below still averages LCD DC exactly as in mode 1.
// Credit: Mark Rejhon (Blur Busters) & Timothy Lottes (MIT, Dec 2024).
localparam [9:0] BEAM_SPLIT = 10'd240;  // mode-3 half split (top/bottom)
reg at_f0_q = 1'b0;
reg at_rel_q = 1'b0;
reg rel_tgl = 1'b0;
always @(posedge clk_pixel) begin
    at_f0_q <= (cy == 10'd0);
    if ((cy == 10'd0) && !at_f0_q) begin
        bfi_ins <= ~bfi_ins;
        if (bfi_swap_pending) begin
            bfi_phase <= ~bfi_phase;
            bfi_swap_pending <= 1'b0;
        end
    end
    at_rel_q <= (cy == RELEASE_ROW);
    if ((cy == RELEASE_ROW) && !at_rel_q && !bfi_ins) begin
        rel_tgl <= ~rel_tgl;
        if (bfi_swap_cnt == BFI_SWAP_FRAMES - 1) begin
            bfi_swap_cnt <= 16'd0;
            bfi_swap_pending <= 1'b1;
        end else
            bfi_swap_cnt <= bfi_swap_cnt + 16'd1;
    end
end
`else
//
// Frame lock: halt the NES once per frame so the PPU frame stays ahead of
// the HDMI read and the single framebuffer never tears.
//
// The NES frame (60.1775 Hz on console138k, 60.1379 Hz on console60k from the
// board PLLs, 262 lines of 341 PPU dots) is shorter than the native-rate
// 720p HDMI frame (60.1093 Hz at 1647 pixels per line, the largest line at
// or above the NES 60.0988 Hz). Halting the whole machine for the
// difference (about 8/19 us) once per frame locks the NES to exactly the
// HDMI rate, 0.017 % fast, with a fixed phase.
//
// Phase: the NES waits at the first vblank scanline (240, all of lines 0-239
// are written by then) and runs again when HDMI reaches RELEASE_ROW near the
// end of its frame. The NES frame then leads the HDMI frame by about 0.9 ms:
// the PPU finishes writing line 8 about 271 us before HDMI reads it (the
// tightest line; reads run slower than writes after that), and the wait
// absorbs the odd-frame short line and the de-jitter freeze. The release is
// edge-triggered (one toggle per HDMI frame over a synchroniser) so a late
// arrival waits for the next frame and the phase is exact every frame after
// at most two frames, including after reset, game reload and menu pause.
//
localparam HALT_LINE = 240;       // NES scanline at which to wait
localparam RELEASE_ROW = 647;     // HDMI row whose start releases the NES

// HDMI side: one toggle per frame as cy passes RELEASE_ROW
reg at_rel_q = 1'b0;
reg rel_tgl = 1'b0;
always @(posedge clk_pixel) begin
    at_rel_q <= (cy == RELEASE_ROW);
    if ((cy == RELEASE_ROW) && !at_rel_q)
        rel_tgl <= ~rel_tgl;
end
`endif

// NES side: synchronise the toggle, then wait/release (one release per
// game frame: per HDMI frame normally, per two HDMI frames with HZ120)
reg [2:0] rel_sync = 3'b0;
reg rel_lvl_q = 1'b0;
wire rel_pulse = rel_sync[2] ^ rel_lvl_q;   // one clk per release
reg halt_req = 1'b0;
reg was_halt_line = 1'b0;
always @(posedge clk) begin
    rel_sync <= {rel_sync[1:0], rel_tgl};
    rel_lvl_q <= rel_sync[2];
    was_halt_line <= (scanline == HALT_LINE);
    if (!resetn) begin
        rel_sync <= 3'b0;
        rel_lvl_q <= 1'b0;
        halt_req <= 1'b0;
        was_halt_line <= 1'b0;
    end else if (rel_pulse && halt_req)
        halt_req <= 1'b0;                       // HDMI at the release row: run
    else if ((scanline == HALT_LINE) && !was_halt_line)
        halt_req <= 1'b1;                       // line 239 written: wait
end
assign frame_halt = halt_req;

// audio stuff
//    localparam AUDIO_RATE=32000;        // weird only 32K sampling rate works
//    localparam AUDIO_RATE=96000;
localparam AUDIO_RATE=48000;
localparam AUDIO_CLK_DELAY = CLKFRQ * 1000 / AUDIO_RATE / 2;
logic [$clog2(AUDIO_CLK_DELAY)-1:0] audio_divider;
logic clk_audio;

always_ff@(posedge clk_pixel) 
begin
    if (audio_divider != AUDIO_CLK_DELAY - 1) 
        audio_divider++;
    else begin 
        clk_audio <= ~clk_audio; 
        audio_divider <= 0; 
    end
end

reg [15:0] audio_sample_word [1:0], audio_sample_word0 [1:0];
always @(posedge clk_pixel) begin       // crossing clock domain
    audio_sample_word0[0] <= sample;
    audio_sample_word[0] <= audio_sample_word0[0];
    audio_sample_word0[1] <= sample;
    audio_sample_word[1] <= audio_sample_word0[1];
end

`ifdef HZ120
//
// Video
// Scale 256x224 to 640x448 (4:3) in the 720x480 frame with the Integer
// scale (2 output rows per source line, centred at top 16), or to the full
// 640x480 frame with the Full scale (core_config[21]); see scanlines.v for
// the scanline geometry. Nearest neighbour.
//
`else
//
// Video
// Scale 256x224 to 960x720 (4:3), see scanlines.v for the scanline geometry:
// integer scale is 3 output rows per source line and 896x672, centred.
// Nearest neighbour.
//
`endif
localparam WIDTH=256;
localparam HEIGHT=240;
localparam LINES=224;       // lines of the picture
wire [23:0] rgb;            // actual RGB output
reg [23:0] rgb_pre;         // before video_fx
reg pic_pre;                // rgb_pre is a pixel of the picture, not the border or the overlay
reg dark_pre;
reg active                  /* xsynthesis syn_keep=1 */;
reg [$clog2(WIDTH)-1:0] xx  /* xsynthesis syn_keep=1 */; // scaled-down pixel position
reg [$clog2(HEIGHT)-1:0] yy /* xsynthesis syn_keep=1 */;
reg [10:0] xcnt             /* xsynthesis syn_keep=1 */;
reg [10:0] ycnt             /* xsynthesis syn_keep=1 */;                  // fractional scaling counters
reg [9:0] cy_r;

`ifdef HZ120
// scanlines: sl_geom frames are scaled 2 rows per source line, 640x448
// centred (top 16); at 2 rows per line thin and thick darken 1 row alike.
localparam [2:0] SL_ROWS = 3'd2;
localparam [2:0] SL_DTHICK = 3'd1;
localparam [9:0] SL_TOP = 10'd16;
`else
// scanlines: sl_geom frames are scaled 3 rows per source line, 896x672
localparam [2:0] SL_ROWS = 3'd3;
localparam [2:0] SL_DTHICK = 3'd2;
localparam [9:0] SL_TOP = 10'd24;
`endif
// The LCD grid (video_config[15]) is not offered on the NES: 3.5 output columns per source
// pixel is not a whole number. Bit 15 is cleared for sl_rows and video_fx, so the picture
// geometry never depends on it and the grid flags are tied low.
wire sl_geom, sl_show, sl_dark;
wire [7:0] sl_yy;
wire [1:0] sl_dk;
sl_rows sl (
    .clk(clk_pixel), .cy(cy),
    .cfg_on(scanlines), .cfg_dark(sl_darkness), .cfg_thick(sl_thick), .cfg_out(sl_out),
    .cfg_grid(1'b0), .hide(overlay),
    .rows(SL_ROWS), .dark_thin(3'd1), .dark_thick(SL_DTHICK), .lines(8'd224), .top(SL_TOP),
    .geom(sl_geom), .pic_top(), .yy(sl_yy), .show(sl_show), .dark(sl_dark), .last(), .darkness(sl_dk)
);
reg [7:0] yy_s;             // source line to show
always @(posedge clk_pixel) yy_s <= sl_geom ? sl_yy : yy;

assign mem_portB_addr = yy_s * WIDTH + xx + 8*256;
assign overlay_x = xx;
assign overlay_y = yy_s;
`ifdef HZ120
wire [11:0] XSIZE  = 12'd640;        // 4:3 at 480 lines, both geometries
wire [11:0] XSTART = (12'd720 - XSIZE) >> 1;
wire [11:0] XSTOP  = (12'd720 + XSIZE) >> 1;
`else
wire [11:0] XSIZE  = sl_geom ? 12'd896 : 12'd960;   // 4:3 on 720 rows, 4:3 on 672 rows
wire [11:0] XSTART = (12'd1280 - XSIZE) >> 1;
wire [11:0] XSTOP  = (12'd1280 + XSIZE) >> 1;
`endif

// address calculation
`ifdef HZ120
// Assume the video occupies fully on the Y direction, we are upscaling the video by `480/height`.
`else
// Assume the video occupies fully on the Y direction, we are upscaling the video by `720/height`.
`endif
// xcnt and ycnt are fractional scaling counters.
// video_fx follows rgb_pre with FX_LAT register stages. Its first stage is the one that sl_dim
// used to be (active started at XSTART - 2 then), so active starts FX_LAT - 1 clocks earlier
// than that, at XSTART - 1 - FX_LAT. The xx/xcnt counters, and so the overlay lookup, run with it.
localparam FX_LAT = 11;     // clocks from rgb_pre to rgb, see video_fx.v
always @(posedge clk_pixel) begin
    reg active_t;
    reg [10:0] xcnt_next;
    reg [10:0] ycnt_next;
    xcnt_next = xcnt + 256;
    ycnt_next = ycnt + 224;

    active_t = 0;
    if ({1'b0, cx} == XSTART - 12'd1 - FX_LAT) begin
        active_t = 1;
        active <= 1;
    end else if ({1'b0, cx} == XSTOP - 12'd1 - FX_LAT) begin
        active_t = 0;
        active <= 0;
    end

    if (active_t | active) begin        // increment xx
        xcnt <= xcnt_next;
        if (xcnt_next >= XSIZE) begin
            xcnt <= xcnt_next - XSIZE;
            xx <= xx + 1;
        end
    end

    cy_r <= cy;
    if (cy[0] != cy_r[0]) begin         // increment yy at new lines
        ycnt <= ycnt_next;
`ifdef HZ120
        if (ycnt_next >= 480) begin
            ycnt <= ycnt_next - 480;
`else
        if (ycnt_next >= 720) begin
            ycnt <= ycnt_next - 720;
`endif
            if (yy != LINES - 1) yy <= yy + 1;      // (the rows below the picture show the last line)
        end
    end

    if (cx == 0) begin
        xx <= 0;
        xcnt <= 0;
    end
    
    if (cy == 0) begin
        yy <= 0;
        ycnt <= 0;
    end 

end

`ifdef HZ120
// calc rgb value to hdmi. Mode 1 blacks the whole picture area (border
// included) on inserted refreshes; modes 2-3 show the precomputed HI/LO pair
// instead (see above). The menu overlay is exempt so the menu stays steady
// while the game is paused under it.
reg [23:0] NES_PALETTE [0:63];
reg [23:0] NES_PALETTE_HI [0:63];
reg [23:0] NES_PALETTE_LO [0:63];
localparam [23:0] BORDER_HI = 24'h454545;
localparam [23:0] BORDER_LO = 24'h000000;
wire bfi_eff_ins = bfi_ins ^ bfi_phase;
wire bfi_lottes = (bfi_mode == 2'd2) | (bfi_mode == 2'd3);
wire show_hi = ~bfi_eff_ins ^ ((bfi_mode == 2'd3) & (cy >= BEAM_SPLIT));
wire bfi_dark = ~overlay & (bfi_mode == 2'd1) & bfi_eff_ins;
reg [23:0] rgb_norm;
reg [23:0] rgb_hi, rgb_lo;
always @* begin
    if (active & sl_show) begin
        if (overlay)
            rgb_norm = {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};      // BGR5 to RGB8
        else
            rgb_norm = NES_PALETTE[mem_portB_rdata];
    end else
        rgb_norm = 24'h303030;
    if (overlay) begin
        rgb_hi = rgb_norm;
        rgb_lo = rgb_norm;
    end else if (active & sl_show) begin
        rgb_hi = NES_PALETTE_HI[mem_portB_rdata];
        rgb_lo = NES_PALETTE_LO[mem_portB_rdata];
    end else begin
        rgb_hi = BORDER_HI;
        rgb_lo = BORDER_LO;
    end
end
always @(posedge clk_pixel) begin
    if (bfi_lottes & ~overlay)
        rgb_pre <= show_hi ? rgb_hi : rgb_lo;
    else if (!bfi_dark)
        rgb_pre <= rgb_norm;
    else
        rgb_pre <= 24'h000000;      // black inserted refresh (mode 1)
    // Lottes modes carry real picture data on both refreshes, so both get
    // the same colour/scanline processing downstream (unlike black BFI).
    pic_pre <= active & sl_show & ~overlay & (~bfi_dark | bfi_lottes);
    dark_pre <= active & sl_show & ~overlay & sl_dark & (~bfi_dark | bfi_lottes);
end
`else
// calc rgb value to hdmi
reg [23:0] NES_PALETTE [0:63];
always @(posedge clk_pixel) begin
    if (active & sl_show) begin
        if (overlay)
            rgb_pre <= {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};      // BGR5 to RGB8
        else
            rgb_pre <= NES_PALETTE[mem_portB_rdata];
    end else
        rgb_pre <= 24'h303030;
    pic_pre <= active & sl_show & ~overlay;
    dark_pre <= active & sl_show & ~overlay & sl_dark;
end
`endif

// colour controls, the scanline darkening and the CRT mask
video_fx fx (
    .clk(clk_pixel), .cx(cx), .cy(cy), .video_config({video_config[31:16], 1'b0, video_config[14:0]}),
    .rgb_in(rgb_pre), .pic_in(pic_pre), .dark_in(dark_pre), .darkness(sl_dk),
    .col_last_in(1'b0), .row_last_in(1'b0),
    .rgb_out(rgb)
);

// HDMI output.
logic[2:0] tmds;

hdmi #( .VIDEO_ID_CODE(VIDEOID), 
        .DVI_OUTPUT(0), 
        .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE), 
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .START_X(0),
        .START_Y(0),
        .NATIVE_FRAME_WIDTH(NATIVE_LINE) )

hdmi( .clk_pixel_x5(clk_5x_pixel), 
        .clk_pixel(clk_pixel), 
        .clk_audio(clk_audio),
        .rgb(rgb), 
        .reset( 0 ),
        .std_timing(std_timing),
        .audio_sample_word(audio_sample_word),
        .tmds(tmds), 
        .tmds_clock(tmdsClk), 
        .cx(cx), 
        .cy(cy),
        .frame_width( frameWidth ),
        .frame_height( frameHeight ) );

// Gowin LVDS output buffer
ELVDS_OBUF tmds_bufds [3:0] (
    .I({clk_pixel, tmds}),
    .O({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);

// 2C02 palette: https://www.nesdev.org/wiki/PPU_palettes
assign NES_PALETTE[0] = 24'h545454;  assign NES_PALETTE[1] = 24'h001e74;  assign NES_PALETTE[2] = 24'h081090;  assign NES_PALETTE[3] = 24'h300088;  
assign NES_PALETTE[4] = 24'h440064;  assign NES_PALETTE[5] = 24'h5c0030;  assign NES_PALETTE[6] = 24'h540400;  assign NES_PALETTE[7] = 24'h3c1800;
assign NES_PALETTE[8] = 24'h202a00;  assign NES_PALETTE[9] = 24'h083a00;  assign NES_PALETTE[10] = 24'h004000;  assign NES_PALETTE[11] = 24'h003c00;  
assign NES_PALETTE[12] = 24'h00323c;  assign NES_PALETTE[13] = 24'h000000;  assign NES_PALETTE[14] = 24'h000000;  assign NES_PALETTE[15] = 24'h000000;
assign NES_PALETTE[16] = 24'h989698;  assign NES_PALETTE[17] = 24'h084cc4;  assign NES_PALETTE[18] = 24'h3032ec;  assign NES_PALETTE[19] = 24'h5c1ee4;  
assign NES_PALETTE[20] = 24'h8814b0;  assign NES_PALETTE[21] = 24'ha01464;  assign NES_PALETTE[22] = 24'h982220;  assign NES_PALETTE[23] = 24'h783c00;
assign NES_PALETTE[24] = 24'h545a00;  assign NES_PALETTE[25] = 24'h287200;  assign NES_PALETTE[26] = 24'h087c00;  assign NES_PALETTE[27] = 24'h007628; 
assign NES_PALETTE[28] = 24'h006678;  assign NES_PALETTE[29] = 24'h000000;  assign NES_PALETTE[30] = 24'h000000;  assign NES_PALETTE[31] = 24'h000000;
assign NES_PALETTE[32] = 24'heceeec;  assign NES_PALETTE[33] = 24'h4c9aec;  assign NES_PALETTE[34] = 24'h787cec;  assign NES_PALETTE[35] = 24'hb062ec;  
assign NES_PALETTE[36] = 24'he454ec;  assign NES_PALETTE[37] = 24'hec58b4;  assign NES_PALETTE[38] = 24'hec6a64;  assign NES_PALETTE[39] = 24'hd48820;
assign NES_PALETTE[40] = 24'ha0aa00;  assign NES_PALETTE[41] = 24'h74c400;  assign NES_PALETTE[42] = 24'h4cd020;  assign NES_PALETTE[43] = 24'h38cc6c; 
assign NES_PALETTE[44] = 24'h38b4cc;  assign NES_PALETTE[45] = 24'h3c3c3c;  assign NES_PALETTE[46] = 24'h000000;  assign NES_PALETTE[47] = 24'h000000;
assign NES_PALETTE[48] = 24'heceeec;  assign NES_PALETTE[49] = 24'ha8ccec;  assign NES_PALETTE[50] = 24'hbcbcec;  assign NES_PALETTE[51] = 24'hd4b2ec;
assign NES_PALETTE[52] = 24'hecaeec;  assign NES_PALETTE[53] = 24'hecaed4;  assign NES_PALETTE[54] = 24'hecb4b0;  assign NES_PALETTE[55] = 24'he4c490;
assign NES_PALETTE[56] = 24'hccd278;  assign NES_PALETTE[57] = 24'hb4de78;  assign NES_PALETTE[58] = 24'ha8e290;  assign NES_PALETTE[59] = 24'h98e2b4;
assign NES_PALETTE[60] = 24'ha0d6e4;  assign NES_PALETTE[61] = 24'ha0a2a0;  assign NES_PALETTE[62] = 24'h000000;  assign NES_PALETTE[63] = 24'h000000;

`ifdef HZ120
// BEGIN Lottes tables (tools/bfi_lottes.py, sRGB GAMMA=2.4).
// Per input code: HI = lit-refresh value, LO = remainder refresh.
// [0] 545454 -> HI 757575 LO 000000
// [1] 001e74 -> HI 002da0 LO 000000
// [2] 081090 -> HI 0f1ac5 LO 000000
// [3] 300088 -> HI 4500ba LO 000000
// [4] 440064 -> HI 5f008a LO 000000
// [5] 5c0030 -> HI 800045 LO 000000
// [6] 540400 -> HI 750800 LO 000000
// [7] 3c1800 -> HI 552500 LO 000000
// [8] 202a00 -> HI 2f3d00 LO 000000
// [9] 083a00 -> HI 0f5200 LO 000000
// [10] 004000 -> HI 005a00 LO 000000
// [11] 003c00 -> HI 005500 LO 000000
// [12] 00323c -> HI 004755 LO 000000
// [13] 000000 -> HI 000000 LO 000000
// [14] 000000 -> HI 000000 LO 000000
// [15] 000000 -> HI 000000 LO 000000
// [16] 989698 -> HI d0cdd0 LO 000000
// [17] 084cc4 -> HI 0f6aff LO 00005b
// [18] 3032ec -> HI 4547ff LO 0000d7
// [19] 5c1ee4 -> HI 802dff LO 0000c4
// [20] 8814b0 -> HI ba1ff0 LO 000000
// [21] a01464 -> HI da1f8a LO 000000
// [22] 982220 -> HI d0322f LO 000000
// [23] 783c00 -> HI a55500 LO 000000
// [24] 545a00 -> HI 757d00 LO 000000
// [25] 287200 -> HI 3a9d00 LO 000000
// [26] 087c00 -> HI 0faa00 LO 000000
// [27] 007628 -> HI 00a23a LO 000000
// [28] 006678 -> HI 008da5 LO 000000
// [29] 000000 -> HI 000000 LO 000000
// [30] 000000 -> HI 000000 LO 000000
// [31] 000000 -> HI 000000 LO 000000
// [32] eceeec -> HI ffffff LO d7dbd7
// [33] 4c9aec -> HI 6ad2ff LO 0000d7
// [34] 787cec -> HI a5aaff LO 0000d7
// [35] b062ec -> HI f088ff LO 0000d7
// [36] e454ec -> HI ff75ff LO c400d7
// [37] ec58b4 -> HI ff7af5 LO d70000
// [38] ec6a64 -> HI ff928a LO d70000
// [39] d48820 -> HI ffba2f LO 990000
// [40] a0aa00 -> HI dae800 LO 000000
// [41] 74c400 -> HI a0ff00 LO 005b00
// [42] 4cd020 -> HI 6aff2f LO 008c00
// [43] 38cc6c -> HI 4fff95 LO 007e00
// [44] 38b4cc -> HI 4ff5ff LO 00007e
// [45] 3c3c3c -> HI 555555 LO 000000
// [46] 000000 -> HI 000000 LO 000000
// [47] 000000 -> HI 000000 LO 000000
// [48] eceeec -> HI ffffff LO d7dbd7
// [49] a8ccec -> HI e5ffff LO 007ed7
// [50] bcbcec -> HI ffffff LO 1111d7
// [51] d4b2ec -> HI fff2ff LO 9900d7
// [52] ecaeec -> HI ffedff LO d700d7
// [53] ecaed4 -> HI ffedff LO d70099
// [54] ecb4b0 -> HI fff5f0 LO d70000
// [55] e4c490 -> HI ffffc5 LO c45b00
// [56] ccd278 -> HI ffffa5 LO 7e9200
// [57] b4de78 -> HI f5ffa5 LO 00b500
// [58] a8e290 -> HI e5ffc5 LO 00bf00
// [59] 98e2b4 -> HI d0fff5 LO 00bf00
// [60] a0d6e4 -> HI daffff LO 009fc4
// [61] a0a2a0 -> HI daddda LO 000000
// [62] 000000 -> HI 000000 LO 000000
// [63] 000000 -> HI 000000 LO 000000
// HI table (lit refresh):
assign NES_PALETTE_HI[0] = 24'h757575;
assign NES_PALETTE_HI[1] = 24'h002da0;
assign NES_PALETTE_HI[2] = 24'h0f1ac5;
assign NES_PALETTE_HI[3] = 24'h4500ba;
assign NES_PALETTE_HI[4] = 24'h5f008a;
assign NES_PALETTE_HI[5] = 24'h800045;
assign NES_PALETTE_HI[6] = 24'h750800;
assign NES_PALETTE_HI[7] = 24'h552500;
assign NES_PALETTE_HI[8] = 24'h2f3d00;
assign NES_PALETTE_HI[9] = 24'h0f5200;
assign NES_PALETTE_HI[10] = 24'h005a00;
assign NES_PALETTE_HI[11] = 24'h005500;
assign NES_PALETTE_HI[12] = 24'h004755;
assign NES_PALETTE_HI[13] = 24'h000000;
assign NES_PALETTE_HI[14] = 24'h000000;
assign NES_PALETTE_HI[15] = 24'h000000;
assign NES_PALETTE_HI[16] = 24'hd0cdd0;
assign NES_PALETTE_HI[17] = 24'h0f6aff;
assign NES_PALETTE_HI[18] = 24'h4547ff;
assign NES_PALETTE_HI[19] = 24'h802dff;
assign NES_PALETTE_HI[20] = 24'hba1ff0;
assign NES_PALETTE_HI[21] = 24'hda1f8a;
assign NES_PALETTE_HI[22] = 24'hd0322f;
assign NES_PALETTE_HI[23] = 24'ha55500;
assign NES_PALETTE_HI[24] = 24'h757d00;
assign NES_PALETTE_HI[25] = 24'h3a9d00;
assign NES_PALETTE_HI[26] = 24'h0faa00;
assign NES_PALETTE_HI[27] = 24'h00a23a;
assign NES_PALETTE_HI[28] = 24'h008da5;
assign NES_PALETTE_HI[29] = 24'h000000;
assign NES_PALETTE_HI[30] = 24'h000000;
assign NES_PALETTE_HI[31] = 24'h000000;
assign NES_PALETTE_HI[32] = 24'hffffff;
assign NES_PALETTE_HI[33] = 24'h6ad2ff;
assign NES_PALETTE_HI[34] = 24'ha5aaff;
assign NES_PALETTE_HI[35] = 24'hf088ff;
assign NES_PALETTE_HI[36] = 24'hff75ff;
assign NES_PALETTE_HI[37] = 24'hff7af5;
assign NES_PALETTE_HI[38] = 24'hff928a;
assign NES_PALETTE_HI[39] = 24'hffba2f;
assign NES_PALETTE_HI[40] = 24'hdae800;
assign NES_PALETTE_HI[41] = 24'ha0ff00;
assign NES_PALETTE_HI[42] = 24'h6aff2f;
assign NES_PALETTE_HI[43] = 24'h4fff95;
assign NES_PALETTE_HI[44] = 24'h4ff5ff;
assign NES_PALETTE_HI[45] = 24'h555555;
assign NES_PALETTE_HI[46] = 24'h000000;
assign NES_PALETTE_HI[47] = 24'h000000;
assign NES_PALETTE_HI[48] = 24'hffffff;
assign NES_PALETTE_HI[49] = 24'he5ffff;
assign NES_PALETTE_HI[50] = 24'hffffff;
assign NES_PALETTE_HI[51] = 24'hfff2ff;
assign NES_PALETTE_HI[52] = 24'hffedff;
assign NES_PALETTE_HI[53] = 24'hffedff;
assign NES_PALETTE_HI[54] = 24'hfff5f0;
assign NES_PALETTE_HI[55] = 24'hffffc5;
assign NES_PALETTE_HI[56] = 24'hffffa5;
assign NES_PALETTE_HI[57] = 24'hf5ffa5;
assign NES_PALETTE_HI[58] = 24'he5ffc5;
assign NES_PALETTE_HI[59] = 24'hd0fff5;
assign NES_PALETTE_HI[60] = 24'hdaffff;
assign NES_PALETTE_HI[61] = 24'hdaddda;
assign NES_PALETTE_HI[62] = 24'h000000;
assign NES_PALETTE_HI[63] = 24'h000000;
// LO table (remainder refresh):
assign NES_PALETTE_LO[0] = 24'h000000;
assign NES_PALETTE_LO[1] = 24'h000000;
assign NES_PALETTE_LO[2] = 24'h000000;
assign NES_PALETTE_LO[3] = 24'h000000;
assign NES_PALETTE_LO[4] = 24'h000000;
assign NES_PALETTE_LO[5] = 24'h000000;
assign NES_PALETTE_LO[6] = 24'h000000;
assign NES_PALETTE_LO[7] = 24'h000000;
assign NES_PALETTE_LO[8] = 24'h000000;
assign NES_PALETTE_LO[9] = 24'h000000;
assign NES_PALETTE_LO[10] = 24'h000000;
assign NES_PALETTE_LO[11] = 24'h000000;
assign NES_PALETTE_LO[12] = 24'h000000;
assign NES_PALETTE_LO[13] = 24'h000000;
assign NES_PALETTE_LO[14] = 24'h000000;
assign NES_PALETTE_LO[15] = 24'h000000;
assign NES_PALETTE_LO[16] = 24'h000000;
assign NES_PALETTE_LO[17] = 24'h00005b;
assign NES_PALETTE_LO[18] = 24'h0000d7;
assign NES_PALETTE_LO[19] = 24'h0000c4;
assign NES_PALETTE_LO[20] = 24'h000000;
assign NES_PALETTE_LO[21] = 24'h000000;
assign NES_PALETTE_LO[22] = 24'h000000;
assign NES_PALETTE_LO[23] = 24'h000000;
assign NES_PALETTE_LO[24] = 24'h000000;
assign NES_PALETTE_LO[25] = 24'h000000;
assign NES_PALETTE_LO[26] = 24'h000000;
assign NES_PALETTE_LO[27] = 24'h000000;
assign NES_PALETTE_LO[28] = 24'h000000;
assign NES_PALETTE_LO[29] = 24'h000000;
assign NES_PALETTE_LO[30] = 24'h000000;
assign NES_PALETTE_LO[31] = 24'h000000;
assign NES_PALETTE_LO[32] = 24'hd7dbd7;
assign NES_PALETTE_LO[33] = 24'h0000d7;
assign NES_PALETTE_LO[34] = 24'h0000d7;
assign NES_PALETTE_LO[35] = 24'h0000d7;
assign NES_PALETTE_LO[36] = 24'hc400d7;
assign NES_PALETTE_LO[37] = 24'hd70000;
assign NES_PALETTE_LO[38] = 24'hd70000;
assign NES_PALETTE_LO[39] = 24'h990000;
assign NES_PALETTE_LO[40] = 24'h000000;
assign NES_PALETTE_LO[41] = 24'h005b00;
assign NES_PALETTE_LO[42] = 24'h008c00;
assign NES_PALETTE_LO[43] = 24'h007e00;
assign NES_PALETTE_LO[44] = 24'h00007e;
assign NES_PALETTE_LO[45] = 24'h000000;
assign NES_PALETTE_LO[46] = 24'h000000;
assign NES_PALETTE_LO[47] = 24'h000000;
assign NES_PALETTE_LO[48] = 24'hd7dbd7;
assign NES_PALETTE_LO[49] = 24'h007ed7;
assign NES_PALETTE_LO[50] = 24'h1111d7;
assign NES_PALETTE_LO[51] = 24'h9900d7;
assign NES_PALETTE_LO[52] = 24'hd700d7;
assign NES_PALETTE_LO[53] = 24'hd70099;
assign NES_PALETTE_LO[54] = 24'hd70000;
assign NES_PALETTE_LO[55] = 24'hc45b00;
assign NES_PALETTE_LO[56] = 24'h7e9200;
assign NES_PALETTE_LO[57] = 24'h00b500;
assign NES_PALETTE_LO[58] = 24'h00bf00;
assign NES_PALETTE_LO[59] = 24'h00bf00;
assign NES_PALETTE_LO[60] = 24'h009fc4;
assign NES_PALETTE_LO[61] = 24'h000000;
assign NES_PALETTE_LO[62] = 24'h000000;
assign NES_PALETTE_LO[63] = 24'h000000;
// border 303030 -> HI 24'h454545 LO 24'h000000
`endif

endmodule
