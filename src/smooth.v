// Picture smoothing for the TangCore video scalers (the same file is in every core).
//
// A scaler by a non-integer factor (3.75 or 3.5 output columns per source pixel,
// 720 / 224 rows per source line) shows some source pixels 3 columns wide and others 4,
// and some lines 3 rows tall and others 4. Smoothing evens that out by blending the
// source pixels, on RGB and before video_fx, so colour, scanlines, CRT mask and LCD grid
// act on the smoothed picture.
//
// video_config bits (the firmware sets them, they may change at any time; the mode
// is latched at the start of every frame):
//   [19:18] smoothing: 0 = off, 1 = sharp, 2 = soft, 3 = reserved (same as 0)
//
// sharp   Each output pixel is the average of the source over the area it covers, so the
//         output pixels inside a source pixel keep its colour and only the one column
//         (row) that straddles a boundary is a blend. The pixel art stays crisp, and
//         every source pixel gets its fair width.
// soft    Bilinear interpolation between the centres of neighbouring source pixels:
//         every output pixel is a blend, the picture is softer (blurrier).
// off     rgb_out is the nearest-neighbour pixel the scaler showed before: with the mode
//         off the output is bit-identical to a scaler without smoothing, whatever the
//         other inputs do.
//
// The scaling is separable. The vertical blend is done first, once per source column
// (the line `a` the scaler shows and its neighbour line `b`, weight wy), the horizontal
// one on the result (the column the scaler shows and its neighbour column, weight wx).
// A blend is  c + ((n - c) * w + 128) >> 8  per channel, w = 0..255 (1/256 units):
// the nearest pixel moved towards its neighbour, rounded to nearest (half up).
//
// What the scaler provides (all in the pixel clock domain). It addresses its frame or
// line buffer as before, but twice per source column: rd_b says, every clock, whether
// this clock's read is of the line `a` (0) or of the neighbour line `b` (1). The column
// is held for at least 3 clocks (the scale is at least 3x), so one read port is enough.
//   rd_rgb    the pixel read two clocks earlier, after the palette (what rgb_pre was)
//   col_new   aligned with rd_rgb: the read is the first of a new source column
//             (the column address changed on this clock's address cycle)
//   wx, hnext aligned with rd_rgb: for the output pixel that this read starts, the weight
//             of its horizontal neighbour and whether it is the next column (1) or the
//             previous one (0). 0 at the ends of the line. (smooth_axis makes both.)
//   wy        weight of the neighbour line `b` for the current output row; constant
//             during a row. The scaler chooses the line `b` (the next or the previous
//             line, or any, with wy = 0) and addresses it when rd_b is set.
// A scaler can use the pixel it got from the nearest-neighbour address as `a` and
// the line above or below as `b`; the line `b` of the first and last line is never
// blended (wy = 0).
//
// Timing. For the output pixel whose address cycle is clock t, rd_rgb is at t + 2 and
// rgb_out at t + 2 + LAT (LAT = 9). Without smoothing the scaler's pixel was ready at
// t + 2, so the scaler starts its counters, and so its `active` window, LAT clocks earlier
// than it did (one more if it registers rgb_out, as nes2hdmi does), and delays what goes
// with the pixel (the overlay lookup address, the flags) by the same number of clocks:
// the picture stays on the same pixels.

