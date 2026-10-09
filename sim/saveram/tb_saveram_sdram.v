// Battery-save channel testbench for iosys_bl616, SDRAM flavor (SAVE_SYNC=0).
//
// Same UART protocol as tb_saveram, but the DUT drives the req/ack save port of
// sdram_nes: a behavioral model with a configurable ack latency stands in for
// the SDRAM controller's save channel (snestang's BSRAM shape). Covers restore
// and dump byte-exactness THROUGH the handshake engine, back-pressure (an ack
// that arrives 30 clocks later, and the engine never issuing two transactions
// at once -- checked by invariant), and the dirty notice paths.

`timescale 1ns/1ps

module tb_saveram_sdram;

parameter FREQ = 21_492_000;          // nestang clk (fclk/3)
parameter BIT = 500.0;                // 2 Mbaud, ns

reg clk = 0;
always #23.264 clk = ~clk;            // 1/(2*FREQ) = 23.264 ns half period
reg resetn = 0;
reg uart_rx = 1;
wire uart_tx;

// ---- dut: iosys, save RAM behind the SDRAM save port (8 KB, 16 blocks) ----
wire [12:0] sv_addr;
wire [7:0] sv_din, sv_q;
wire sv_we, sv_req;
reg  sv_ack = 0;
wire sv_core_we;
reg  [11:0] joy1 = 0, joy2 = 0;

integer LAT = 2;                      // model's ack latency, in clocks

iosys_bl616 #(.FREQ(FREQ), .CORE_ID(1), .SAVE_IF(1), .SAVE_AW(13), .SAVE_SYNC(0)) dut (
    .clk(clk), .hclk(clk), .resetn(resetn),
    .overlay(), .overlay_x(8'h00), .overlay_y(8'h00), .overlay_color(),
    .joy1(joy1), .joy2(joy2), .hid1(), .hid2(),
    .rom_loading(), .rom_do(), .rom_do_valid(), .core_config(),
    .mgmt_readdata(16'h0), .fdd_request(2'b00), .kbd_data(8'h0),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(sv_we),
    .sv_q(sv_q), .sv_core_we(sv_core_we), .sv_req(sv_req), .sv_ack(sv_ack),
    .uart_rx(uart_rx), .uart_tx(uart_tx)
);

// ---- behavioral model of sdram_nes's save channel + the save RAM itself ----
reg [7:0] ram [0:8191];
reg [7:0] dout = 0;
integer cnt = 0;

always @(posedge clk) begin
    if (sv_req ^ sv_ack) begin
        if (cnt == LAT) begin
            if (sv_we)
                ram[sv_addr] = sv_din;
            else
                dout = ram[sv_addr];
            sv_ack <= ~sv_ack;          // toggle: one ack per transaction
            cnt <= 0;
        end else
            cnt <= cnt + 1;
    end else
        cnt <= 0;
end

assign sv_q = dout;
assign sv_core_we = core_we;

// the engine must never toggle sv_req while a transaction is outstanding
reg sv_req_d = 0;
always @(posedge clk) begin
    sv_req_d <= sv_req;
    if (sv_req != sv_req_d && sv_req_d != sv_ack) begin
        errs = errs + 1;
        $display("FAIL: engine issued a second request before the ack");
    end
end

// ---- the "game"'s side: writes straight into the array, plus the dirty hook
task core_write(input [12:0] a, input [7:0] d);
begin
    @(posedge clk); ram[a] = d;       // the core port, at once
    core_we <= 1;
    @(posedge clk); core_we <= 0;
end
endtask
reg core_we = 0;

task core_read_check(input [12:0] a, input [7:0] e);
begin
    repeat (LAT + 20) @(posedge clk);     // let the engine settle, like saves_settle()
    if (ram[a] !== e) begin
        errs = errs + 1;
        $display("FAIL: ram[%0h] = %02x, expected %02x", a, ram[a], e);
    end
end
endtask

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

task wait_for(input integer want);
    integer t;
begin
    t = 0;
    while (ncap < want && t < 4_000_000) begin @(posedge clk); t = t + 1; end
    if (ncap < want) begin
        errs = errs + 1;
        $display("FAIL: timeout waiting for byte %0d (have %0d)", want, ncap);
        $finish;
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
    for (k = 0; k < 8192; k = k + 1) ram[k] = 8'hFF;

    repeat (10) @(posedge clk);
    resetn = 1;
    repeat (50) @(posedge clk);

    // 1. a core write earns exactly one dirty notice (also: dirty logic is
    //    independent of the engine)
    core_write(13'h0100, 8'hAB);
    expect_dirty;
    expect_no_traffic(20_000);

    // 2. restore blocks through the handshake, fast ack
    restore(16'd0, 8'h11);
    restore(16'd6, 8'h3C);
    for (k = 0; k < 512; k = k + 64) begin
        core_read_check({9'd0, 6'd0,  k[8:0]}, pat(8'h11, k));
        core_read_check({9'd0, 6'd6,  k[8:0]}, pat(8'h3C, k));
    end
    core_read_check(13'h01FF, pat(8'h11, 511));
    core_read_check(13'h0DFF, pat(8'h3C, 511));

    // 3. slow ack: a full restore and dump with the controller lagging 30
    //    clocks (still a fraction of the 215-clk UART byte). No byte may be
    //    dropped, reordered or written twice.
    LAT = 30;
    restore(16'd5, 8'hA5);
    for (k = 0; k < 512; k = k + 64)
        core_read_check({9'd0, 6'd5,  k[8:0]}, pat(8'hA5, k));
    core_read_check(13'h0BFF, pat(8'hA5, 511));
    expect_dump(16'd5, 8'hA5);
    core_read_check(13'h0A00, pat(8'hA5, 0));      // untouched by the dump
    LAT = 2;

    // 4. byte-exact dump of the blocks
    expect_dump(16'd0, 8'h11);
    expect_dump(16'd6, 8'h3C);

    // 5. a write landing mid-dump dirties again and re-notifies, and the dump
    //   's own SDRAM reads never re-dirty
    request_dump(16'd0);
    dump_header(16'd0);
    for (k = 0; k < 100; k = k + 1) expect_byte(pat(8'h11, k));
    core_write(13'h0300, 8'h77);
    for (k = 100; k < 512; k = k + 1) expect_byte(pat(8'h11, k));
    expect_dirty;
    expect_no_traffic(20_000);

    // 6. dump block 0 (clean) with a 0x01 core-ID request arriving mid-reply
    send_hdr(16'd3, 8'h12); tx_byte(8'h00); tx_byte(8'h00);
    dump_header(16'd0);
    for (k = 0; k < 250; k = k + 1) expect_byte(pat(8'h11, k));
    send_hdr(16'd1, 8'h01);
    for (k = 250; k < 512; k = k + 1) expect_byte(pat(8'h11, k));
    expect_core_id;

    // 7. joypad wins arbitration from idle, the block reply follows it
    restore(16'd15, 8'h5A);
    joy1 = 12'h008;
    request_dump(16'd15);
    expect_byte(8'hAA); expect_byte(8'h00); expect_byte(8'h05); expect_byte(8'h03);
    expect_byte(8'h00); expect_byte(8'h08); expect_byte(8'h00); expect_byte(8'h00);
    dump_header(16'd15);
    for (k = 0; k < 512; k = k + 1) expect_byte(pat(8'h5A, k));

    // 8. a restore straight after a dump still lands (read/write interleave)
    restore(16'd15, 8'hC3);
    for (k = 0; k < 512; k = k + 64)
        core_read_check({9'd0, 6'd15, k[8:0]}, pat(8'hC3, k));

    if (errs == 0) $display("tb_saveram_sdram: PASS");
    else $display("tb_saveram_sdram: FAIL, %0d errors", errs);
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
