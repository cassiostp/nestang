// Link soak / stall regression (round-4 QA: the NES core's UART went silent
// a few seconds into any game, tangcore QA4 U1/U4/N6/S1). The REAL
// iosys_bl616 (clk, 21.49 MHz) wired to the REAL sdram_nes (fclk = 3 x clk,
// clk edge placed at parameter PHASE within the fclk period) through the
// save channel, exactly as nestang_top does it, with a behavioral SDRAM,
// NES-like CPU/PPU traffic -- CPU accesses, PPU fetches and VRAM writes,
// WRAM writes that dirty the save -- and an MCU model that behaves like the
// firmware in game: restore at load, whole dumps (16 x 0x12 -> 0x0A) while
// polling the core ID, sending HID frames and pad changes, plus game-menu
// rounds (overlay on, the NES frozen by core_config[17] at a different
// divider phase each round so oe/we are caught held in several states, a
// settle dump against the frozen core, menu text, resume -- once mid-dump).
// The MCU-side parser carries the firmware's mid-frame gap resync, scaled.
// Finally one save acknowledgement is eaten inside the engine for far
// longer than any fetch takes (a lost toggle on the clk/fclk crossing):
// the block in flight may be abandoned, but polls, pads and later dumps
// must carry on. On the pre-fix iosys that injection parks TX in
// SEND_SAVE_BLK forever (send_state=10, sv_data_rdy=0 with the SDRAM side
// idle) and every check after it fails.
//
// run.sh compiles a sim copy of iosys with the 20 ms joypad rate limit
// shortened, so a pad change is due within ~0.5 ms here.

