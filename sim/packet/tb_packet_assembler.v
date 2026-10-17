// packet_assembler with shift registers against the module as it was before
// (built from git history by run.sh as packet_assembler_old). Both get the
// same header/sub/data_island_period every clock; packet_data and counter
// must match on every clock, in and out of the island. The inputs follow
// the packet_picker's contract: header/sub change only while the island is
// off or in the cycle the counter wraps to 0, and then hold still for the
// whole 32-cycle packet. Back-to-back packets, packet bursts with gaps,
// and a reset pulse are covered.
`timescale 1ns/1ps

module tb_packet_assembler;

    reg clk_pixel = 0;
    always #3.367 clk_pixel = ~clk_pixel;       // 148.5 MHz

    reg        reset = 0;
    reg        data_island_period = 0;
    reg [23:0] header = 24'd0;
    reg [55:0] sub [3:0];

    wire [8:0] pd_new, pd_old;
    wire [4:0] cnt_new, cnt_old;
    packet_assembler     dut (.clk_pixel(clk_pixel), .reset(reset), .data_island_period(data_island_period),
                              .header(header), .sub(sub), .packet_data(pd_new), .counter(cnt_new));
    packet_assembler_old gold (.clk_pixel(clk_pixel), .reset(reset), .data_island_period(data_island_period),
                              .header(header), .sub(sub), .packet_data(pd_old), .counter(cnt_old));

    integer clocks = 0, bad = 0, npacket = 0;
    reg [31:0] h = 32'h13579BDF;
    function [31:0] rnd(input integer dummy);
        begin
            h = h * 32'd1664525 + 32'd1013904223;
            rnd = h ^ (h >> 13);
        end
    endfunction

    // a fresh random packet on the inputs (call only when the picker may)
    task new_packet;
        begin
            header = rnd(0);
            sub[0] = {rnd(0), rnd(0)};
            sub[1] = {rnd(0), rnd(0)};
            sub[2] = {rnd(0), rnd(0)};
            sub[3] = {rnd(0), rnd(0)};
            npacket = npacket + 1;
        end
    endtask

    // compare just before every edge: the values of the ending cycle
    always @(negedge clk_pixel) begin
        clocks = clocks + 1;
        if (pd_new !== pd_old || cnt_new !== cnt_old) begin
            bad = bad + 1;
            if (bad < 8)
                $display("MISMATCH at clock %0d island=%b counter new=%0d old=%0d: packet_data new %h old %h",
                         clocks, data_island_period, cnt_new, cnt_old, pd_new, pd_old);
        end
    end

    integer burst, pkt, gap, c;
    initial begin
        sub[0] = 56'd0; sub[1] = 56'd0; sub[2] = 56'd0; sub[3] = 56'd0;
        // a reset pulse first, inputs changing while reset is on
        reset = 1;
        repeat (3) @(posedge clk_pixel);
        @(negedge clk_pixel); new_packet;
        repeat (2) @(posedge clk_pixel);
        @(negedge clk_pixel); reset = 0;

        // bursts of 1..6 back-to-back packets with 0..40 idle clocks between
        while (npacket < 300) begin
            burst = 1 + rnd(0) % 6;
            @(negedge clk_pixel);
            new_packet;
            data_island_period = 1;
            for (pkt = 0; pkt < burst; pkt = pkt + 1) begin
                // wait out this packet; change the inputs in its counter-0
                // cycle for the next one, like packet_enable does
                for (c = 0; c < 32; c = c + 1) begin
                    @(posedge clk_pixel);
                    if (c == 31 && pkt != burst - 1)
                        @(negedge clk_pixel) new_packet;
                end
            end
            @(negedge clk_pixel);
            data_island_period = 0;
            gap = rnd(0) % 40;
            // inputs may wander while the island is off
            for (c = 0; c < gap; c = c + 1) begin
                @(posedge clk_pixel);
                if (rnd(0) % 3 == 0)
                    @(negedge clk_pixel) new_packet;
            end
        end
        $display("tb_packet_assembler: %0d clocks, %0d packets, %0d mismatches", clocks, npacket, bad);
        if (bad != 0 || npacket < 300) begin
            $display("tb_packet_assembler: FAIL");
            $fatal(1, "tb_packet_assembler: FAIL");
        end
        $display("tb_packet_assembler: PASS");
        $finish;
    end
endmodule
