// nes2hdmi with video_fx against the scaler before video_fx (the baseline, built from the git
// history by prep.sh as nes2hdmi_base): a video_config that enables nothing must give the very
// same rgb stream into the hdmi module, clock for clock, in every scanline mode, with the menu
// overlay up or not. The words tried: 0, what the firmware sends with every filter off (the
// strengths at 1), and one with the LCD grid bit set, which the NES ignores.
// The frame buffer holds a pseudo-random picture and the overlay is a pattern read through the
// overlay_x / overlay_y outputs with a two clock latency, so a picture or overlay that lands on
// other pixels is caught. Settings change in the blanking, then two whole frames are compared.
`timescale 1ns/1ps

module tb_nes_regress;

    reg clk_pixel = 0, clk = 0;
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz
    always #23.28 clk = ~clk;                   // 21.477 MHz

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
    reg [31:0] vcfg = 0;

    wire [7:0] ovx_n, ovy_n, ovx_b, ovy_b;
    reg [14:0] ovc_n, ovc_b, ovc_n1, ovc_b1;
    function [14:0] ov_pix(input [7:0] x, input [7:0] y);
        ov_pix = {x[4:0] ^ y[6:2], x[7:3] + y[4:0], y[7:3] ^ x[6:2]};
    endfunction
    always @(posedge clk_pixel) begin
        ovc_n1 <= ov_pix(ovx_n, ovy_n); ovc_n <= ovc_n1;
        ovc_b1 <= ov_pix(ovx_b, ovy_b); ovc_b <= ovc_b1;
    end

    wire [2:0] tmds_d_p, tmds_d_n, tmds_d_pb, tmds_d_nb;
    wire       tmds_clk_p, tmds_clk_n, tmds_clk_pb, tmds_clk_nb;

    nes2hdmi dut (
        .clk(clk), .resetn(1'b1),
        .color(6'd0), .cycle(9'd0), .scanline(9'd0), .sample(16'd0), .aspect_8x7(1'b0),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out),
        .video_config(vcfg),
        .overlay(ov), .overlay_x(ovx_n), .overlay_y(ovy_n), .overlay_color(ovc_n),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    nes2hdmi_base base (
        .clk(clk), .resetn(1'b1),
        .color(6'd0), .cycle(9'd0), .scanline(9'd0), .sample(16'd0), .aspect_8x7(1'b0),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out),
        .overlay(ov), .overlay_x(ovx_b), .overlay_y(ovy_b), .overlay_color(ovc_b),
        .clk_pixel(clk_pixel), .clk_5x_pixel(1'b0),
        .tmds_clk_n(tmds_clk_nb), .tmds_clk_p(tmds_clk_pb), .tmds_d_n(tmds_d_nb), .tmds_d_p(tmds_d_pb)
    );

    integer i;
    reg [31:0] h;
    initial begin
        #1;
        h = 32'h1234567;
        for (i = 0; i < 256 * 240; i = i + 1) begin
            h = h * 1664525 + 1013904223;
            dut.mem[i]  = h[29:24];
            base.mem[i] = h[29:24];
        end
    end

    // compare the rgb inputs of the two hdmi modules on every visible row
    reg     armed = 0;
    integer cmp = 0, bad = 0, picture = 0, total_cmp = 0, total_pic = 0;
    always @(negedge clk_pixel) begin
        if (armed && dut.cy < 10'd720) begin
            cmp = cmp + 1;
            if (dut.rgb !== 24'h303030) picture = picture + 1;
            if (dut.rgb !== base.rgb || dut.cx !== base.cx || dut.cy !== base.cy) begin
                bad = bad + 1;
                if (bad <= 8)
                    $display("MISMATCH cy=%0d cx=%0d: got %h, baseline %h", dut.cy, dut.cx, dut.rgb, base.rgb);
            end
        end
    end

    // the row where the settings change: blanking, no picture in flight
    task wait_row730;
        begin
            while (dut.cy == 10'd730) @(posedge clk_pixel);
            while (dut.cy != 10'd730) @(posedge clk_pixel);
        end
    endtask

    task variant(input on, input out, input thick, input [1:0] dk, input over, input [31:0] cfg);
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; ov = over; vcfg = cfg;
            cmp = 0; bad = 0; picture = 0;
            armed = 1;                          // rows 730.. of this frame are not compared
            wait_row730;                        // the first frame with these settings
            wait_row730;                        // the second
            if (bad != 0) begin
                $display("FAIL: on=%b out=%b thick=%b dark=%0d overlay=%b video_config=%h: %0d of %0d pixels differ",
                         on, out, thick, dk, over, cfg, bad, cmp);
                $fatal(1, "tb_nes_regress: FAIL");
            end
            if (cmp < 2 * 720 * 1650 - 10 || (!over && picture < 2 * 500 * 800)) begin
                $display("FAIL: only %0d pixels compared, %0d of them picture", cmp, picture);
                $fatal(1, "tb_nes_regress: FAIL");
            end
            total_cmp = total_cmp + cmp; total_pic = total_pic + picture;
            $display("nes2hdmi on=%b out=%b thick=%b darkness=%0d overlay=%b video_config=%h: %0d pixels identical (%0d picture)",
                     on, out, thick, dk, over, cfg, cmp, picture);
            armed = 0;
        end
    endtask

    localparam [31:0] OFF = 32'h0000_0000, FW_OFF = 32'h0001_2000, GRID = 32'h0003_A000;

    initial begin
        // the first frame runs the pipelines empty; the settings are applied in its blanking
        wait_row730;
        variant(0, 0, 0, 2, 0, OFF);
        variant(0, 0, 0, 2, 0, FW_OFF);
        variant(0, 0, 0, 2, 0, GRID);
        variant(1, 0, 0, 2, 0, OFF);            // integer scale, thin
        variant(1, 0, 0, 2, 0, FW_OFF);
        variant(1, 0, 1, 0, 0, FW_OFF);         // thick, 25 %
        variant(1, 0, 1, 3, 0, OFF);            // 100 %
        variant(1, 0, 0, 1, 0, GRID);
        variant(1, 1, 0, 2, 0, OFF);            // output rows
        variant(1, 1, 1, 1, 0, FW_OFF);
        variant(0, 0, 0, 2, 1, OFF);            // menu overlay up
        variant(0, 0, 0, 2, 1, FW_OFF);
        variant(1, 0, 0, 2, 1, FW_OFF);
        variant(1, 1, 1, 2, 1, OFF);
        variant(1, 0, 1, 2, 0, FW_OFF);         // and back
        $display("tb_nes_regress: %0d pixels identical to the baseline (%0d picture)", total_cmp, total_pic);
        $display("tb_nes_regress: PASS");
        $finish;
    end

    initial begin
        #4000000000000;
        $fatal(1, "tb_nes_regress: timeout");
    end
endmodule
