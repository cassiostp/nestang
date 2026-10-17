// nes2hdmi with scanlines, whole frames: the HDMI part is a stub that counts
// cx/cy like the real one (hdmi_stub.v), the picture is the scaler's rgb output.
// Checks, for each setting, every output row of the frame against the model of
// src/scanlines.v: which source line it shows, border rows, dark rows and the
// darkened colour; and the horizontal extent of the picture.
// With HZ120 the DUT runs the 480p120 geometry (640x448 integer / 640x480
// full, 2 rows per line); otherwise the 720p geometry. Fails with $fatal on
// the first mismatch.
//
// HZ120 also dumps sim frames (frames/hz120_*.ppm: Integer/Full, with and
// without scanlines, and an OSD band held up through a black inserted frame
// to show the overlay exemption) and checks the overlay stays lit in BFI
// modes 1-3.
`timescale 1ns/1ps

`include "variant.vh"

module tb_nes_scaler;

    reg clk_pixel = 0, clk = 0;
`ifdef HZ120
    always #9.259 clk_pixel = ~clk_pixel;       // 54 MHz
`else
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
`endif
    always #23.28 clk = ~clk;                   // 21.477 MHz

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
    reg  [1:0] bfi_mode_tb = 2'd0;              // HZ120 only: BFI off unless a BFI run sets it
    wire [7:0] overlay_x, overlay_y;
    reg [14:0] overlay_color = 15'b10101_01010_11100;   // BGR5
    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;

    nes2hdmi dut (
        .clk(clk), .resetn(1'b1),
        .color(6'd0), .cycle(9'd0), .scanline(9'd0), .sample(16'd0), .aspect_8x7(1'b0),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out), .video_config(32'd0),
        .std_timing(1'b0),      // native NES rate, as in hardware
`ifdef HZ120
        .bfi_mode(bfi_mode_tb), // BFI off for the geometry runs
`endif
        .overlay(ov), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(overlay_color),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

`ifdef HZ120
    localparam ROWS = 480, COLS = 720, SETTLE_CY = 521;
