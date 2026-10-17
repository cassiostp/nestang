// video_fx (src/video_fx.v) against the golden model (model.py gen -> vec_*.hex):
// every brightness / contrast / saturation / gamma, every CRT mask type and strength
// with and without the LCD grid at its four strengths, and random settings with random
// pictures, borders, scanline darkening and grid flags.
//
// One case is one setting: it is latched (cy = 0), then rows are fed the way a scaler
// does, one pixel a clock, so that the pixel of output column x is seen at rgb_out while
// cx = x. The rows start FX_LAT clocks before cx = 0. Fails with $fatal on a mismatch.
`timescale 1ns/1ps

module tb_video_fx;

    localparam FX_LAT = 11;

    reg clk = 0;
    always #6.734 clk = ~clk;                   // 74.25 MHz

    reg  [10:0] cx = 0;
    reg  [9:0]  cy = 10'd5;
    reg  [31:0] video_config = 0;
    reg  [23:0] rgb_in = 24'h303030;
    reg         pic_in = 0, dark_in = 0, col_last_in = 0, row_last_in = 0;
    reg  [1:0]  darkness = 0;
    wire [23:0] rgb_out;

    video_fx dut (
        .clk(clk), .cx(cx), .cy(cy), .video_config(video_config),
        .rgb_in(rgb_in), .pic_in(pic_in), .dark_in(dark_in), .darkness(darkness),
        .col_last_in(col_last_in), .row_last_in(row_last_in),
        .rgb_out(rgb_out)
    );

    reg [31:0] ctab [0:3*4000];
    reg [31:0] vin  [0:2000000];
    reg [23:0] vexp [0:2000000];

    integer ncase, c, r, t, x, base, nx, nr, errs, checked;
    reg [31:0] cfg, w;

    initial begin
        $readmemh("vec_case.hex", ctab);
        $readmemh("vec_in.hex", vin);
        $readmemh("vec_exp.hex", vexp);
        ncase = ctab[0];
        base = 0;
        errs = 0;
        checked = 0;
        @(negedge clk);
        for (c = 0; c < ncase; c = c + 1) begin
            cfg = ctab[1 + 3*c]; nx = ctab[2 + 3*c]; nr = ctab[3 + 3*c];
            video_config = cfg;
            cy = 10'd5;
            repeat (6) @(negedge clk);
            cy = 10'd0;                         // the frame start latches the setting
            repeat (3) @(negedge clk);
            for (r = 0; r < nr; r = r + 1) begin
                cy = r + 1;
                for (t = -FX_LAT; t < nx; t = t + 1) begin
                    cx = (t < 0) ? 1650 + t : t;
                    x = t + FX_LAT;
                    if (x < nx) begin           // the pixel that comes out at cx = x + FX_LAT
                        w = vin[base + r * nx + x];
                        rgb_in = w[23:0]; pic_in = w[24]; dark_in = w[25];
                        col_last_in = w[26]; row_last_in = w[27]; darkness = w[29:28];
                    end else begin
                        rgb_in = 24'h303030; pic_in = 0; dark_in = 0; col_last_in = 0; row_last_in = 0;
                    end
                    if (t >= 0) begin           // the output seen now is column t
                        if (rgb_out !== vexp[base + r * nx + t]) begin
                            errs = errs + 1;
                            if (errs <= 10)
                                $display("MISMATCH case %0d cfg=%h row %0d x=%0d: in=%h flags=%b got %h want %h",
                                         c, cfg, r + 1, t, vin[base + r * nx + t][23:0],
                                         vin[base + r * nx + t][29:24], rgb_out, vexp[base + r * nx + t]);
                        end
                        checked = checked + 1;
                    end
                    @(negedge clk);
                end
            end
            base = base + nx * nr;
        end
        $display("tb_video_fx: %0d cases, %0d pixels checked, %0d mismatches", ncase, checked, errs);
        if (errs != 0 || checked == 0)
            $fatal(1, "tb_video_fx: FAIL");
        $display("tb_video_fx: PASS");
        $finish;
    end

    initial begin
        #200000000000;
        $fatal(1, "tb_video_fx: timeout");
    end
endmodule
