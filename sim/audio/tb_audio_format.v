// Sample-format test for the NES -> HDMI audio path (tangcore#21).
//
// Proves from the real mixer RTL (extract.pl) what `sample` is at the top:
//   APU only : sample_inverted = 16'hFFFF - sample_apu (nes.v), silence FFFF
//   mapper 19: namco163_mixed output, silence 7FFF (audio_in halved in mix)
//   mapper 69: SS5b_mixed output, silence 8000
// HDMI (hdmi2, IEC 60958 L-PCM) takes signed samples with silence 0, which
// is also what the pause mux at nestang_top feeds it. The fixed chain is:
//   nes.v     APU path halved to {1'b0, sample_inverted[15:1]} so every
//             path is unsigned offset-binary with silence ~7FFF/8000, then
//   nestang_top {~sample[15], sample[14:0]} converts to signed, full range.
// This bench checks the old chain has the reported DC offset and the new
// chain maps silence to 0/-1 with no wrap. run.sh grep-gates that the two
// expressions above are the ones in the sources.

module SS5b_audio (          // stub: the bench drives exp_val directly
    input clk, input ce, input enable, input wren,
    input [15:0] addr_in, input [7:0] data_in, output [15:0] audio_out);
    assign audio_out = tb_audio_format.exp_val;
endmodule

module namco163_sound (clk20, m2, reset, wr, ain, din, dout, out);
    input clk20, m2, reset, wr;         // stub: bench drives n163_val
    input [15:0] ain; input [7:0] din;
    output [7:0] dout; output [10:0] out;
    assign dout = 8'b0;
    assign out = tb_audio_format.n163_val;
endmodule

