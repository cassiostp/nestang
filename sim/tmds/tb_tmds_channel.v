// tmds_channel in two register stages against the direct implementation (the module as it was
// before the split, built from git history by run.sh as tmds_channel_old). Both channels of
// each of the three TMDS channels get the same inputs on every clock, and the new code words
// must be the old ones one clock later.
// The inputs follow the hdmi module's sequences: control periods (sync pulses, video and data
// island preambles), video guard band, a video period of pseudo-random pixels (up to a whole
// 1280 pixel line, so the running disparity wanders), data island guard bands and data islands of
// 32 pixel packets with pseudo-random data. Over 2.5 million clocks, two 720p frames' worth,
// with the lengths of the periods drawn at random.
`timescale 1ns/1ps

module tb_tmds_channel;

    reg clk_pixel = 0;
    always #6.734 clk_pixel = ~clk_pixel;       // 74.25 MHz

    reg  [2:0]  mode = 3'd1;
    reg  [23:0] video_data = 24'd0;
    reg  [5:0]  control_data = 6'd0;
    reg  [11:0] data_island_data = 12'd0;

    wire [9:0] new0, new1, new2, old0, old1, old2;
    tmds_channel     #(.CN(0)) n0 (.clk_pixel(clk_pixel), .video_data(video_data[7:0]),   .data_island_data(data_island_data[3:0]),
                                    .control_data(control_data[1:0]), .mode(mode), .tmds(new0));
    tmds_channel     #(.CN(1)) n1 (.clk_pixel(clk_pixel), .video_data(video_data[15:8]),  .data_island_data(data_island_data[7:4]),
                                    .control_data(control_data[3:2]), .mode(mode), .tmds(new1));
    tmds_channel     #(.CN(2)) n2 (.clk_pixel(clk_pixel), .video_data(video_data[23:16]), .data_island_data(data_island_data[11:8]),
                                    .control_data(control_data[5:4]), .mode(mode), .tmds(new2));
    tmds_channel_old #(.CN(0)) o0 (.clk_pixel(clk_pixel), .video_data(video_data[7:0]),   .data_island_data(data_island_data[3:0]),
                                    .control_data(control_data[1:0]), .mode(mode), .tmds(old0));
    tmds_channel_old #(.CN(1)) o1 (.clk_pixel(clk_pixel), .video_data(video_data[15:8]),  .data_island_data(data_island_data[7:4]),
                                    .control_data(control_data[3:2]), .mode(mode), .tmds(old1));
    tmds_channel_old #(.CN(2)) o2 (.clk_pixel(clk_pixel), .video_data(video_data[23:16]), .data_island_data(data_island_data[11:8]),
                                    .control_data(control_data[5:4]), .mode(mode), .tmds(old2));

    // the periods: 0 control, 1 video, 2 video guard, 3 island, 4 island guard; mode 5 is the
    // control period with the video preamble in front of the guard band
    reg [9:0] od0, od1, od2;
    integer clocks = 0, bad = 0, cnt[0:4], k, run, seg, pk;
    integer nmode0 = 0, nmode1 = 0, nmode2 = 0, nmode3 = 0, nmode4 = 0, nacc_neg = 0, nacc_pos = 0;
    reg [31:0] h = 32'h2468ACE;
    function [31:0] rnd(input integer dummy);
        begin
            h = h * 32'd1664525 + 32'd1013904223;
            rnd = h ^ (h >> 13);
        end
    endfunction

    // drive one clock (inputs change just after the edge)
    task tick(input [2:0] m, input [5:0] ctl);
        begin
            @(posedge clk_pixel);
            #1;
            mode = m;
            control_data = ctl;
            video_data = rnd(0);
            data_island_data = rnd(0);
        end
    endtask

    // compare on every edge: the new outputs against the old ones one edge earlier
    always @(posedge clk_pixel) begin
        clocks <= clocks + 1;
        if (clocks > 4) begin
            if (new0 !== od0 || new1 !== od1 || new2 !== od2) begin
                bad <= bad + 1;
                if (bad < 8)
                    $display("MISMATCH at clock %0d mode=%0d: new %h %h %h, old one clock earlier %h %h %h", clocks, mode,
                             new0, new1, new2, od0, od1, od2);
            end
        end
        case (mode)
        3'd0: nmode0 <= nmode0 + 1;
        3'd1: nmode1 <= nmode1 + 1;
        3'd2: nmode2 <= nmode2 + 1;
        3'd3: nmode3 <= nmode3 + 1;
        3'd4: nmode4 <= nmode4 + 1;
        endcase
        if (o1.acc < 0) nacc_neg <= nacc_neg + 1;
        if (o1.acc > 0) nacc_pos <= nacc_pos + 1;
        od0 <= old0; od1 <= old1; od2 <= old2;
    end

    reg [1:0] sync;
    initial begin
        // 2.5 million clocks of lines: control period, then either a video period or a data island
        while (clocks < 2500000) begin
            sync = rnd(0);
            seg = rnd(0) % 4;
            // control period: 8 preamble clocks (video: ctl3..0 = 0001, data island: 0101) and the rest
            run = 4 + rnd(0) % 60;
            repeat (run) tick(3'd0, {4'b0000, sync});
            if (seg == 0) begin                 // data island: preamble, guard, packets, guard
                repeat (8) tick(3'd0, {4'b0101, sync});
                repeat (2) tick(3'd4, {4'b0101, sync});
                pk = 1 + rnd(0) % 4;
                repeat (32 * pk) tick(3'd3, {4'b0000, sync});
                repeat (2) tick(3'd4, {4'b0000, sync});
            end else begin                      // video: preamble, guard, pixels
                repeat (8) tick(3'd0, {4'b0001, sync});
                repeat (2) tick(3'd2, {4'b0000, sync});
                run = (seg == 1) ? 1280 : 1 + rnd(0) % 1280;
                repeat (run) tick(3'd1, {4'b0000, sync});
            end
        end
        repeat (4) tick(3'd0, 6'd0);
        $display("tb_tmds_channel: %0d clocks, %0d mismatches (control %0d, video %0d, video guard %0d, island %0d, island guard %0d; running disparity > 0 %0d, < 0 %0d clocks)",
                 clocks, bad, nmode0, nmode1, nmode2, nmode3, nmode4, nacc_pos, nacc_neg);
        if (bad != 0 || nmode0 == 0 || nmode1 == 0 || nmode2 == 0 || nmode3 == 0 || nmode4 == 0 || nacc_pos == 0 || nacc_neg == 0) begin
            $display("tb_tmds_channel: FAIL");
            $fatal(1, "tb_tmds_channel: FAIL");
        end
        $display("tb_tmds_channel: PASS");
        $finish;
    end
endmodule
