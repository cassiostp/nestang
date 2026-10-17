// RX desync testbench for iosys_bl616 (round-4 QA NES link stall, stalls
// with no save frame on the wire). The RX state machine has no inter-byte
// timeout: one dropped or flipped byte in an MCU->FPGA frame can inflate
// len_reg to up to 2047 and leave RX swallowing core-ID polls for as long
// as bytes keep trickling in, and a dropped header byte in an overlay
// cursor frame to column 18 (x = 8'h12) decodes as a save-block request
// (0x12) the firmware never sent -- on the pre-round-5 RTL that parked TX
// in SEND_SAVE_BLK when its acknowledgement edge was lost (tb_link_soak).
//
// This bench (dpram flavour, so the block fetch itself cannot park) shows:
//   T1 a plain poll is answered;
//   T2 the cursor desync emits a whole unsolicited 0x0A save-block frame;
//   T3 an inflated-length frame swallows polls across >1 ms gaps (the QA4
//      deafness). With the inter-byte timeout the partial frame is dropped
//      at the first gap and the next poll is answered;
//   T4 raw ASCII (an SDK printf to the console UART) between frames is
//      ignored, and spliced into a header it dies at the first gap too.
// Run with run.sh. On the RTL without the RX timeout, T3/T4 fail.

`timescale 1ns/1ps

module tb_rx_desync;

parameter FREQ = 21_492_000;
parameter BIT = 500.0;

reg clk = 0;
always #23.264 clk = ~clk;
reg resetn = 0;
reg uart_rx = 1;
wire uart_tx;

wire [12:0] sv_addr;
wire [7:0] sv_din, sv_q;
wire sv_we;
reg  [11:0] joy1 = 0, joy2 = 0;
reg         core_we = 0;

iosys_bl616 #(.FREQ(FREQ), .CORE_ID(1), .SAVE_IF(1), .SAVE_AW(13)) dut (
    .clk(clk), .hclk(clk), .resetn(resetn),
    .overlay(), .overlay_x(8'h00), .overlay_y(8'h00), .overlay_color(),
    .joy1(joy1), .joy2(joy2), .hid1(), .hid2(),
    .rom_loading(), .rom_do(), .rom_do_valid(), .core_config(),
    .mgmt_readdata(16'h0), .fdd_request(2'b00), .kbd_data(8'h0),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(sv_we),
    .sv_q(sv_q), .sv_core_we(core_we),
    .uart_rx(uart_rx), .uart_tx(uart_tx)
);

dpram #(.widthad_a(13)) save_ram (
    .clock_a(clk), .address_a(13'h0), .wren_a(1'b0), .data_a(8'h0),
    .q_a(), .byteena_a(1'b1),
    .clock_b(clk), .address_b(sv_addr), .wren_b(sv_we), .data_b(sv_din),
    .q_b(sv_q), .byteena_b(1'b1)
);

wire [7:0] cap_data;
wire cap_valid;
async_receiver #(.ClkFrequency(FREQ), .Baud(2_000_000)) cap (
    .clk(clk), .RxD(uart_tx), .RxD_data(cap_data), .RxD_data_ready(cap_valid)
);
reg [7:0] cap_mem [0:8191];
integer ncap = 0, errs = 0;
always @(posedge clk)
    if (cap_valid && ncap < 8192) begin
        cap_mem[ncap] = cap_data;
        ncap = ncap + 1;
    end

task tx_byte(input [7:0] b);
    integer k;
begin
    uart_rx = 1'b0; #BIT;
    for (k = 0; k < 8; k = k + 1) begin uart_rx = b[k]; #BIT; end
    uart_rx = 1'b1; #BIT;
end
endtask

task send_hdr(input [15:0] len, input [7:0] cmd);
begin
    tx_byte(8'hAA); tx_byte(len[15:8]); tx_byte(len[7:0]); tx_byte(cmd);
end
endtask

task poll;                                  // firmware core-ID poll
begin
    send_hdr(16'd1, 8'h01);
end
endtask

// wait up to `cycles` for a core-ID reply frame (AA 00 02 01 01)
task expect_id_reply(input integer cycles, input [8*48-1:0] what);
    integer t, base;
begin
    t = 0; base = ncap;
    while (ncap < base + 5 && t < cycles) begin @(posedge clk); t = t + 1; end
    if (ncap < base + 5 || cap_mem[base] !== 8'hAA || cap_mem[base+1] !== 8'h00 ||
        cap_mem[base+2] !== 8'h02 || cap_mem[base+3] !== 8'h01 ||
        cap_mem[base+4] !== 8'h01) begin
        errs = errs + 1;
        $display("FAIL: %0s: no core-ID reply (%0d bytes captured)", what, ncap - base);
    end else
        $display("ok: %0s: core-ID reply after %0d cycles", what, t);
end
endtask

initial begin
    // model FF power-on state (Gowin FFs come up 0; these regs have no reset)
    dut.send_idx = 0; dut.response_req = 0; dut.response_ack = 0;
    dut.joy1_reg = 0; dut.joy2_reg = 0; dut.send_state_next = 0;

    repeat (20) @(posedge clk);
    resetn = 1;
    repeat (50) @(posedge clk);

    // T1: sanity poll
    poll;
    expect_id_reply(200000, "T1 plain poll");

    // T2: overlay cursor to (18, 12) with the LEN2 byte dropped on the
    // wire: AA 00 [03 dropped] 04 12 0C decodes as len=4 cmd=0x12, blk
    // high byte 0x0C; the next two bytes on the wire (here AA 00, the
    // start of whatever frame follows) complete it as blk=16'h0CAA
    // -> an unsolicited save-block frame AA 02 03 0A <514 bytes>.
    begin : t2
        integer base, t;
        base = ncap;
        tx_byte(8'hAA); tx_byte(8'h00); tx_byte(8'h04);
        tx_byte(8'h12); tx_byte(8'h0C); tx_byte(8'hAA); tx_byte(8'h00);
        t = 0;
        while (ncap < base + 518 && t < 2_000_000) begin @(posedge clk); t = t + 1; end
        if (ncap >= base + 518 && cap_mem[base] === 8'hAA &&
            cap_mem[base+3] === 8'h0A)
            $display("ok: T2 cursor desync produced unsolicited 0x0A block frame (as on QA4 RTL)");
        else begin
            errs = errs + 1;
            $display("FAIL: T2 expected unsolicited 0x0A frame, got %0d bytes", ncap - base);
        end
    end
    poll;
    expect_id_reply(200000, "T2 poll after garbage block");

    // T3: length MSB flipped 0x00 -> 0x01 in a cursor frame: len = 259,
    // RX sits in RECV_PARAM. Polls arrive with 2 ms gaps (the firmware
    // polls every 250 ms in game). Without an RX timeout every poll is
    // swallowed as params; with it the frame dies in the first gap.
    tx_byte(8'hAA); tx_byte(8'h01); tx_byte(8'h03); tx_byte(8'h04);
    tx_byte(8'h02); tx_byte(8'h05);
    #2_000_000;                              // 2 ms of silence
    poll;
    #2_000_000;
    poll;
    expect_id_reply(400000, "T3 poll after inflated-length frame");

    // T4a: raw ASCII between frames (SDK printf) is ignored.
    begin : t4a
        integer k;
        reg [8*16-1:0] s;
        s = "[I/usbh] reset  ";
        for (k = 15; k >= 0; k = k - 1) tx_byte(s[8*k +: 8]);
    end
    poll;
    expect_id_reply(200000, "T4a poll after raw printf burst");

    // T4b: the same burst spliced into a config frame's header
    // (AA 00 <burst> 05 03 ...): LEN2 becomes '[', cmd 'I', and RX
    // swallows params until the frame completes or a gap kills it.
    tx_byte(8'hAA); tx_byte(8'h00);
    begin : t4b
        integer k;
        reg [8*16-1:0] s;
        s = "[I/usbh] reset  ";
        for (k = 15; k >= 0; k = k - 1) tx_byte(s[8*k +: 8]);
    end
    tx_byte(8'h05); tx_byte(8'h03);
    tx_byte(8'h00); tx_byte(8'h00); tx_byte(8'h00); tx_byte(8'h00);
    #2_000_000;
    poll;
    expect_id_reply(400000, "T4b poll after spliced printf burst");

    // T5: 0x17 (link resync) while idle, then a poll. The command is not
    // a poll and must not stop the next core-ID reply.
    send_hdr(16'd1, 8'h17);
    poll;
    expect_id_reply(200000, "T5 poll after 0x17");

    // T5b: a long frame, a gap so RX returns to idle, then 0x17, then a
    // poll. 0x17 sent with no gap would be swallowed as a parameter.
    tx_byte(8'hAA); tx_byte(8'h01); tx_byte(8'h03); tx_byte(8'h04);
    tx_byte(8'h02); tx_byte(8'h05);
    #2_000_000;
    send_hdr(16'd1, 8'h17);
    poll;
    expect_id_reply(400000, "T5b poll after gap and 0x17");

    if (errs == 0)
        $display("tb_rx_desync: PASS");
    else
        $display("tb_rx_desync: %0d FAILURES", errs);
    $finish;
end

endmodule