module tb_audio_format;
    reg [3:0] sq1, sq2, trg, noi;
    reg [6:0] dmc;
    wire [15:0] apu;
    APUMixer mixer (.square1(sq1), .square2(sq2), .triangle(trg),
                    .noise(noi), .dmc(dmc), .sample(apu));

    reg clk = 0, ce = 0;
    reg [15:0] exp_val = 0;
    reg ss_en = 1;
    reg [15:0] ss_in = 0;
    wire [15:0] ss_out;
    SS5b_mixed ss5b (.clk(clk), .ce(ce), .enable(ss_en), .wren(1'b0),
                     .addr_in(16'b0), .data_in(8'b0), .audio_in(ss_in),
                     .audio_out(ss_out));

    reg [10:0] n163_val = 0;
    reg n163_en = 0;
    reg [15:0] n163_in = 0;
    wire [7:0] n163_dout;
    wire [15:0] n163_out;
    namco163_mixed n163 (.clk(clk), .ce(ce), .submapper(4'd0), .enable(n163_en),
                         .wren(1'b0), .addr_in(16'b0), .data_in(8'b0),
                         .data_out(n163_dout), .audio_in(n163_in),
                         .audio_out(n163_out));

    integer i, j, k, errors = 0;
    integer ch1_max, ch2_max, ch2_min, apu_idle, apu_max;
    integer mn, mx, prev, cur;

    function integer s16(input [15:0] v);
        s16 = v[15] ? v - 65536 : v;
    endfunction
    function [15:0] old_hdmi(input [15:0] v);   // nestang_top before the fix
        old_hdmi = v >> 1;
    endfunction
    function [15:0] new_apu(input [15:0] inv);  // nes.v halve + top MSB flip
        reg [15:0] norm;
        begin
            norm = {1'b0, inv[15:1]};
            new_apu = {~norm[15], norm[14:0]};
        end
    endfunction
    function [15:0] new_ext(input [15:0] v);    // top MSB flip only
        new_ext = {~v[15], v[14:0]};
    endfunction

    task check(input cond, input [8*64-1:0] what);
        if (cond !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL: %0s", what);
        end
    endtask

    initial begin
        // ---- APUMixer range: sample = ch1(squares) + ch2(tri/noise/dmc),
        // so sweep the two independent halves exhaustively.
        sq1 = 0; sq2 = 0; trg = 0; noi = 0; dmc = 0; #1;
        apu_idle = apu;
        ch1_max = 0;
        for (i = 0; i < 16; i = i + 1)
            for (j = 0; j < 16; j = j + 1) begin
                sq1 = i[3:0]; sq2 = j[3:0]; #1;
                if (apu > ch1_max) ch1_max = apu;
            end
        sq1 = 0; sq2 = 0; ch2_max = 0; ch2_min = 65535;
        for (i = 0; i < 16; i = i + 1)
            for (j = 0; j < 16; j = j + 1)
                for (k = 0; k < 128; k = k + 1) begin
                    trg = i[3:0]; noi = j[3:0]; dmc = k[6:0]; #1;
                    if (apu > ch2_max) ch2_max = apu;
                    if (apu < ch2_min) ch2_min = apu;
                end
        sq1 = 15; sq2 = 15; trg = 15; noi = 15; dmc = 127; #1;
        apu_max = apu;
        $display("APUMixer sample_apu: idle=%0d (0x%04h) ch1_max=%0d ch2 range %0d..%0d all-max=%0d (0x%04h)",
                 apu_idle, apu_idle[15:0], ch1_max, ch2_min, ch2_max, apu_max, apu_max[15:0]);
        check(apu_idle == 0, "APU silence is 0 before the nes.v inversion");
        check(apu_max == ch1_max + ch2_max, "all-max APU sample is the sum of the half maxima");

        // ---- APU-only path (audio_en == 2): old vs new HDMI sample, signed
        $display("APU path idle : sample=%04h old=%04h (%0d) new=%04h (%0d)",
                 16'hFFFF - apu_idle[15:0],
                 old_hdmi(16'hFFFF - apu_idle[15:0]), s16(old_hdmi(16'hFFFF - apu_idle[15:0])),
                 new_apu(16'hFFFF - apu_idle[15:0]), s16(new_apu(16'hFFFF - apu_idle[15:0])));
        $display("APU path max  : sample=%04h old=%04h (%0d) new=%04h (%0d)",
                 16'hFFFF - apu_max[15:0],
                 old_hdmi(16'hFFFF - apu_max[15:0]), s16(old_hdmi(16'hFFFF - apu_max[15:0])),
                 new_apu(16'hFFFF - apu_max[15:0]), s16(new_apu(16'hFFFF - apu_max[15:0])));
        check(s16(old_hdmi(16'hFFFF)) == 32767, "old chain: silence is +32767 DC (the bug)");
        check(s16(new_apu(16'hFFFF)) == -1, "new chain: silence maps to -1");
        prev = -32769;
        for (i = 0; i < 65536; i = i + 1) begin
            cur = s16(new_apu(i[15:0]));
            if (cur < prev || cur < -32768 || cur > -1)
                check(0, "new APU conversion wraps or is not monotonic");
            prev = cur;
        end

        // ---- Sunsoft 5B path (mapper 69), expansion silent, then at its
        // real maximum (3 channels * 177 << 5 from ss5b_amp_lut).
        exp_val = 0; ss_in = 16'hFFFF; #1;
        $display("SS5B path idle: sample=%04h old=%04h (%0d) new=%04h (%0d)",
                 ss_out, old_hdmi(ss_out), s16(old_hdmi(ss_out)),
                 new_ext(ss_out), s16(new_ext(ss_out)));
        check(ss_out == 16'h8000, "SS5B silence is offset-binary 8000");
        check(s16(new_ext(ss_out)) == 0, "new chain: SS5B silence maps to 0");
        mn = 65535; mx = 0;
        for (i = 0; i < 65536; i = i + 1) begin
            ss_in = i[15:0]; #1;
            if (ss_out < mn) mn = ss_out;
            if (ss_out > mx) mx = ss_out;
            if (s16(new_ext(ss_out)) != ss_out - 32768)
                check(0, "MSB flip is not the unsigned-to-signed bijection");
        end
        $display("SS5B sample over all audio_in (exp=0): %0d..%0d", mn, mx);
        exp_val = 3 * 177 * 32; ss_in = 16'hFFFF; #1;
        $display("SS5B exp-max, APU idle: sample=%04h new=%04h (%0d)",
                 ss_out, new_ext(ss_out), s16(new_ext(ss_out)));

        // ---- Namco 163 path (mapper 19), expansion silent (submapper 0)
        n163_en = 0; clk = 1; #1; clk = 0; #1;   // clock once: disabled <= 0
        n163_en = 1; n163_val = 0; n163_in = 16'hFFFF; #1;
        $display("N163 path idle: sample=%04h old=%04h (%0d) new=%04h (%0d)",
                 n163_out, old_hdmi(n163_out), s16(old_hdmi(n163_out)),
                 new_ext(n163_out), s16(new_ext(n163_out)));
        check(n163_out == 16'h7FFF, "N163 silence is offset-binary 7FFF");
        check(s16(new_ext(n163_out)) == -1, "new chain: N163 silence maps to -1");
        mn = 65535; mx = 0;
        for (i = 0; i < 65536; i = i + 1) begin
            n163_in = i[15:0]; #1;
            if (n163_out < mn) mn = n163_out;
            if (n163_out > mx) mx = n163_out;
        end
        $display("N163 sample over all audio_in (exp=0): %0d..%0d", mn, mx);

        if (errors == 0) $display("tb_audio_format: PASS");
        else             $display("tb_audio_format: %0d FAILURES", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end
endmodule
