// nes2hdmi with scanlines, whole frames: the HDMI part is a stub that counts
// cx/cy like the real one (hdmi_stub.v), the picture is the scaler's rgb output.
// Checks, for each setting, every output row of the frame against the model of
// src/scanlines.v: which source line it shows, border rows, dark rows and the
// darkened colour; and the horizontal extent of the picture.
// Fails with $fatal on the first mismatch.
`timescale 1ns/1ps

module tb_nes_scaler;

    reg clk_pixel = 0, clk = 0;
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
    always #23.28 clk = ~clk;                   // 21.477 MHz

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
    wire [7:0] overlay_x, overlay_y;
    reg [14:0] overlay_color = 15'b10101_01010_11100;   // BGR5
    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;

    nes2hdmi dut (
        .clk(clk), .resetn(1'b1),
        .color(6'd0), .cycle(9'd0), .scanline(9'd0), .sample(16'd0), .aspect_8x7(1'b0),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out),
        .overlay(ov), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(overlay_color),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // what the HDMI sink would show: rgb while cx = x + 1
    reg [23:0] img [0:1280*720-1];
    always @(posedge clk_pixel)
        if (dut.cy < 10'd720 && dut.cx >= 11'd1 && dut.cx <= 11'd1280)
            img[dut.cy * 1280 + dut.cx - 1] = dut.rgb;

    localparam BORDER = 24'h303030;

    // source picture: NES line l (0..239) is palette entry 32 + l % 12, or (mode 1)
    // column c is palette entry 32 + c % 12
    function [5:0] pal_idx(input integer n);
        pal_idx = 32 + (n % 12);
    endfunction

    task load_image(input integer by_column);
        integer l, c;
        begin
            for (l = 0; l < 240; l = l + 1)
                for (c = 0; c < 256; c = c + 1)
                    dut.mem[l * 256 + c] = by_column ? pal_idx(c) : pal_idx(l);
        end
    endtask

    function [7:0] dim8(input [7:0] v, input [1:0] d);
        case (d)
        0: dim8 = v - v / 4;
        1: dim8 = v / 2;
        2: dim8 = v / 4;
        default: dim8 = 0;
        endcase
    endfunction

    function [23:0] darken(input [23:0] p, input [1:0] d);
        darken = {dim8(p[23:16], d), dim8(p[15:8], d), dim8(p[7:0], d)};
    endfunction

    function [23:0] overlay_rgb(input [14:0] o);
        overlay_rgb = {o[4:0], 3'b0, o[9:5], 3'b0, o[14:10], 3'b0};
    endfunction

    // wait for two frame ends after a settings change: the second frame is drawn with
    // the new settings, and img holds it when this returns (in the blanking at row 726)
    task settle;
        begin
            repeat (2) begin
                while (dut.cy != 10'd725) @(posedge clk_pixel);
                while (dut.cy == 10'd725) @(posedge clk_pixel);
            end
        end
    endtask

    task fail(input [8*60-1:0] what, input integer row, input [23:0] got, input [23:0] want);
        begin
            $display("FAIL: %0s at row %0d: got %h, want %h (on=%b out=%b thick=%b dark=%0d ov=%b)",
                     what, row, got, want, sl_on, sl_out, sl_thick, sl_dark, ov);
            $fatal(1, "tb_nes_scaler: FAIL");
        end
    endtask

    // the model
    localparam R = 3, LINES = 224, TOP = 24, GEOM_W = 896, FULL_W = 960;
    integer row, line, rr, nd, XP, x, first, last, runs, runlen, minrun, maxrun, w;
    reg [23:0] want, got, prev;
    reg is_geom;

    task check_rows(input on, input out, input thick, input [1:0] dk, input over);
        begin
            is_geom = on & ~out & ~over;
            nd = thick ? 2 : 1;
            XP = 640;
            for (row = 0; row < 720; row = row + 1) begin
                got = img[row * 1280 + XP];
                if (over)
                    want = overlay_rgb(overlay_color);
                else if (is_geom) begin
                    if (row < TOP || row >= TOP + R * LINES)
                        want = BORDER;
                    else begin
                        line = (row - TOP) / R;
                        rr = (row - TOP) % R;
                        want = dut.NES_PALETTE[pal_idx(line + 8)];
                        if (rr >= R - nd) want = darken(want, dk);
                    end
                end else begin
                    line = row * LINES / 720;       // the fractional scaler
                    want = dut.NES_PALETTE[pal_idx(line + 8)];
                    if (on & out & ((row % R) >= R - nd)) want = darken(want, dk);
                end
                if (got !== want) fail("picture", row, got, want);
                // the left border is never touched
                if (img[row * 1280 + 100] !== BORDER) fail("left border", row, img[row * 1280 + 100], BORDER);
                if (img[row * 1280 + 1200] !== BORDER) fail("right border", row, img[row * 1280 + 1200], BORDER);
            end
        end
    endtask

    // horizontal extent and pixel widths on a row through the middle of the picture
    task check_columns(input geom);
        begin
            row = 360;
            first = -1; last = -1; runs = 0; minrun = 99; maxrun = 0; runlen = 0; prev = BORDER;
            for (x = 0; x < 1280; x = x + 1) begin
                got = img[row * 1280 + x];
                if (got !== BORDER) begin
                    if (first < 0) first = x;
                    last = x;
                    if (got !== prev) begin
                        if (runs > 0) begin
                            if (runlen < minrun) minrun = runlen;
                            if (runlen > maxrun) maxrun = runlen;
                        end
                        runs = runs + 1; runlen = 0;
                    end
                    runlen = runlen + 1;
                end
                prev = got;
            end
            w = last - first + 1;
            if (geom) begin
                if (first !== (1280 - GEOM_W) / 2 || w !== GEOM_W) begin
                    $display("FAIL: integer scale picture spans x=%0d..%0d (width %0d), want %0d..%0d", first, last, w, (1280 - GEOM_W) / 2, (1280 + GEOM_W) / 2 - 1);
                    $fatal(1, "tb_nes_scaler: FAIL");
                end
                if (minrun < 3 || maxrun > 4) begin
                    $display("FAIL: pixel widths %0d..%0d, want 3..4", minrun, maxrun);
                    $fatal(1, "tb_nes_scaler: FAIL");
                end
            end else begin
                if (first !== (1280 - FULL_W) / 2 || w !== FULL_W) begin
                    $display("FAIL: normal picture spans x=%0d..%0d (width %0d), want %0d..%0d", first, last, w, (1280 - FULL_W) / 2, (1280 + FULL_W) / 2 - 1);
                    $fatal(1, "tb_nes_scaler: FAIL");
                end
                if (minrun < 3 || maxrun > 4) begin
                    $display("FAIL: pixel widths %0d..%0d, want 3..4", minrun, maxrun);
                    $fatal(1, "tb_nes_scaler: FAIL");
                end
            end
            if (runs !== 256) begin
                $display("FAIL: %0d source columns on the row, want 256", runs);
                $fatal(1, "tb_nes_scaler: FAIL");
            end
        end
    endtask

    task run(input on, input out, input thick, input [1:0] dk, input over);
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; ov = over;
            settle;
            check_rows(on, out, thick, dk, over);
            $display("nes2hdmi on=%b out=%b thick=%b darkness=%0d overlay=%b: ok", on, out, thick, dk, over);
        end
    endtask

    initial begin
        #1;
        // by row: the vertical geometry and the darkening
        load_image(0);
        run(0, 0, 0, 2, 0);                     // off: the old geometry
        run(1, 0, 0, 2, 0);                     // the default: integer, thin, 75 %
        run(1, 0, 1, 0, 0);
        run(1, 0, 0, 1, 0);
        run(1, 0, 1, 3, 0);
        run(1, 1, 0, 2, 0);                     // output rows
        run(1, 1, 1, 1, 0);
        run(1, 0, 0, 2, 1);                     // menu up: the overlay is left alone
        run(1, 1, 1, 2, 1);
        run(1, 0, 1, 2, 0);                     // and back
        // by column: the horizontal geometry
        load_image(1);
        sl_on = 0; sl_out = 0; ov = 0; settle; check_columns(0);
        $display("nes2hdmi columns, scanlines off: ok");
        sl_on = 1; settle; check_columns(1);
        $display("nes2hdmi columns, integer scale: ok");
        sl_out = 1; settle; check_columns(0);
        $display("nes2hdmi columns, output rows: ok");
        $display("tb_nes_scaler: PASS");
        $finish;
    end

    initial begin
        #2000000000;
        $fatal(1, "tb_nes_scaler: timeout");
    end
endmodule
