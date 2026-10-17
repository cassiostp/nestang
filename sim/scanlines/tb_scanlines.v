// Scanline logic (src/scanlines.v): the row generator for every picture
// geometry the cores use, in each mode, and the darkening of a pixel.
// Fails with $fatal on the first mismatch.
`timescale 1ns/1ps

module tb_scanlines;

    reg clk = 0;
    always #5 clk = ~clk;

    // hdmi-like row counter, ROWCLK clocks per output row
    localparam ROWCLK = 8;
    reg [9:0] cy = 10'd749;
    integer   sub = 0;
    always @(posedge clk) begin
        sub <= (sub == ROWCLK - 1) ? 0 : sub + 1;
        if (sub == ROWCLK - 1)
            cy <= (cy == 10'd749) ? 10'd0 : cy + 10'd1;
    end

    reg        cfg_on = 0, cfg_thick = 0, cfg_out = 0, cfg_grid = 0, hide = 0;
    reg  [1:0] cfg_dark = 0;
    reg  [2:0] rows = 3, dark_thin = 1, dark_thick = 2;
    reg  [7:0] lines = 224;
    reg  [9:0] top = 24;

    wire       geom, show, dark, last;
    wire [9:0] pic_top;
    wire [7:0] yy;
    wire [1:0] darkness;

    sl_rows dut (
        .clk(clk), .cy(cy),
        .cfg_on(cfg_on), .cfg_dark(cfg_dark), .cfg_thick(cfg_thick), .cfg_out(cfg_out), .cfg_grid(cfg_grid), .hide(hide),
        .rows(rows), .dark_thin(dark_thin), .dark_thick(dark_thick), .lines(lines), .top(top),
        .geom(geom), .pic_top(pic_top), .yy(yy), .show(show), .dark(dark), .last(last), .darkness(darkness)
    );

    integer errs = 0;
    task fail(input [8*80-1:0] what);
        begin
            $display("FAIL: %0s (rows=%0d lines=%0d on=%b out=%b thick=%b grid=%b hide=%b cy=%0d)",
                     what, rows, lines, cfg_on, cfg_out, cfg_thick, cfg_grid, hide, cy);
            $fatal(1, "tb_scanlines: FAIL");
        end
    endtask

    // wait for the start of the next frame, plus a few clocks for row 0 to settle
    task next_frame;
        begin
            @(posedge clk);
            while (cy != 10'd0) @(posedge clk);
            repeat (6) @(posedge clk);
        end
    endtask

    // expected behaviour of one output row, from the settings of the frame
    integer d, k, r_in, line_ex;
    reg exp_show, exp_dark, exp_last, exp_geom;
    task check_row(input on, input out, input thick, input hid, input grid);
        begin
            d = thick ? dark_thick : dark_thin;
            exp_show = 1; exp_dark = 0; exp_last = 0; line_ex = -1;
            exp_geom = (on && !out || grid) && !hid;            // the integer scale
            if (exp_geom) begin
                k = cy - top;
                if (k < 0 || k >= rows * lines) exp_show = 0;
                else begin
                    line_ex = k / rows;
                    r_in = k % rows;
                    exp_dark = on && !out && (r_in >= rows - d);    // the grid alone does not darken
                    exp_last = (r_in == rows - 1);
                end
            end
            if (on && !hid && out)                  // output rows (also with the grid's geometry)
                exp_dark = ((cy % rows) >= rows - d);
            if (show !== exp_show) begin
                $display("row %0d: show %b, want %b", cy, show, exp_show); fail("show");
            end
            if (dark !== exp_dark) begin
                $display("row %0d: dark %b, want %b", cy, dark, exp_dark); fail("dark");
            end
            if (exp_show && line_ex >= 0 && yy !== line_ex[7:0]) begin
                $display("row %0d: yy %0d, want %0d", cy, yy, line_ex); fail("source line");
            end
            if (last !== exp_last) begin
                $display("row %0d: last %b, want %b", cy, last, exp_last); fail("last");
            end
            if (geom !== exp_geom) fail("geom");
            if (pic_top !== (exp_geom ? top : 10'd0)) begin
                $display("pic_top %0d", pic_top); fail("pic_top");
            end
        end
    endtask

    // run a frame at the settings, after one frame to latch them
    task run(input on, input out, input thick, input hid, input grid);
        integer n;
        begin
            cfg_on = on; cfg_out = out; cfg_thick = thick; hide = hid; cfg_grid = grid;
            next_frame;                         // latched here
            // check rows 0..749 of the frame that started
            for (n = 0; n < 750; n = n + 1) begin
                while (sub != 6) @(posedge clk);
                check_row(on, out, thick, hid, grid);
                while (sub == 6) @(posedge clk);
            end
        end
    endtask

    // pixel darkening
    reg  [23:0] px_in;
    reg         px_dark = 0;
    reg   [1:0] px_dk = 0;
    wire [23:0] px_out;
    sl_dim dim (.clk(clk), .rgb_in(px_in), .dark(px_dark), .darkness(px_dk), .rgb_out(px_out));

    function [7:0] want8(input [7:0] c, input [1:0] dk);
        integer v;
        begin
            case (dk)
            0: v = c - c / 4;
            1: v = c / 2;
            2: v = c / 4;
            default: v = 0;
            endcase
            want8 = v;
        end
    endfunction

    integer c, dk, cfg;
    integer diff;
    reg [7:0] e;

    task check_dim(input [23:0] p, input dk_en, input [1:0] dkv);
        reg [23:0] want;
        integer ch;
        real ideal;
        begin
            px_in = p; px_dark = dk_en; px_dk = dkv;
            @(posedge clk); @(posedge clk); #1;
            want = dk_en ? {want8(p[23:16], dkv), want8(p[15:8], dkv), want8(p[7:0], dkv)} : p;
            if (px_out !== want) begin
                $display("pixel %h dark=%b darkness=%0d: got %h, want %h", p, dk_en, dkv, px_out, want);
                fail("sl_dim");
            end
            if (dk_en) begin                   // and it is the multiply by (1 - darkness), to 1 LSB
                for (ch = 0; ch < 3; ch = ch + 1) begin
                    ideal = p[ch*8 +: 8] * (3.0 - dkv) / 4.0;
                    if (px_out[ch*8 +: 8] > ideal + 1.0 || px_out[ch*8 +: 8] < ideal - 1.0) begin
                        $display("pixel %h darkness=%0d channel %0d: %0d, ideal %f", p, dkv, ch, px_out[ch*8 +: 8], ideal);
                        fail("sl_dim ideal");
                    end
                end
            end
        end
    endtask

    integer s, g;
    reg [2:0] g_rows [0:4];
    reg [2:0] g_dthin [0:4];
    reg [2:0] g_dthick [0:4];
    reg [7:0] g_lines [0:4];
    reg [9:0] g_top [0:4];

    initial begin
        // NES, SNES, MD (224 lines), MD (240 lines), SMS (192 lines), GBA, Game Gear
        g_rows[0] = 3; g_dthin[0] = 1; g_dthick[0] = 2; g_lines[0] = 224; g_top[0] = 24;
        g_rows[1] = 3; g_dthin[1] = 1; g_dthick[1] = 2; g_lines[1] = 240; g_top[1] = 0;
        g_rows[2] = 3; g_dthin[2] = 1; g_dthick[2] = 2; g_lines[2] = 192; g_top[2] = 72;
        g_rows[3] = 4; g_dthin[3] = 1; g_dthick[3] = 2; g_lines[3] = 160; g_top[3] = 40;
        g_rows[4] = 5; g_dthin[4] = 2; g_dthick[4] = 3; g_lines[4] = 144; g_top[4] = 0;

        // darkening: every channel value, every darkness, each channel alone and mixed
        for (dk = 0; dk < 4; dk = dk + 1)
            for (c = 0; c < 256; c = c + 1) begin
                check_dim({c[7:0], 8'h00, 8'h00}, 1, dk);
                check_dim({8'h00, c[7:0], 8'h00}, 1, dk);
                check_dim({8'h00, 8'h00, c[7:0]}, 1, dk);
                check_dim({c[7:0], ~c[7:0], c[7:0] ^ 8'hA5}, 1, dk);
                check_dim({c[7:0], ~c[7:0], c[7:0] ^ 8'hA5}, 0, dk);
            end
        // spot values of the spec
        check_dim(24'hFFFFFF, 1, 0);  if (px_out !== 24'hC0C0C0) fail("255 at 25 %");
        check_dim(24'hFFFFFF, 1, 1);  if (px_out !== 24'h7F7F7F) fail("255 at 50 %");
        check_dim(24'hFFFFFF, 1, 2);  if (px_out !== 24'h3F3F3F) fail("255 at 75 %");
        check_dim(24'hFFFFFF, 1, 3);  if (px_out !== 24'h000000) fail("255 at 100 %");

        // darkness bits reach the pixel stage
        for (dk = 0; dk < 4; dk = dk + 1) begin
            cfg_dark = dk; repeat (6) @(posedge clk);
            if (darkness !== dk[1:0]) fail("darkness sync");
        end

        // row generator, every geometry and mode
        for (g = 0; g < 5; g = g + 1) begin
            rows = g_rows[g]; dark_thin = g_dthin[g]; dark_thick = g_dthick[g];
            lines = g_lines[g]; top = g_top[g];
            for (cfg = 0; cfg < 24; cfg = cfg + 1) begin
                // cfg: bit0 thick, bit1 out, bit3:2 = 0 off, 1 on, 2 on but hidden; 12.. LCD grid on
                run((cfg % 12) / 4 == 1, cfg[1], cfg[0], (cfg % 12) / 4 == 2, cfg >= 12);
            end
            $display("geometry %0d rows x %0d lines (top %0d): ok", rows, lines, top);
        end

        // the settings change in the middle of a frame: the frame under way keeps its own
        rows = 3; dark_thin = 1; dark_thick = 2; lines = 224; top = 24;
        run(1, 0, 0, 0, 0);
        next_frame;
        while (cy != 10'd300) @(posedge clk);
        cfg_thick = 1; cfg_out = 1; cfg_grid = 1;   // mid-frame
        for (s = 0; s < 450; s = s + 1) begin   // rows 300..749: still thin, integer scale, no grid
            while (sub != 6) @(posedge clk);
            check_row(1, 0, 0, 0, 0);
            while (sub == 6) @(posedge clk);
        end
        next_frame;                             // the next frame takes them
        for (s = 0; s < 750; s = s + 1) begin
            while (sub != 6) @(posedge clk);
            check_row(1, 1, 1, 0, 1);
            while (sub == 6) @(posedge clk);
        end

        $display("tb_scanlines: PASS");
        $finish;
    end

    initial begin
        #200000000;
        $fatal(1, "tb_scanlines: timeout");
    end
endmodule
