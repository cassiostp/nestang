// The whole hdmi packet path (packet_picker + packet_assembler in the real
// hdmi module at VIC 47) checked at the data-island output: every packet
// sent in mode 3 is reassembled from the module's data_island_data and its
// BCH parity recomputed bit by bit, the way a sink checks it. A picker or
// assembler misaligned by one cycle (packet_enable is registered from
// cx_next; the assembler snapshots its inputs at counter 0) corrupts the
// first bits of a packet and fails the parity. Also requires each packet
// type (ACR, audio sample, AVI/SPD/audio InfoFrames) to appear, which
// proves the audio sample buffer and the clock-regeneration wrap flow
// through packet_enable. Verilator (see run.sh): the serializer is empty
// under it, which is fine, nothing here looks at the TMDS pins.
`timescale 1ns/1ps

module tb_hdmi_packets;

    reg clk_pixel = 0;
    always #3.367 clk_pixel = ~clk_pixel;       // 148.5 MHz

    reg clk_audio = 0;
    integer audiv = 0;
    reg [15:0] sample_l = 16'h1000, sample_r = 16'h2000;
    always @(posedge clk_pixel) begin
        if (audiv == 1546) begin
            audiv <= 0;
            clk_audio <= ~clk_audio;
            if (!clk_audio) begin               // about to rise: new sample
                sample_l <= sample_l + 16'd111;
                sample_r <= sample_r + 16'd222;
            end
        end else
            audiv <= audiv + 1;
    end

    wire [10:0] cx;
    wire [9:0]  cy;
    wire [23:0] rgb = {cx[7:0], cy[7:0], 8'h5A};
    wire [2:0] tmds;
    wire tmds_clock;
    hdmi #(.VIDEO_ID_CODE(47), .VIDEO_REFRESH_RATE(120.0), .IT_CONTENT(1),
           .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16), .NATIVE_FRAME_WIDTH(1647))
    dut (.clk_pixel_x5(clk_pixel), .clk_pixel(clk_pixel), .clk_audio(clk_audio),
         .reset(1'b0), .std_timing(1'b0), .rgb(rgb),
         .audio_sample_word('{sample_r, sample_l}),
         .tmds(tmds), .tmds_clock(tmds_clock), .cx(cx), .cy(cy),
         .frame_width(), .frame_height(), .screen_width(), .screen_height());

    // HDMI BCH parity, Figure 5-5: the sink-side recomputation
    function [7:0] next_ecc(input [7:0] ecc, input b);
        next_ecc = (ecc >> 1) ^ ((ecc[0] ^ b) ? 8'b10000011 : 8'd0);
    endfunction
    function [7:0] ecc_of_sub(input [55:0] s);
        integer j;
        reg [7:0] e;
        begin
            e = 8'd0;
            for (j = 0; j < 56; j = j + 1) e = next_ecc(e, s[j]);
            ecc_of_sub = e;
        end
    endfunction
    function [7:0] ecc_of_header(input [23:0] s);
        integer j;
        reg [7:0] e;
        begin
            e = 8'd0;
            for (j = 0; j < 24; j = j + 1) e = next_ecc(e, s[j]);
            ecc_of_header = e;
        end
    endfunction

    // packet_data as registered into data_island_data (hdmi.sv):
    //   [11:4] = packet_data[8:1], [2] = packet_data[0]
    // packet_data = {s3[1],s2[1],s1[1],s0[1], s3[0],s2[0],s1[0],s0[0], hdr}
    reg [55:0] sub_got [3:0];
    reg [7:0]  par_got [3:0];
    reg [23:0] hdr_got;
    reg [7:0]  hpar_got;
    integer cyc = 0, cnt = 0, npkt = 0, bad = 0;
    integer n_acr = 0, n_aud = 0, n_avi = 0, n_spd = 0, n_aif = 0, n_null = 0, n_other = 0;
    integer frames = 0;
    reg in_island = 0;
    integer i;
    reg [7:0] ptype;

    always @(negedge clk_pixel) begin
        cyc = cyc + 1;
        if (dut.mode == 3'd3) begin
            if (!in_island) begin
                in_island = 1;
                cnt = 0;
            end
            // the two bits per subpacket and the header bit of this cycle
            for (i = 0; i < 4; i = i + 1) begin
                if (cnt < 28) begin
                    sub_got[i][2*cnt]   = dut.data_island_data[4 + i];  // packet_data[1+i]
                    sub_got[i][2*cnt+1] = dut.data_island_data[8 + i];  // packet_data[5+i]
                end else begin
                    par_got[i][2*(cnt-28)]   = dut.data_island_data[4 + i];
                    par_got[i][2*(cnt-28)+1] = dut.data_island_data[8 + i];
                end
            end
            if (cnt < 24) hdr_got[cnt] = dut.data_island_data[2];
            else          hpar_got[cnt-24] = dut.data_island_data[2];

            if (cnt == 31) begin
                npkt = npkt + 1;
                ptype = hdr_got[7:0];
                case (ptype)
                8'd0:   n_null = n_null + 1;
                8'd1:   n_acr  = n_acr + 1;
                8'd2:   n_aud  = n_aud + 1;
                8'd130: n_avi  = n_avi + 1;
                8'd131: n_spd  = n_spd + 1;
                8'd132: n_aif  = n_aif + 1;
                default: n_other = n_other + 1;
                endcase
                for (i = 0; i < 4; i = i + 1)
                    if (ecc_of_sub(sub_got[i]) !== par_got[i]) begin
                        bad = bad + 1;
                        if (bad < 6)
                            $display("ECC mismatch packet %0d type %0d sub %0d: got %h want %h (sub=%h)",
                                     npkt, ptype, i, par_got[i], ecc_of_sub(sub_got[i]), sub_got[i]);
                    end
                if (ecc_of_header(hdr_got) !== hpar_got) begin
                    bad = bad + 1;
                    if (bad < 6)
                        $display("header ECC mismatch packet %0d type %0d: got %h want %h (header=%h)",
                                 npkt, ptype, hpar_got, ecc_of_header(hdr_got), hdr_got);
                end
                cnt = 0;
            end else
                cnt = cnt + 1;
        end else begin
            if (in_island && cnt != 0) begin
                bad = bad + 1;
                $display("island ended mid-packet at count %0d (cycle %0d)", cnt, cyc);
            end
            in_island = 0;
            cnt = 0;
        end
    end

    reg [9:0] cy_q = 0;
    always @(posedge clk_pixel) begin
        cy_q <= cy;
        if (cy == 10'd0 && cy_q != 10'd0) frames = frames + 1;
    end

    initial begin
        while (!(frames >= 1 && npkt >= 200 && n_acr >= 1 && n_aud >= 1 &&
                 n_avi >= 1 && n_spd >= 1 && n_aif >= 1)) begin
            @(posedge clk_pixel);
            if (cyc > 8000000) begin
                $display("tb_hdmi_packets: FAIL (timeout: frames=%0d packets=%0d acr=%0d aud=%0d avi=%0d spd=%0d aif=%0d)",
                         frames, npkt, n_acr, n_aud, n_avi, n_spd, n_aif);
                $fatal(1, "tb_hdmi_packets: FAIL");
            end
        end
        $display("tb_hdmi_packets: %0d cycles, %0d frames, %0d packets (null %0d, ACR %0d, audio %0d, AVI %0d, SPD %0d, AIF %0d, other %0d), %0d ECC/island errors",
                 cyc, frames, npkt, n_null, n_acr, n_aud, n_avi, n_spd, n_aif, n_other, bad);
        if (bad != 0 || n_other != 0) begin
            $display("tb_hdmi_packets: FAIL");
            $fatal(1, "tb_hdmi_packets: FAIL");
        end
        $display("tb_hdmi_packets: PASS");
        $finish;
    end
endmodule