module smooth (
    input             clk,              // pixel clock, 74.25 MHz
    input       [9:0] cy,               // output row, from the hdmi module
    input       [1:0] cfg,              // video_config[19:18], any clock domain
    output      [1:0] mode,             // this frame: 0 off, 1 sharp, 2 soft; for smooth_axis

    output            rd_b,             // read the neighbour line `b` on this clock's address cycle
    input      [23:0] rd_rgb,           // RGB of the read, two clocks after the address cycle
    input             col_new,          // aligned with rd_rgb: first read of a new source column
    input       [7:0] wx,               // horizontal weight and direction, aligned with rd_rgb
    input             hnext,
    input       [7:0] wy,               // vertical weight, constant during a row

    output reg [23:0] rgb_out           // LAT clocks after rd_rgb
);

    localparam LAT = 9;

    // the mode: synchronised to the pixel clock, latched at the start of every frame
    reg [1:0] cfg_a, cfg_b;
    reg [1:0] cfg_l = 2'd0;
    reg       cy0_r = 1'b1;
    always @(posedge clk) begin
        cfg_a <= cfg;
        cfg_b <= cfg_a;
        cy0_r <= (cy == 10'd0);
        if (cy == 10'd0 && !cy0_r)
            cfg_l <= cfg_b;
    end
    assign mode = (cfg_l == 2'd3) ? 2'd0 : cfg_l;
    wire on = (mode != 2'd0);

    // alternate reads: line a, line b. ph_r[1] says which one rd_rgb is.
    reg       ph = 1'b0;
    reg [1:0] ph_r;
    always @(posedge clk) begin
        ph   <= ~ph;
        ph_r <= {ph_r[0], ph};
    end
    assign rd_b = ph;

    // The last pixel read of each line, held. After the first two reads of a column both
    // are the new column's; col_new says when that is (cs[k] is col_new k + 1 clocks old).
    reg [23:0] reg_a = 24'd0, reg_b = 24'd0;
    reg [5:0]  cs = 6'd0;
    always @(posedge clk) begin
        if (ph_r[1]) reg_b <= rd_rgb;
        else         reg_a <= rd_rgb;
        cs <= {cs[4:0], col_new};
    end

    // The weights of a pixel travel along to the stage that uses them.
    reg  [62:0] sd = 63'd0;
    always @(posedge clk)
        sd <= {sd[53:0], hnext, on ? wx : 8'd0};
    wire [7:0] wx_d = sd[61:54];
    wire       hn_d = sd[62];

    wire [7:0] wy_g = on ? wy : 8'd0;
    wire signed [8:0] wy_s = {1'b0, wy_g};
    wire signed [8:0] wx_s = {1'b0, wx_d};

    genvar k;

    // vertical blend of the pair (reg_a, reg_b), registered when it is a new column's.
    //   V1: difference times weight   V2 (on col_new): the blend, held in n
    reg [23:0] da = 24'd0, n = 24'd0;
    generate for (k = 0; k < 3; k = k + 1) begin : vert
        reg signed [17:0] pv;
        wire signed [8:0] dv = $signed({1'b0, reg_b[8*k +: 8]}) - $signed({1'b0, reg_a[8*k +: 8]});
        wire signed [17:0] r8 = (pv + 18'sd128) >>> 8;
        always @(posedge clk) begin
            pv <= dv * wy_s;
            if (cs[2])
                n[8*k +: 8] <= da[8*k +: 8] + r8[7:0];
        end
    end endgenerate
    always @(posedge clk)
        da <= reg_a;

    // The columns, as the pixels see them: c = the pixel's column, p = the one before it,
    // n = the one after it (as soon as it has arrived: the next column starts at most 3
    // clocks after a pixel that blends with it). c and p move on with the column, 6
    // clocks after col_new, so that the pixel evaluated 7 clocks after its rd_rgb sees them.
    reg [23:0] c = 24'd0, p = 24'd0;
    always @(posedge clk)
        if (cs[5]) begin
            c <= n;
            p <= c;
        end

    //   H1: difference times weight   H2: the blend
    reg [23:0] cd = 24'd0;
    generate for (k = 0; k < 3; k = k + 1) begin : horz
        reg signed [17:0] ph1;
        wire [7:0] o = hn_d ? n[8*k +: 8] : p[8*k +: 8];
        wire signed [8:0] dh = $signed({1'b0, o}) - $signed({1'b0, c[8*k +: 8]});
        wire signed [17:0] h8 = (ph1 + 18'sd128) >>> 8;
        always @(posedge clk) begin
            ph1 <= dh * wx_s;
            cd[8*k +: 8] <= c[8*k +: 8];
            rgb_out[8*k +: 8] <= cd[8*k +: 8] + h8[7:0];
        end
    end endgenerate

endmodule


// The weights of one axis of the scaler's fractional counter (xcnt / ycnt), two clocks
// from the counter to the weight. The scaler's counter: an output pixel starts `pos`
// units into its source pixel (0 <= pos < size); a source pixel is `size` units wide and
// an output pixel `step` units. The counter advances by `step` per output pixel, and the
// source pixel by one when it reaches `size`: nearest neighbour shows the source pixel
// that holds the start of the output pixel.
//
//   sharp  the share of the output pixel that lies in the next source pixel,
//          max(0, pos + step - size) / step, `next` = 1
//   soft   the distance from the centre of the output pixel to the centre of the source
//          pixel, as a share of a source pixel: |pos + step / 2 - size / 2| / size,
//          `next` = the output pixel centre is past the source pixel centre
//
// as w / 256, rounded to nearest (half up), 0..255. The scaler gives the constants
// k_step = round(2^16 * 256 / step) and k_half = round(2^16 * 128 / size).
// `first` / `last`: this is the first / last source pixel (line): the weight of a
// neighbour that does not exist is 0.
module smooth_axis (
    input             clk,
    input       [1:0] mode,         // from smooth: 2 = soft, else sharp
    input      [10:0] pos,
    input      [10:0] step,
    input      [11:0] size,
    input      [16:0] k_step,
    input      [16:0] k_half,
    input             first,
    input             last,
    output reg  [7:0] w,
    output reg        next
);

    // stage 1: the distance in units of 1/size (soft: of 1/(2 size)), and which side
    wire [12:0]        a  = {2'b00, pos} + {2'b00, step};         // pos + step
    wire signed [13:0] sh = $signed({2'b00, pos, 1'b0}) + $signed({3'b000, step}) - $signed({2'b00, size});
    wire [11:0]        sa = sh[13] ? 12'd0 - sh[11:0] : sh[11:0];
    wire               is_soft = (mode == 2'd2);
    wire               nx_now = is_soft ? ~sh[13] : 1'b1;
    reg [11:0] num;
    reg [16:0] kk;
    reg        nx, kill;
    always @(posedge clk) begin
        num <= is_soft ? sa : (a > {1'b0, size}) ? a[11:0] - size : 12'd0;
        kk  <= is_soft ? k_half : k_step;
        nx  <= nx_now;
        kill <= (first & ~nx_now) | (last & nx_now);
    end

    // stage 2: the weight, num * k / 2^16 rounded
    wire [28:0] prod = num * kk + 29'd32768;
    wire [12:0] ws   = prod[28:16];
    always @(posedge clk) begin
        w    <= kill ? 8'd0 : (ws > 13'd255) ? 8'd255 : ws[7:0];
        next <= nx;
    end

endmodule
