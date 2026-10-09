// Battery-save channel testbench for iosys_bl616, dpram flavor (SAVE_SYNC=1).
//
// The same protocol test as smstang's tb_saveram, on nestang's iosys at its
// console clock (21.4912 Mhz, 2 Mbaud UART bit timing) with an 8 KB dpram. It
// guards the SAVE_SYNC=1 half of the save channel: restore/dump byte-exactness,
// the 0x0B notice, the block-0 dump clearing dirty (and a write during a dump
// re-notifying), joypad/core-ID arbitration around a block reply, and that
// other cores' FDD commands (0x0a/0x0b) are consumed, not acted on.
// Run with run.sh (iverilog, `define SIM skips textdisp).

`timescale 1ns/1ps

module tb_saveram;

parameter FREQ = 21_492_000;          // nestang clk (fclk/3)
parameter BIT = 500.0;                // 2 Mbaud, ns

reg clk = 0;
always #23.264 clk = ~clk;            // 1/(2*FREQ) = 23.264 ns half period
reg resetn = 0;
reg uart_rx = 1;
wire uart_tx;

// ---- dut: iosys with the save channel, SAVE_AW=13 (8 KB, 16 blocks) ----
wire [12:0] sv_addr;
wire [7:0] sv_din, sv_q;
wire sv_we;
reg  [11:0] joy1 = 0, joy2 = 0;

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

// ---- the "game"'s port of the save RAM: port A ----
reg  [12:0] core_a = 0;
reg  [7:0]  core_d = 0;
reg         core_we = 0;
wire [7:0]  core_q;

dpram #(.widthad_a(13)) save_ram (
    .clock_a(clk), .address_a(core_a), .wren_a(core_we), .data_a(core_d),
    .q_a(core_q), .byteena_a(1'b1),
    .clock_b(clk), .address_b(sv_addr), .wren_b(sv_we), .data_b(sv_din),
    .q_b(sv_q), .byteena_b(1'b1)
);

// ---- capture dut's uart_tx ----
wire [7:0] cap_data;
wire cap_valid;
async_receiver #(.ClkFrequency(FREQ), .Baud(2_000_000)) cap (
    .clk(clk), .RxD(uart_tx), .RxD_data(cap_data), .RxD_data_ready(cap_valid)
);
reg [7:0] cap_mem [0:65535];
integer ncap = 0, rcnt = 0, errs = 0;
always @(posedge clk)
    if (cap_valid && ncap < 65536) begin
        cap_mem[ncap] = cap_data;
        ncap = ncap + 1;
    end

// block byte pattern
function [7:0] pat(input [7:0] seed, input integer i);
    pat = seed + i[7:0];
endfunction

// ---- stimulus ----
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

task restore(input [15:0] blk, input [7:0] seed);
    integer k;
begin
    send_hdr(16'd515, 8'h11); tx_byte(blk[15:8]); tx_byte(blk[7:0]);
    for (k = 0; k < 512; k = k + 1) tx_byte(pat(seed, k));
end
endtask

task core_write(input [12:0] a, input [7:0] d);
begin
    @(posedge clk); core_a <= a; core_d <= d; core_we <= 1;
    @(posedge clk); core_we <= 0;
end
endtask

task core_read_check(input [12:0] a, input [7:0] e);
begin
    @(posedge clk); core_a <= a;
    @(posedge clk); @(posedge clk);   // q_a is registered: one settling edge
    if (core_q !== e) begin
        errs = errs + 1;
        $display("FAIL: ram[%0h] = %02x, expected %02x", a, core_q, e);
    end
end
endtask

task wait_for(input integer want);
    integer t;
begin
    t = 0;
    while (ncap < want && t < 4_000_000) begin @(posedge clk); t = t + 1; end
    if (ncap < want) begin
        errs = errs + 1;
        $fatal(1, "FAIL: timeout waiting for byte %0d (have %0d)", want, ncap);
    end
end
endtask

task expect_byte(input [7:0] e);
    reg [7:0] b;
begin
    wait_for(rcnt + 1);
    b = cap_mem[rcnt]; rcnt = rcnt + 1;
    if (b !== e) begin
        errs = errs + 1;
        $display("FAIL: byte %0d = %02x, expected %02x", rcnt - 1, b, e);
    end
end
endtask

task expect_dirty;
begin
    expect_byte(8'hAA); expect_byte(8'h00); expect_byte(8'h02);
    expect_byte(8'h0B); expect_byte(8'h00);
end
endtask

task expect_core_id;
begin
    expect_byte(8'hAA); expect_byte(8'h00); expect_byte(8'h02);
    expect_byte(8'h01); expect_byte(8'h01);   // CORE_ID=1 for nestang
end
endtask

task dump_header(input [15:0] blk);
begin
    expect_byte(8'hAA); expect_byte(8'h02); expect_byte(8'h03);
    expect_byte(8'h0A); expect_byte(blk[15:8]); expect_byte(blk[7:0]);
end
endtask

task request_dump(input [15:0] blk);
begin
    send_hdr(16'd3, 8'h12); tx_byte(blk[15:8]); tx_byte(blk[7:0]);
end
endtask

task expect_dump(input [15:0] blk, input [7:0] seed);
    integer k;
begin
    request_dump(blk);
    dump_header(blk);
    for (k = 0; k < 512; k = k + 1) expect_byte(pat(seed, k));
end
endtask

integer k;

initial begin
    // model FF power-on state (Gowin FFs come up 0; these regs have no reset)
    dut.send_idx = 0; dut.response_req = 0; dut.response_ack = 0;
    dut.joy1_reg = 0; dut.joy2_reg = 0; dut.send_state_next = 0;

    repeat (10) @(posedge clk);
    resetn = 1;
    repeat (50) @(posedge clk);

    // 1. a core write earns exactly one dirty notice
    core_write(13'h0100, 8'hAB);
    expect_dirty;
    expect_no_traffic(20_000);

    // 2. restore blocks, read back through the game's port; the last byte of
    //    each block must survive the next frame's block-number byte
    restore(16'd0,  8'h11);
    restore(16'd5,  8'hA5);
    restore(16'd6,  8'h3C);
    for (k = 0; k < 512; k = k + 64) begin
        core_read_check({9'd0, 6'd0,  k[8:0]}, pat(8'h11, k));
        core_read_check({9'd0, 6'd5,  k[8:0]}, pat(8'hA5, k));
        core_read_check({9'd0, 6'd6,  k[8:0]}, pat(8'h3C, k));
    end
    core_read_check(13'h01FF, pat(8'h11, 511));
    core_read_check(13'h0BFF, pat(8'hA5, 511));
    core_read_check(13'h0DFF, pat(8'h3C, 511));

    // 3. dump them back, byte exact
    expect_dump(16'd5, 8'hA5);
    expect_dump(16'd6, 8'h3C);

    // 4. a write landing mid-dump dirties again and re-notifies: dump block 0
    //    (clears dirty), game-write during it, 0x0B follows the block
    request_dump(16'd0);
    dump_header(16'd0);
    for (k = 0; k < 100; k = k + 1) expect_byte(pat(8'h11, k));
    core_write(13'h0300, 8'h77);              // block 3: doesn't disturb dump
    for (k = 100; k < 512; k = k + 1) expect_byte(pat(8'h11, k));
    expect_dirty;

    // 5. dump block 0 again (clean: no core write) while a 0x01 core-ID
    //    request is pending: the block reply must not swallow the core ID
    send_hdr(16'd3, 8'h12); tx_byte(8'h00); tx_byte(8'h00);
    dump_header(16'd0);
    for (k = 0; k < 200; k = k + 1) expect_byte(pat(8'h11, k));
    send_hdr(16'd1, 8'h01);                   // request during the reply
    for (k = 200; k < 512; k = k + 1) expect_byte(pat(8'h11, k));
    expect_core_id;                           // ... answered, RX not stuck

    // 6. other cores' FDD commands are consumed, not acted on
    send_hdr(16'd3, 8'h0A); tx_byte(8'h12); tx_byte(8'h34);
    send_hdr(16'd5, 8'h0B); tx_byte(8'hF2); tx_byte(8'h00); tx_byte(8'h00); tx_byte(8'h01);
    expect_no_traffic(20_000);
    send_hdr(16'd1, 8'h01);
    expect_core_id;

    // 7. a joypad change and a block reply arbitrate: joypad wins from idle,
    //    and a 0x01 arriving during the reply still comes out after it
    restore(16'd15, 8'h5A);
    joy1 = 12'h008;                           // pad 1 B pressed
    request_dump(16'd15);
    expect_byte(8'hAA); expect_byte(8'h00); expect_byte(8'h05); expect_byte(8'h03);
    expect_byte(8'h00); expect_byte(8'h08); expect_byte(8'h00); expect_byte(8'h00);
    dump_header(16'd15);
    for (k = 0; k < 300; k = k + 1) expect_byte(pat(8'h5A, k));
    send_hdr(16'd1, 8'h01);
    for (k = 300; k < 512; k = k + 1) expect_byte(pat(8'h5A, k));
    expect_core_id;

    // 8. protocol still healthy: dump block 6 once more
    expect_dump(16'd6, 8'h3C);

    if (errs == 0) $display("tb_saveram: PASS");
    else $fatal(1, "tb_saveram: FAIL, %0d errors", errs);
    $finish;
end

// nothing at all must appear on uart_tx for `cycles` clocks
task expect_no_traffic(input integer cycles);
    integer base, t;
begin
    base = ncap; t = 0;
    while (ncap == base && t < cycles) begin @(posedge clk); t = t + 1; end
    if (ncap != base) begin
        errs = errs + 1;
        $display("FAIL: unexpected byte %02x (byte %0d) on uart_tx", cap_mem[base], base);
    end
end
endtask

endmodule