`timescale 1ns/1ps

package configPackage;
    localparam SDRAM_DATA_WIDTH = 16;
    localparam SDRAM_ROW_WIDTH  = 13;
endpackage

module tb_link_soak;
import configPackage::*;

localparam real BIT = 500.0;            // MCU UART: 2 Mbaud, 1 stop bit

// ---- clocks: fclk from the PLL, clk = fclk/3 in phase (clkoutd3) ----
reg fclk = 0;
always #7.7555 fclk = ~fclk;            // 64.47 MHz
reg clk = 0;
integer fdiv = 0;
parameter PHASE = 0;                    // clk edge offset within the 3-fclk period
always @(posedge fclk) begin
    fdiv <= fdiv == 2 ? 0 : fdiv + 1;
    if (fdiv == PHASE) clk <= 1;
    if (fdiv == (PHASE + 1) % 3) clk <= 0;   // 1/3 duty is fine for the logic here
end

reg sys_resetn = 0;
reg clkref = 0;
always @(posedge clk) clkref <= ~clkref;

function [7:0] pat(input [7:0] seed, input integer blk, input integer i);
    pat = seed ^ (blk * 37) ^ i[7:0] ^ (i >> 8);
endfunction

// ---- NES-like CPU/PPU traffic in the CPU/PPU slot (clk domain) ----
reg [21:0] addrA = 0, addrB = 0;
reg        oeA = 0, oeB = 0, weB = 0, weA = 0;
reg  [7:0] dinB = 0;
reg        core_we = 0;
reg        traffic = 0;
reg        paused = 0;                  // menu pause: the NES dividers hold, oe/we freeze
integer    tc = 0;
reg [11:0] wofs;
always @(posedge clk) begin
    if (!paused) tc <= tc + 1;
    core_we <= 0;
    if (traffic && !paused) begin
        // PPU: one fetch every 8 clk (2 PPU dots), held 4 clk; occasionally
        // a VRAM write instead (CHR-RAM games: $2007 writes ride port A)
        if (tc % 8 == 0) begin
            addrA <= 22'h200000 + (tc & 22'h1FFF);
            if ((tc % 64) == 32) weA <= 1; else oeA <= 1;
        end
        if (tc % 8 == 4) begin oeA <= 0; weA <= 0; end
        // CPU: one access every 12 clk, held 6 clk; now and then a WRAM write
        if (tc % 12 == 0) begin
            if (($random & 15) == 0) begin
                // the game rewrites the save with what it already holds, so the
                // dumps stay checkable while the dirty logic sees real writes
                wofs = 12'h F00 + ($random & 12'h0FF);
                weB <= 1; addrB <= 22'h3C0000 + wofs; dinB <= pat(8'h5A, wofs >> 9, wofs & 12'h1FF);
                core_we <= 1;
            end else begin
                oeB <= 1; addrB <= 22'h000000 + ($random & 22'h7FFF);
            end
        end
        if (tc % 12 == 6) begin oeB <= 0; weB <= 0; end
    end else if (!traffic) begin
        oeA <= 0; oeB <= 0; weB <= 0; weA <= 0;
    end
end

// ---- DUT: iosys + sdram_nes, connected as in nestang_top ----
wire [12:0] sv_addr;
wire [7:0]  sv_din, sv_q;
wire        sv_we, sv_req, sv_ack;
reg  [11:0] joy1 = 0, joy2 = 0;
reg         uart_rx = 1;
wire        uart_tx;

iosys_bl616 #(.FREQ(21_492_000), .CORE_ID(1), .SAVE_IF(1), .SAVE_AW(13), .SAVE_SYNC(0)) sys (
    .clk(clk), .hclk(clk), .resetn(sys_resetn),
    .overlay(), .overlay_x(8'h00), .overlay_y(8'h00), .overlay_color(),
    .joy1(joy1), .joy2(joy2), .hid1(), .hid2(),
    .rom_loading(), .rom_do(), .rom_do_valid(), .core_config(),
    .mgmt_readdata(16'h0), .fdd_request(2'b00), .kbd_data(8'h0),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(sv_we), .sv_q(sv_q),
    .sv_core_we(core_we), .sv_req(sv_req), .sv_ack(sv_ack),
    .uart_rx(uart_rx), .uart_tx(uart_tx)
);

wire [SDRAM_ROW_WIDTH-1:0] A;
wire [1:0] BA, DQM;
wire nCS, nWE, nRAS, nCAS, cke, busy;
wire [15:0] SDRAM_DQ;
wire [7:0] doutA, doutB;

sdram_nes sdram (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_nCS(nCS),
    .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_CKE(cke),
    .SDRAM_DQM(DQM),
    .clk(fclk), .clkref(clkref), .resetn(sys_resetn), .busy(busy),
    .addrA(addrA), .weA(weA), .dinA(8'h3C), .oeA(oeA & ~weA), .doutA(doutA),
    .addrB(addrB), .weB(weB), .dinB(dinB), .oeB(oeB), .doutB(doutB),
    .rv_addr(20'h0), .rv_din(16'h0), .rv_ds(2'b00), .rv_dout(), .rv_req(1'b0),
    .rv_req_ack(), .rv_we(1'b0),
    .sv_addr({9'b11_1100_000, sv_addr}), .sv_din(sv_din), .sv_we(sv_we),
    .sv_req(sv_req), .sv_ack(sv_ack), .sv_dout(sv_q)
);

// ---- behavioral SDRAM (as tb_sdram_save): 2 banks, CL2 ----
reg [10:0] row_lat [0:1];
reg [15:0] mem [0:(1<<21)-1];
wire [3:0] cmd = {nCS, nRAS, nCAS, nWE};
wire [20:0] word = {BA[0], row_lat[BA[0]], A[8:0]};
reg rv0 = 0, rv1 = 0;
reg [15:0] rq0 = 0, rq1 = 0;
always @(posedge fclk) begin
    if (cmd == 4'b0011)
        row_lat[BA[0]] <= A[10:0];
    else if (cmd == 4'b0100) begin
        if (!DQM[0]) mem[word][7:0]  <= SDRAM_DQ[7:0];
        if (!DQM[1]) mem[word][15:8] <= SDRAM_DQ[15:8];
    end
    {rv1, rq1} <= {rv0, rq0};
    {rv0, rq0} <= {cmd == 4'b0101, mem[word]};
end
assign SDRAM_DQ = rv1 ? rq1 : 16'hzzzz;

// ---- MCU side: receive and parse the FPGA's frames ----
wire [7:0] cap_data;
wire cap_valid;
async_receiver #(.ClkFrequency(21_492_000), .Baud(2_000_000)) cap (
    .clk(clk), .RxD(uart_tx), .RxD_data(cap_data), .RxD_data_ready(cap_valid)
);

integer errs = 0;
integer pos = 0, flen = 0;
reg [7:0] ftype = 0;
reg [7:0] fbuf [0:1023];
integer n_id = 0, n_dirty = 0, n_joy = 0, n_blk = 0;
reg [15:0] last_joy1 = 0;
reg [15:0] last_blk = 16'hFFFF;
reg [7:0]  blkdata [0:511];

// the firmware's parser resync, scaled: a frame's bytes arrive 5 us apart,
// so a gap over 1 ms mid-frame means the rest was abandoned (uart1_rx_task
// uses 50 ms at real scale). Without it an abandoned save block would eat
// every later frame here, which the real firmware does not do.
time last_cap = 0;
integer epos;
always @(posedge clk) if (cap_valid) begin
    epos = (pos != 0 && $time - last_cap > 1_000_000) ? 0 : pos;
    if (epos == 0 && pos != 0)
        $display("bench parser resync at t=%0t (abandoned frame dropped)", $time);
    last_cap = $time;
    if (epos == 0) begin
        if (cap_data == 8'hAA) pos <= 1;
        else begin errs = errs + 1; $display("FAIL t=%0t: junk byte %02x between frames", $time, cap_data); end
    end else if (epos == 1) begin flen <= cap_data << 8; pos <= 2; end
    else if (epos == 2) begin flen <= flen | cap_data; pos <= 3; end
    else if (epos == 3) begin ftype <= cap_data; pos <= 4; end
    else begin
        fbuf[epos - 4] = cap_data;
        if (epos - 4 == flen - 2) begin          // last payload byte
            pos <= 0;
            case (ftype)
            8'h01: begin
                n_id = n_id + 1;
                if (fbuf[0] !== 8'h01) begin errs = errs + 1; $display("FAIL: core id %02x", fbuf[0]); end
            end
            8'h03: begin n_joy = n_joy + 1; last_joy1 = {fbuf[0], fbuf[1]}; end
            8'h0A: begin
                last_blk = {fbuf[0], fbuf[1]};
                for (integer i = 0; i < 512; i = i + 1) blkdata[i] = fbuf[2 + i];
                n_blk = n_blk + 1;
            end
            8'h0B: n_dirty = n_dirty + 1;
            default: begin errs = errs + 1; $display("FAIL: unknown frame type %02x", ftype); end
            endcase
        end else
            pos <= epos + 1;
    end
end

// ---- MCU side: send frames (one sender at a time, like taskENTER_CRITICAL) ----
reg tx_lock = 0;
task tx_byte(input [7:0] b);
    integer k;
begin
    uart_rx = 1'b0; #BIT;
    for (k = 0; k < 8; k = k + 1) begin uart_rx = b[k]; #BIT; end
    uart_rx = 1'b1; #BIT;
end
endtask
task lock;   begin while (tx_lock) #50; tx_lock = 1; end endtask
task unlock; begin tx_lock = 0; end endtask
task send_hdr(input [15:0] len, input [7:0] c);
begin tx_byte(8'hAA); tx_byte(len[15:8]); tx_byte(len[7:0]); tx_byte(c); end
endtask


task restore_all(input [7:0] seed);
    integer b, k;
begin
    for (b = 0; b < 16; b = b + 1) begin
        lock;
        send_hdr(16'd515, 8'h11); tx_byte(b >> 8); tx_byte(b[7:0]);
        for (k = 0; k < 512; k = k + 1) tx_byte(pat(seed, b, k));
        unlock;
    end
end
endtask

// one firmware sv_fetch_block(): 0x12, then the block within 1 s (scaled: 10 ms; one block frame takes ~2.9 ms)
task fetch(input integer b, input [7:0] seed, input check);
    integer n0, t, k;
begin
    n0 = n_blk;
    lock; send_hdr(16'd3, 8'h12); tx_byte(b >> 8); tx_byte(b[7:0]); unlock;
    t = 0;
    while (n_blk == n0 && t < 10000) begin #1000; t = t + 1; end
    if (n_blk == n0) begin
        errs = errs + 1;
        $display("FAIL t=%0t: block %0d never arrived  send_state=%0d sv_idx=%0d sv_data_rdy=%b sv_req=%b sv_ack=%b ack_s=%b rd_pend=%b wr_pend=%b we_e=%b rd_lat=%0d sdram_req_q=%b sdram_port0=%0d paused=%b oeA=%b oeB=%b weB=%b",
                 $time, b, sys.send_state, sys.sv_idx, sys.sv_data_rdy, sv_req, sv_ack, sys.sv_ack_s, sys.sv_rd_pend, sys.sv_wr_pend, sys.sv_we_e, sys.sv_rd_lat, sdram.sv_req_q, sdram.port[0], paused, oeA, oeB, weB);
    end else if (last_blk != b) begin
        errs = errs + 1; $display("FAIL: asked block %0d, got %0d", b, last_blk);
    end else if (check) begin
        for (k = 0; k < 512; k = k + 1)
            if (blkdata[k] !== pat(seed, b, k)) begin
                errs = errs + 1;
                if (errs < 20) $display("FAIL: block %0d byte %0d = %02x, expected %02x", b, k, blkdata[k], pat(seed, b, k));
            end
    end
end
endtask

// like fetch(), but a timeout is the expected outcome of the injected fault
task fetch_may_fail(input integer b);
    integer n0, t;
begin
    n0 = n_blk;
    lock; send_hdr(16'd3, 8'h12); tx_byte(b >> 8); tx_byte(b[7:0]); unlock;
    t = 0;
    while (n_blk == n0 && t < 10000) begin #1000; t = t + 1; end
    if (n_blk == n0)
        $display("fault block %0d did not arrive (abandoned or wedged) send_state=%0d", b, sys.send_state);
    else
        $display("fault block %0d arrived despite the fault (self-healed)", b);
end
endtask

// the main task's get_core_id(): 0x01, then the reply within 200 ms (scaled: 5 ms; it may wait out a block frame)
task poll_id;
    integer n0, t;
begin
    n0 = n_id;
    lock; send_hdr(16'd1, 8'h01); unlock;
    t = 0;
    while (n_id == n0 && t < 5000) begin #1000; t = t + 1; end
    if (n_id == n0) begin
        errs = errs + 1;
        $display("FAIL t=%0t: core-ID poll unanswered send_state=%0d sv_idx=%0d sv_data_rdy=%b recv_state=%b sv_req=%b sv_ack=%b paused=%b", $time, sys.send_state, sys.sv_idx, sys.sv_data_rdy, sys.recv_state, sv_req, sv_ack, paused);
    end
end
endtask

// a HID frame (main task, send_hid_state): the core must take it, even when it
// lands while iosys still owes a core-ID reply behind a long block frame
task send_hid(input [15:0] h);
begin
    lock; send_hdr(16'd5, 8'h09); tx_byte(h[15:8]); tx_byte(h[7:0]); tx_byte(0); tx_byte(0); unlock;
    #2000;
    if (sys.hid1 !== h) begin
        errs = errs + 1;
        $display("FAIL t=%0t: HID frame %04x dropped (core has %04x) recv_state=%b", $time, h, sys.hid1, sys.recv_state);
    end
end
endtask

// the player: change the pad, the MCU must see the new state soon
task press(input [11:0] v);
    integer t;
begin
    joy1 = v;
    t = 0;
    while (last_joy1 !== {4'b0, v} && t < 5000) begin #1000; t = t + 1; end
    if (last_joy1 !== {4'b0, v}) begin
        errs = errs + 1;
        $display("FAIL t=%0t: pad %03x never reported (MCU still sees %03x) send_state=%0d",
                 $time, v, last_joy1, sys.send_state);
    end
end
endtask

integer round, b, k;
reg dumping = 0;

// firmware frames the game menu sends: core_config (pause bit 17), overlay
// on/off, cursor + text. The traffic generator's `paused` follows bit 17,
// exactly as nestang_top wires core_config[17] to the NES divider hold.
task send_config(input [31:0] v);
begin
    lock; send_hdr(16'd5, 8'h03);
    tx_byte(v[31:24]); tx_byte(v[23:16]); tx_byte(v[15:8]); tx_byte(v[7:0]);
    unlock;
    paused = v[17];
end
endtask
task send_overlay(input on);
begin
    lock; send_hdr(16'd2, 8'h08); tx_byte(on ? 8'h01 : 8'h00); unlock;
end
endtask
task send_text;
    integer c;
begin
    lock; send_hdr(16'd3, 8'h04); tx_byte(8'd2); tx_byte(8'd5); unlock;
    lock; send_hdr(16'd12, 8'h05);
    for (c = 0; c < 11; c = c + 1) tx_byte(8'h41 + c[7:0]);
    unlock;
end
endtask


initial begin
    // FF power-on state of regs without a reset (Gowin FFs come up 0)
    sys.send_idx = 0; sys.response_req = 0; sys.response_ack = 0;
    sys.joy1_reg = 0; sys.joy2_reg = 0; sys.send_state_next = 0;
    for (k = 0; k < (1<<21); k = k + 1) mem[k] = 16'hxxxx;

    repeat (300) @(posedge clk);
    sys_resetn = 1;
    wait (busy == 0);
    repeat (50) @(posedge clk);

    // load: restore while the core is held (no traffic), like saves_restore()
    restore_all(8'h5A);
    traffic = 1;
    poll_id;
    press(12'h004); press(12'h00C); press(12'h40C); press(12'h000);

    // game running: dumps (the save task) race the main task and the player
    for (round = 0; round < 3; round = round + 1) begin
        dumping = 1;
        fork
            begin
                for (b = 0; b < 16; b = b + 1) fetch(b, 8'h5A, 1);
                dumping = 0;
            end
            begin
                while (dumping) begin poll_id; #(37_000 + round * 11_000); end
            end
            begin
                while (dumping) begin send_hid(16'h0008); #23_000; send_hid(0); #31_000; end
            end
            begin
                while (dumping) begin
                    press(12'h004); #7_000; press(12'h00C); #5_000; press(12'h40C);
                    #60_000; press(12'h000); #40_000;
                end
            end
        join
        // after the dump the controls must still work
        poll_id;
        press(12'h40C); press(12'h000);
        press(12'h80C); press(12'h000);

        // game menu at a random point in the traffic phase: overlay on and
        // pause, a settle dump against the frozen NES, menu text and pad
        // navigation, then resume (the QA4 menu-open sequence). The pause
        // is dropped again at a random point, once mid-dump.
        // freeze the traffic at a different divider phase each round, so
        // oeA/oeB/weA/weB are caught in several held combinations
        wait ((tc % 24) == (round * 3 + 1));
        send_overlay(1);
        send_config(32'h0002_0000);                     // pause
        dumping = 1;
        fork
            begin
                for (b = 0; b < 16; b = b + 1) fetch(b, 8'h5A, 1);
                dumping = 0;
            end
            begin
                while (dumping) begin poll_id; #17_000; end
            end
            begin
                while (dumping) begin send_text; #43_000; end
            end
            begin
                // resume mid-dump in the last round, like an impatient exit
                if (round == 2) begin
                    #90_000;
                    send_config(32'h0);
                    send_overlay(0);
                end
            end
        join
        send_text;
        press(12'h001); press(12'h000);
        press(12'h020); press(12'h000);
        poll_id;
        send_config(32'h0);                             // resume
        send_overlay(0);
        #20_000;
        poll_id;
        press(12'h004); press(12'h000);
    end

    // ---- fault injection: swallow the engine's data-ready for far longer
    // than any real fetch takes (a lost ack toggle inside the handshake).
    // The block in flight may be lost, but the link must carry on: polls
    // answered, pads reported, and later dumps byte-exact again. On the
    // pre-fix iosys this wedges SEND_SAVE_BLK forever and everything
    // after it fails -- the QA4 hardware symptom.
    fork
        begin
            fetch_may_fail(3);
        end
        begin
            wait (sys.send_state == 6 && sys.send_state_next == 10);   // header of a save block
            repeat (40000) @(negedge clk) sys.sv_data_rdy = 1'b0;      // eat every ready
            $display("fault injection over at t=%0t send_state=%0d", $time, sys.send_state);
        end
    join
    poll_id;
    press(12'h004); press(12'h000);
    for (b = 0; b < 16; b = b + 1) fetch(b, 8'h5A, 1);
    poll_id;
    press(12'h40C); press(12'h000);

    $display("tb_link_soak: %0d blocks, %0d id replies, %0d pad frames, %0d dirty notices",
             n_blk, n_id, n_joy, n_dirty);
    if (errs == 0) $display("tb_link_soak: PASS");
    else $fatal(1, "tb_link_soak: FAIL, %0d errors", errs);
    $finish;
end

initial begin
    #2_000_000_000;
    $fatal(1, "tb_link_soak: FAIL, global timeout");
end

endmodule
