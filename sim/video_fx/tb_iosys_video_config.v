// iosys_bl616 command 0x13 (video_config), through the real UART receiver: the frame sets the
// register, big-endian like command 3, whatever is already in it; command 3 leaves it alone
// and 0x13 leaves core_config alone; a frame for another command in between changes neither;
// reset clears it.
`timescale 1ns/1ps

module tb_iosys_video_config;

    parameter FREQ = 21_492_000;
    parameter BIT = 500.0;                      // 2 Mbaud, ns

    reg clk = 0;
    always #23.264 clk = ~clk;
    reg resetn = 0;
    reg uart_rx = 1;
    wire uart_tx;
    wire [31:0] core_config, video_config;

    iosys_bl616 #(.FREQ(FREQ), .CORE_ID(1)) dut (
        .clk(clk), .hclk(clk), .resetn(resetn),
        .overlay(), .overlay_x(8'h00), .overlay_y(8'h00), .overlay_color(),
        .joy1(12'h0), .joy2(12'h0), .hid1(), .hid2(),
        .rom_loading(), .rom_do(), .rom_do_valid(),
        .core_config(core_config), .video_config(video_config),
        .mgmt_readdata(16'h0), .fdd_request(2'b00), .kbd_data(8'h0),
        .sv_addr(), .sv_din(), .sv_we(), .sv_q(8'h0), .sv_core_we(1'b0),
        .uart_rx(uart_rx), .uart_tx(uart_tx)
    );

    task tx_byte(input [7:0] b);
        integer k;
        begin
            uart_rx = 1'b0; #BIT;
            for (k = 0; k < 8; k = k + 1) begin uart_rx = b[k]; #BIT; end
            uart_rx = 1'b1; #BIT;
        end
    endtask

    task frame4(input [7:0] cmd, input [31:0] v);
        begin
            tx_byte(8'hAA); tx_byte(8'h00); tx_byte(8'h05); tx_byte(cmd);
            tx_byte(v[31:24]); tx_byte(v[23:16]); tx_byte(v[15:8]); tx_byte(v[7:0]);
            #(4 * BIT);
        end
    endtask

    task expect_cfg(input [31:0] core, input [31:0] video, input [8*40-1:0] what);
        begin
            if (core_config !== core || video_config !== video) begin
                $display("FAIL: %0s: core_config %h (want %h), video_config %h (want %h)",
                         what, core_config, core, video_config, video);
                $fatal(1, "tb_iosys_video_config: FAIL");
            end
        end
    endtask

    initial begin
        #200 resetn = 1;
        #2000;
        expect_cfg(32'h0, 32'h0, "after reset");
        frame4(8'h13, 32'h0001_2000);
        expect_cfg(32'h0, 32'h0001_2000, "0x13");
        frame4(8'h03, 32'h0003_0000);
        expect_cfg(32'h0003_0000, 32'h0001_2000, "0x03 after 0x13");
        frame4(8'h13, 32'h89AB_CDEF);
        expect_cfg(32'h0003_0000, 32'h89AB_CDEF, "0x13, all byte lanes");
        frame4(8'h0d, 32'hFFFF_FFFF);           // debug printf: ignored
        expect_cfg(32'h0003_0000, 32'h89AB_CDEF, "other command");
        frame4(8'h13, 32'h0);
        expect_cfg(32'h0003_0000, 32'h0, "0x13 clears");
        frame4(8'h13, 32'hFFFF_FFFF);
        resetn = 0; #200; resetn = 1; #200;
        expect_cfg(32'h0, 32'h0, "reset");
        $display("tb_iosys_video_config: PASS");
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "tb_iosys_video_config: timeout");
    end
endmodule