`else
    localparam ROWS = 720, COLS = 1280, SETTLE_CY = 725;
`endif
    // what the HDMI sink would show: rgb while cx = x + 1
    reg [23:0] img [0:COLS*ROWS-1];
    always @(posedge clk_pixel)
        if (dut.cy < ROWS && dut.cx >= 11'd1 && dut.cx <= COLS)
            img[dut.cy * COLS + dut.cx - 1] = dut.rgb;

    localparam BORDER = 24'h303030;

    // source picture: NES line l (0..239) is palette entry 32 + l % 12, or (mode 1)
    // column c is palette entry 32 + c % 12
    function [5:0] pal_idx(input integer n);
        pal_idx = 32 + (n % 12);
    endfunction

    task load_image(input by_column);
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
    // the new settings, and img holds it when this returns (in the blanking past SETTLE_CY)
    task settle;
        begin
            repeat (2) begin
                while (dut.cy != SETTLE_CY) @(posedge clk_pixel);
                while (dut.cy == SETTLE_CY) @(posedge clk_pixel);
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
`ifdef HZ120
    localparam R = 2, LINES = 224, TOP = 16, GEOM_W = 640, FULL_W = 640;
    localparam MID_ROW = 240, XP = 360, LB_X = 20, RB_X = 700;
`else
    localparam R = 3, LINES = 224, TOP = 24, GEOM_W = 896, FULL_W = 960;
    localparam MID_ROW = 360, XP = 640, LB_X = 100, RB_X = 1200;
`endif
    integer row, line, rr, nd, x, first, last, runs, runlen, minrun, maxrun, w;
    reg [23:0] want, got, prev;
    reg is_geom;

    task check_rows(input on, input out, input thick, input [1:0] dk, input over);
        begin
            is_geom = ~out & ~over;
`ifdef HZ120
            nd = 1;     // at 2 rows per line thin and thick darken 1 row alike
`else
            nd = thick ? 2 : 1;
`endif
            for (row = 0; row < ROWS; row = row + 1) begin
                got = img[row * COLS + XP];
                if (over)
                    want = overlay_rgb(overlay_color);
                else if (is_geom) begin
                    if (row < TOP || row >= TOP + R * LINES)
                        want = BORDER;
                    else begin
                        line = (row - TOP) / R;
                        rr = (row - TOP) % R;
                        want = dut.NES_PALETTE[pal_idx(line + 8)];
                        if (on && rr >= R - nd) want = darken(want, dk);
                    end
                end else begin
                    line = row * LINES / ROWS;       // the fractional scaler
                    want = dut.NES_PALETTE[pal_idx(line + 8)];
                    if (on & out & ((row % R) >= R - nd)) want = darken(want, dk);
                end
                if (got !== want) fail("picture", row, got, want);
                // the left border is never touched
                if (img[row * COLS + LB_X] !== BORDER) fail("left border", row, img[row * COLS + LB_X], BORDER);
                if (img[row * COLS + RB_X] !== BORDER) fail("right border", row, img[row * COLS + RB_X], BORDER);
            end
        end
    endtask

    // horizontal extent and pixel widths on a row through the middle of the picture
    task check_columns(input geom);
        begin
            row = MID_ROW;
            first = -1; last = -1; runs = 0; minrun = 99; maxrun = 0; runlen = 0; prev = BORDER;
            for (x = 0; x < COLS; x = x + 1) begin
                got = img[row * COLS + x];
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
                if (first !== (COLS - GEOM_W) / 2 || w !== GEOM_W) begin
                    $display("FAIL: integer scale picture spans x=%0d..%0d (width %0d), want %0d..%0d", first, last, w, (COLS - GEOM_W) / 2, (COLS + GEOM_W) / 2 - 1);
                    $fatal(1, "tb_nes_scaler: FAIL");
                end
`ifdef HZ120
                if (minrun < 2 || maxrun > 3) begin
                    $display("FAIL: pixel widths %0d..%0d, want 2..3", minrun, maxrun);
                    $fatal(1, "tb_nes_scaler: FAIL");
                end
`else
                if (minrun < 3 || maxrun > 4) begin
                    $display("FAIL: pixel widths %0d..%0d, want 3..4", minrun, maxrun);
                    $fatal(1, "tb_nes_scaler: FAIL");
                end
`endif
            end else begin
                if (first !== (COLS - FULL_W) / 2 || w !== FULL_W) begin
                    $display("FAIL: normal picture spans x=%0d..%0d (width %0d), want %0d..%0d", first, last, w, (COLS - FULL_W) / 2, (COLS + FULL_W) / 2 - 1);
                    $fatal(1, "tb_nes_scaler: FAIL");
                end
`ifdef HZ120
                if (minrun < 2 || maxrun > 3) begin
                    $display("FAIL: pixel widths %0d..%0d, want 2..3", minrun, maxrun);
                    $fatal(1, "tb_nes_scaler: FAIL");
                end
`else
                if (minrun < 3 || maxrun > 4) begin
                    $display("FAIL: pixel widths %0d..%0d, want 3..4", minrun, maxrun);
                    $fatal(1, "tb_nes_scaler: FAIL");
                end
`endif
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

`ifdef HZ120
    // the menu overlay stays lit in every BFI mode: the whole frame must be
    // the overlay colour, lit or inserted refresh alike
    task run_bfi_over(input [1:0] mode);
        integer r;
        begin
            bfi_mode_tb = mode; ov = 1; sl_on = 1; sl_out = 0; settle;
            for (r = 0; r < ROWS; r = r + 1) begin
                got = img[r * COLS + XP];
                want = overlay_rgb(overlay_color);
                if (got !== want) fail("bfi overlay", r, got, want);
            end
            $display("nes2hdmi hz120 bfi mode %0d, overlay: ok", mode);
            ov = 0; bfi_mode_tb = 2'd0;
        end
    endtask

    task dump_frame(input [8*64-1:0] name);
        integer f, x, y;
        begin
            f = $fopen(name, "wb");
            $fwrite(f, "P6\n%0d %0d\n255\n", COLS, ROWS);
            for (y = 0; y < ROWS; y = y + 1)
                for (x = 0; x < COLS; x = x + 1)
                    $fwrite(f, "%c%c%c", img[y * COLS + x][23:16], img[y * COLS + x][15:8], img[y * COLS + x][7:0]);
            $fclose(f);
            $display("dumped %0s", name);
        end
    endtask

    // hold the OSD up over rows 100..300 of one black inserted frame and dump
    // it: the lit band over the blackened game picture shows the overlay
    // exemption. Rows 110..290 must be the overlay colour, the rest black.
    task osd_band_dump(input on, input out, input thick, input [1:0] dk, input [8*64-1:0] name);
        integer r;
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; ov = 0; bfi_mode_tb = 2'd1;
            settle;
            begin : find_ins
                forever begin
                    while (dut.cy != 10'd0) @(posedge clk_pixel);
                    if (dut.bfi_ins === 1'b1) disable find_ins;
                end
            end
            while (dut.cy != 10'd100) @(posedge clk_pixel);
            ov = 1;
            while (dut.cy != 10'd300) @(posedge clk_pixel);
            ov = 0;
            while (dut.cy != SETTLE_CY) @(posedge clk_pixel);
            while (dut.cy == SETTLE_CY) @(posedge clk_pixel);
            for (r = 0; r < ROWS; r = r + 1) begin
                got = img[r * COLS + XP];
                if (r >= 110 && r <= 290) want = overlay_rgb(overlay_color);
                else want = 24'h000000;
                if (got !== want) fail("osd band", r, got, want);
            end
            dump_frame(name);
            $display("nes2hdmi hz120 osd band on=%b out=%b: ok", on, out);
            bfi_mode_tb = 2'd0;
        end
    endtask
`endif

    initial begin
        #1;
        // by row: the vertical geometry and the darkening
        load_image(0);
        run(0, 0, 0, 2, 0);                     // off, integer scale: no darkening
`ifdef HZ120
        dump_frame("frames/hz120_int_off.ppm");
`endif
        run(0, 0, 1, 0, 0);                     // off, integer scale, thick: still none
        run(0, 1, 0, 2, 0);                     // off, full scale
`ifdef HZ120
        dump_frame("frames/hz120_full_off.ppm");
`endif
        run(1, 0, 0, 2, 0);                     // the default: integer, thin, 75 %
`ifdef HZ120
        dump_frame("frames/hz120_int_on.ppm");
`endif
        run(1, 0, 1, 0, 0);
        run(1, 0, 0, 1, 0);
        run(1, 0, 1, 3, 0);
        run(1, 1, 0, 2, 0);                     // output rows
`ifdef HZ120
        dump_frame("frames/hz120_full_on.ppm");
`endif
        run(1, 1, 1, 1, 0);
        run(1, 0, 0, 2, 1);                     // menu up: the overlay is left alone
        run(1, 1, 1, 2, 1);
        run(1, 0, 1, 2, 0);                     // and back
`ifdef HZ120
        // BFI overlay exemption in every darkening mode
        run_bfi_over(2'd1);
        run_bfi_over(2'd2);
        run_bfi_over(2'd3);
        // an OSD band over a black inserted frame, both scales
        osd_band_dump(1, 0, 0, 2, "frames/hz120_int_osd.ppm");
        osd_band_dump(1, 1, 0, 2, "frames/hz120_full_osd.ppm");
`endif
        // by column: the horizontal geometry
        load_image(1);
        sl_on = 0; sl_out = 0; ov = 0; settle; check_columns(1);
        $display("nes2hdmi columns, scanlines off, integer scale: ok");
        sl_on = 1; settle; check_columns(1);
        $display("nes2hdmi columns, integer scale: ok");
        sl_out = 1; settle; check_columns(0);
        $display("nes2hdmi columns, output rows: ok");
        sl_on = 0; settle; check_columns(0);
        $display("nes2hdmi columns, scanlines off, full scale: ok");
        $display("tb_nes_scaler: PASS");
        $finish;
    end

    initial begin
        #2000000000;
        $fatal(1, "tb_nes_scaler: timeout");
    end
endmodule
