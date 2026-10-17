// NES video and sound to HDMI converter
// nand2mario, 2022.9

`timescale 1ns / 1ps

module nes2hdmi #(
    // 0 compiles the smoothing blend out (nearest-neighbour)
    parameter bit SMOOTH_EN = 1'b1
) (
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
    input sl_out,           // core_config[21]: dark output rows instead of an integer scale
    input [31:0] video_config,  // colour controls, CRT mask and smoothing, see video_fx.v, smooth.v (the LCD grid is unused)

    // overlay interface
    input overlay,
    output [7:0] overlay_x,
    output [7:0] overlay_y,
    input [14:0] overlay_color, // BGR5

	// video clocks
	input clk_pixel,
	input clk_5x_pixel,

    // 1: standard 120.00 Hz 480p; 0: native NES rate x2 (855-pixel lines)
    input std_timing,
    // BFI mode (video_config[21:20] in hardware, runtime-switchable):
    // 0 off (every console frame shown twice, both refreshes lit),
    // 1 black inserted refresh, 2 dim (50 %) inserted refresh,
    // 3 rolling scan (prototype): each refresh lights a contiguous half
    // of the rows, rolling down; the other half is black. The game menu
    // (overlay) is lit on every refresh in every mode.
    input [1:0] bfi_mode,

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

localparam FRAMEWIDTH = 720;
localparam FRAMEHEIGHT = 480;
localparam TOTALWIDTH = 858;
localparam TOTALHEIGHT = 525;
localparam SCALE = 5;
localparam VIDEOID = 48;            // 480p120: VIC 2/3 totals at 54 MHz, for BFI
localparam VIDEO_REFRESH = 120.0;   // the audio clock regeneration only: the line is NATIVE below
// 54 MHz / (855x525) = 120.3008 Hz, twice 60.1504 Hz: the largest
// whole-pixel line at or above twice the NES 60.0988 Hz that the console138k
// NES clock can still lock (free-run 60.1775 Hz, 7.5 us halt); the 856 line
// would run 60.0816 Hz, below native, and 855 is too fast for console60k
// (free-run 60.1379 Hz), so this test build is console138k-only
// (21.477272 MHz / 4 / 89341.5 dots)
localparam NATIVE_LINE = 855;

// localparam IDIV_SEL_X5 = 3;
// localparam FBDIV_SEL_X5 = 54;
// localparam ODIV_SEL_X5 = 2;
// localparam DUTYDA_SEL_X5 = "1000";
// localparam DYN_SDIV_SEL_X5 = 2;
  
localparam CLKFRQ = 54000;

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
// Mode 3 (rolling scan prototype): each refresh lights a contiguous half of
// the 480 active rows, the lit half rolling down by ROLL_STEP rows per game
// frame. The two refreshes of a pair show complementary halves, so like
// modes 1-2 every row is lit half the time at the same average brightness,
// but the light is spread over the frame (a band sweeping down, CRT-style)
// instead of flashing whole frames. One narrow-beam strobe per row per pair
// keeps the motion-blur reduction of mode 1 (Blur Busters: one strobe per
// point per refresh; halving the strobe halves eye-tracking blur); a true
// dark-90 % beam would need a 10x backlight, so the prototype keeps 50 %
// duty. The beam rolls one full sweep per second (480 rows / 8 per game
// frame / 60 game frames). The phase swap flips which half the first
// refresh lights, so DC averages like modes 1-3.
localparam [9:0] ROLL_ROWS = 10'd480;  // active rows the band rolls over
localparam [9:0] ROLL_STEP = 10'd8;    // rows per game frame
localparam [9:0] ROLL_HALF = 10'd240;  // rows lit per refresh
reg [9:0] roll_beam = 10'd0;           // first lit row of the even refresh
wire [9:0] roll_next = roll_beam + ROLL_STEP;
reg at_f0_q = 1'b0;
reg at_rel_q = 1'b0;
reg rel_tgl = 1'b0;
always @(posedge clk_pixel) begin
    at_f0_q <= (cy == 10'd0);
    if ((cy == 10'd0) && !at_f0_q) begin
        bfi_ins <= ~bfi_ins;
        // the release frame starts here: roll the band now so every HDMI
        // frame shows one uniform beam position (a mid-frame step would
        // light 240 +/- 8 rows and break the pair complement)
        if (bfi_ins) begin
            if (roll_next >= ROLL_ROWS) roll_beam <= roll_next - ROLL_ROWS;
            else roll_beam <= roll_next;
        end
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

// NES side: synchronise the toggle, then wait/release
reg [2:0] rel_sync = 3'b0;
reg rel_lvl_q = 1'b0;
wire rel_pulse = rel_sync[2] ^ rel_lvl_q;   // one clk per game frame (two HDMI frames)
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

//
// Video
// Scale 256x224 to 640x448 (4:3) in the 720x480 frame, see scanlines.v for the scanline geometry:
// with scanlines on, 2 output rows per source line, centred (top 16).
// Nearest neighbour; smooth.v blends the source pixels (video_config[19:18]). For that the
// frame buffer is read twice per source column, the line to show and its neighbour line.
//
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

// scanlines: sl_geom frames are scaled 2 rows per source line, 640x448
// centred (top 16); at 2 rows per line thin and thick coincide (1 dark row).
// The LCD grid (video_config[15]) is not offered on the NES: 3.5 output columns per source
// pixel is not a whole number. Bit 15 is cleared for sl_rows and video_fx, so the picture
// geometry never depends on it and the grid flags are tied low.
wire sl_geom, sl_show, sl_dark, sl_last;
wire [7:0] sl_yy;
wire [1:0] sl_dk;
sl_rows sl (
    .clk(clk_pixel), .cy(cy),
    .cfg_on(scanlines), .cfg_dark(sl_darkness), .cfg_thick(sl_thick), .cfg_out(sl_out),
    .cfg_grid(1'b0), .hide(overlay),
    .rows(3'd2), .dark_thin(3'd1), .dark_thick(3'd1), .lines(8'd224), .top(10'd16),
    .geom(sl_geom), .pic_top(), .yy(sl_yy), .show(sl_show), .dark(sl_dark), .last(sl_last), .darkness(sl_dk)
);
reg [7:0] yy_s;             // source line to show
always @(posedge clk_pixel) yy_s <= sl_geom ? sl_yy : yy;

// smoothing: the frame buffer is read for line yy_s and for yb_s, one clock each in turn
wire [1:0] sm_mode;
wire sm_rd_b;
wire [23:0] sm_rgb;
reg [7:0] yb_s;             // the neighbour line to blend with
wire [7:0] ysel = sm_rd_b ? yb_s : yy_s;
wire [7:0] xx_ov;           // xx, SM_LAT clocks old
assign mem_portB_addr = ysel * WIDTH + xx + 8*256;
assign overlay_x = xx_ov;
assign overlay_y = yy_s;
wire [11:0] XSIZE  = 12'd640;        // 4:3 at 480 lines, both geometries
wire [11:0] XSTART = (12'd720 - XSIZE) >> 1;
wire [11:0] XSTOP  = (12'd720 + XSIZE) >> 1;

// address calculation
// Assume the video occupies fully on the Y direction, we are upscaling the video by `480/height`.
// xcnt and ycnt are fractional scaling counters.
// video_fx follows rgb_pre with FX_LAT register stages. Its first stage is the one that sl_dim
// used to be (active started at XSTART - 2 then), so active starts FX_LAT - 1 clocks earlier
// than that, at XSTART - 1 - FX_LAT. The smoothing is between the frame buffer and rgb_pre:
// rgb_pre comes SM_LAT clocks later than the palette lookup alone would give it, so active
// starts SM_LAT clocks earlier still. The xx/xcnt counters run with it; the overlay lookup
// address (xx_ov) and `active` are delayed back by SM_LAT, so the picture, the overlay and
// the border land where they did.
localparam FX_LAT = 11;     // clocks from rgb_pre to rgb, see video_fx.v
localparam SM_LAT = 9;      // the palette lookup is followed by smooth.v (LAT 8) and the rgb_pre register
reg cnew = 1'b0;            // the frame buffer address is the first of a source column
always @(posedge clk_pixel) begin
    reg active_t;
    reg [10:0] xcnt_next;
    reg [10:0] ycnt_next;
    xcnt_next = xcnt + 256;
    ycnt_next = ycnt + 224;

    active_t = 0;
    if ({1'b0, cx} == XSTART - 12'd1 - FX_LAT - SM_LAT) begin
        active_t = 1;
        active <= 1;
    end else if ({1'b0, cx} == XSTOP - 12'd1 - FX_LAT - SM_LAT) begin
        active_t = 0;
        active <= 0;
    end

    // the first source column starts with the first pixel, the others when xx changes
    cnew <= ({1'b0, cx} == XSTART - 12'd2 - FX_LAT - SM_LAT) | ((active_t | active) & (xcnt_next >= XSIZE));

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
        if (ycnt_next >= 480) begin
            ycnt <= ycnt_next - 480;
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

// xx and active, delayed by SM_LAT
reg [8*SM_LAT-1:0] xx_sh;
reg [SM_LAT-1:0] act_sh;
always @(posedge clk_pixel) begin
    xx_sh <= {xx_sh[8*SM_LAT-9:0], xx};
    act_sh <= {act_sh[SM_LAT-2:0], active};
end
assign xx_ov = xx_sh[8*SM_LAT-1 -: 8];
wire active_d = act_sh[SM_LAT-1];

// The weights of the blend, from the same counters (smooth.v). Horizontally the output pixel
// is 256 of the 640 units of a source pixel, vertically 224 of 480.
localparam [16:0] KX_HALF_640 = (65536 * 128 + 640 / 2) / 640;
localparam [16:0] KY_STEP = (65536 * 256 + 224 / 2) / 224;
localparam [16:0] KY_HALF = (65536 * 128 + 480 / 2) / 480;
wire [7:0] wx, wy_ax;
wire hnext, vnext_ax;
smooth_axis ax (
    .clk(clk_pixel), .mode(sm_mode), .pos(xcnt), .step(11'd256), .size(XSIZE),
    .k_step(17'd65536), .k_half(KX_HALF_640),
    .first(xx == 8'd0), .last(xx == 8'd255), .w(wx), .next(hnext)
);
smooth_axis ay (
    .clk(clk_pixel), .mode(sm_mode), .pos(ycnt), .step(11'd224), .size(12'd480),
    .k_step(KY_STEP), .k_half(KY_HALF),
    .first(yy_s == 8'd0), .last(yy_s == LINES - 1), .w(wy_ax), .next(vnext_ax)
);

// Scanline frames show 2 rows per source line: soft blends each row 1/2
// towards its neighbour line. Sharp has nothing to blend, the rows are whole.
reg sl_last_p, sl_show_p;           // the previous output row
always @(posedge clk_pixel)
    if (cy[0] != cy_r[0]) begin
        sl_last_p <= sl_last;
        sl_show_p <= sl_show;
    end
localparam [7:0] W_HALF = 8'd128;   // round(256 / 2)
wire row_first = ~sl_show_p | sl_last_p;
wire geom_blend = (sm_mode == 2'd2) & ((row_first & (yy_s != 8'd0)) | (sl_last & (yy_s != LINES - 1)));
wire [7:0] wy = sl_geom ? (geom_blend ? W_HALF : 8'd0) : wy_ax;
wire vnext = sl_geom ? sl_last : vnext_ax;
always @(posedge clk_pixel)
    yb_s <= vnext ? ((yy_s == LINES - 1) ? yy_s : yy_s + 8'd1)
                  : ((yy_s == 8'd0) ? yy_s : yy_s - 8'd1);

// the palette lookup, and the first-of-column flag with it
reg [23:0] NES_PALETTE [0:63];
reg [23:0] pal_q;
reg cn1, cn2;
always @(posedge clk_pixel) begin
    pal_q <= NES_PALETTE[mem_portB_rdata];
    cn1 <= cnew;
    cn2 <= cn1;
end

smooth sm (
    .clk(clk_pixel), .cy(cy), .cfg(SMOOTH_EN ? video_config[19:18] : 2'd0), .mode(sm_mode),
    .rd_b(sm_rd_b), .rd_rgb(pal_q), .col_new(cn2), .wx(wx), .hnext(hnext), .wy(wy),
    .rgb_out(sm_rgb)
);

// calc rgb value to hdmi. In an inserted BFI frame the whole picture area
// (border included) is black or dimmed; in rolling mode the unlit half of
// the rows is black. The menu overlay is exempt so the menu stays steady
// while the game is paused under it.
wire bfi_eff_ins = bfi_ins ^ bfi_phase;
wire [9:0] roll_d = (cy >= roll_beam) ? cy - roll_beam : cy - roll_beam + ROLL_ROWS;
wire roll_dark = ((roll_d < ROLL_HALF) == bfi_eff_ins);
wire bfi_dark = ~overlay & ((((bfi_mode == 2'd1) | (bfi_mode == 2'd2)) & bfi_eff_ins) |
                            ((bfi_mode == 2'd3) & roll_dark));
reg [23:0] rgb_norm;
always @* begin
    if (active_d & sl_show) begin
        if (overlay)
            rgb_norm = {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};      // BGR5 to RGB8
        else
            rgb_norm = sm_rgb;
    end else
        rgb_norm = 24'h303030;
end
always @(posedge clk_pixel) begin
    if (!bfi_dark)
        rgb_pre <= rgb_norm;
    else if (bfi_mode == 2'd2)
        rgb_pre <= {1'b0, rgb_norm[23:17], 1'b0, rgb_norm[15:9], 1'b0, rgb_norm[7:1]};
    else
        rgb_pre <= 24'h000000;      // black inserted refresh (mode 1) or unlit rolling rows (mode 3)
    pic_pre <= active_d & sl_show & ~overlay & ~bfi_dark;
    dark_pre <= active_d & sl_show & ~overlay & sl_dark & ~bfi_dark;
end

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

endmodule
