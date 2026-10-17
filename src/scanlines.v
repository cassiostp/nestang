// Scanlines for the TangCore video scalers (the same file is in every core).
//
// core_config bits (the firmware sets them, they may change at any time):
//   [16]    scanlines on
//   [19:18] darkness of a scanline row: 0 = 25 %, 1 = 50 %, 2 = 75 %, 3 = 100 % (black)
//   [20]    thickness: 0 = thin, 1 = thick
//   [21]    mode: 0 = integer scale (default), 1 = output rows
//
// Integer scale (the default). Every source line is scaled by the same whole
// number of output rows, `rows`, so the lines are evenly spaced. The picture is
// centred vertically with a border above and below it. The last `dark_thin`
// (thin) or `dark_thick` (thick) rows of each source line are darkened.
//
// Output rows. The picture keeps the scaler's normal geometry. The 720p rows
// are counted from the top of the frame and the last `dark_*` rows of every
// `rows` output rows are darkened, whatever source line they show. The dark
// rows are evenly spaced, but they beat against content that isn't scaled by
// exactly `rows`.
//
// The LCD grid (video_fx.v) needs the integer scale too: with cfg_grid set
// the frame uses it even when the scanlines are off or in output rows mode,
// and `last` marks the last output row of every source line. The scanline
// darkening is not affected.
//
// sl_rows follows the output row (cy) and says, for the row being drawn,
// which source line it shows, whether it is inside the picture, whether it
// is a dark row and whether it is the last row of its source line. sl_dim
// darkens one pixel. The settings are latched at the start of every frame, so
// a frame never mixes two geometries, except `hide` (the menu is up), which
// the scaler also looks at directly.

module sl_rows (
    input            clk,           // pixel clock, 74.25 MHz
    input      [9:0] cy,            // output row, from the hdmi module

    // core_config bits, any clock domain
    input            cfg_on,        // [16]
    input      [1:0] cfg_dark,      // [19:18]
    input            cfg_thick,     // [20]
    input            cfg_out,       // [21]
    input            cfg_grid,      // video_config[15]: LCD grid on, wants the integer scale
    input            hide,          // 1: no scanlines, no grid geometry (the menu is up)

    // the picture, sampled at the start of every frame
    input      [2:0] rows,          // output rows per source line
    input      [2:0] dark_thin,     // dark rows per `rows`, thin
    input      [2:0] dark_thick,    // dark rows per `rows`, thick
    input      [7:0] lines,         // source lines in the picture
    input      [9:0] top,           // first output row of the picture, (720 - rows * lines) / 2

    output reg       geom,          // this frame uses the integer scale
    output     [9:0] pic_top,       // first output row of the picture (0 unless geom)
    output reg [7:0] yy,            // geom: source line shown by this output row
    output           show,          // 1: this output row shows the picture (always 1 unless geom)
    output           dark,          // 1: this output row is darkened
    output           last,          // geom: this output row is the last of its source line
    output reg [1:0] darkness       // synchronised cfg_dark
);

    // synchronise the config bits to the pixel clock
    reg [6:0] cfg_a, cfg_b;
    always @(posedge clk) begin
        cfg_a <= {cfg_grid, hide, cfg_out, cfg_thick, cfg_dark, cfg_on};
        cfg_b <= cfg_a;
        darkness <= cfg_b[2:1];
    end
    wire s_on    = cfg_b[0];
    wire s_thick = cfg_b[3];
    wire s_out   = cfg_b[4];
    wire s_hide  = cfg_b[5];
    wire s_grid  = cfg_b[6];

    reg       smode;                // this frame darkens the rows of the integer scale
    reg       omode;                // this frame darkens output rows
    reg       in_pic;               // geom: the output row is inside the picture
    reg [2:0] rows_l;               // `rows` of this frame
    reg [2:0] dstart;               // first dark row of `rows`
    reg [7:0] lines_l;
    reg [9:0] top_l;
    reg [2:0] rcnt;                 // geom: row within the source line
    reg [2:0] orow;                 // omode: row within the pitch, counted from the top of the frame
    reg       cy0_r;                // cy[0] one clock ago, a change is a new output row

    always @(posedge clk) begin
        cy0_r <= cy[0];
        if (cy == 10'd0) begin      // the first row: take the settings for this frame
            geom    <= (s_on & ~s_out | s_grid) & ~s_hide;
            smode   <= s_on & ~s_out & ~s_hide;
            omode   <= s_on &  s_out & ~s_hide;
            rows_l  <= rows;
            dstart  <= rows - (s_thick ? dark_thick : dark_thin);
            lines_l <= lines;
            top_l   <= top;
            in_pic  <= (top == 10'd0);
            yy      <= 8'd0;
            rcnt    <= 3'd0;
            orow    <= 3'd0;
        end else if (cy[0] != cy0_r) begin  // a new output row
            orow <= (orow == rows_l - 3'd1) ? 3'd0 : orow + 3'd1;
            if (cy == top_l) begin          // first row of the picture
                in_pic <= 1'b1;
                yy     <= 8'd0;
                rcnt   <= 3'd0;
            end else if (in_pic) begin
                if (rcnt == rows_l - 3'd1) begin
                    rcnt <= 3'd0;
                    if (yy == lines_l - 8'd1)
                        in_pic <= 1'b0;     // that was the last source line
                    else
                        yy <= yy + 8'd1;
                end else
                    rcnt <= rcnt + 3'd1;
            end
        end
    end

    assign pic_top = geom ? top_l : 10'd0;
    assign show    = ~geom | in_pic;
    assign dark    = (smode & in_pic & (rcnt >= dstart)) | (omode & (orow >= dstart));
    assign last    = geom & in_pic & (rcnt == rows_l - 3'd1);

endmodule


// Darken a pixel by 25, 50, 75 or 100 %: each channel is multiplied by
// (1 - darkness) with shifts and a subtract. One register stage.
module sl_dim (
    input             clk,
    input      [23:0] rgb_in,
    input             dark,         // darken this pixel
    input       [1:0] darkness,     // 0: 25 %, 1: 50 %, 2: 75 %, 3: 100 %
    output reg [23:0] rgb_out
);

    function [7:0] dim8(input [7:0] c, input [1:0] d);
        case (d)
        2'd0:    dim8 = c - (c >> 2);   // x 0.75
        2'd1:    dim8 = c >> 1;         // x 0.5
        2'd2:    dim8 = c >> 2;         // x 0.25
        default: dim8 = 8'd0;           // black
        endcase
    endfunction

    always @(posedge clk)
        rgb_out <= dark ? {dim8(rgb_in[23:16], darkness),
                           dim8(rgb_in[15:8],  darkness),
                           dim8(rgb_in[7:0],   darkness)} : rgb_in;

endmodule
