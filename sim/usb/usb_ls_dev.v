// usb_ls_dev: behavioural low-speed USB HID device for the usb_hid_host sims.
//
// Line level: NRZI, bit stuffing, SYNC/PID/CRC5/CRC16, EOP, sampled by a DPLL at
// OVS x 1.5 Mb/s on its own clock (CLK_PPM off nominal). Bus reset (SE0 >= 4 us),
// suspend after 3 ms of idle J, wake on any non-idle signalling.
//
// Protocol: a real device's control endpoint (GET_DESCRIPTOR, SET_ADDRESS,
// SET_CONFIGURATION, SET_IDLE), real addressing, the address switch after the
// SET_ADDRESS status stage (addr_delay_us later, answering the old address until then),
// and interrupt IN EP1 when configured. Tokens to another address, or to EP1 when
// not configured, get no answer.
//
// The testbench drives the knobs below by hierarchical reference.
`timescale 1ns/1ps

module usb_ls_dev #(
    parameter integer OVS = 8,          // samples per bit
    parameter integer CLK_PPM = 1000    // device clock error
)(
    inout dp, dm
);
    localparam real CLK_NS = 666.6667 / OVS * 1e6 / (1e6 + CLK_PPM);
    localparam [1:0] SE0 = 2'b00, J = 2'b01, K = 2'b10, SE1 = 2'b11;    // {dp, dm}, low speed

    // ---- knobs
    reg attached = 0;               // plugged in and powered
    integer kind = 0;               // 0: Sipeed-style gamepad, 1: boot keyboard, 2: boot mouse
    integer rpt_ms = 10;            // gamepad: a report every rpt_ms; keyboard/mouse: on change only
    integer turnaround = 4;         // bit times between the end of an EOP and our answer (2..7)
    integer addr_delay_us = 0;      // address switch after the SET_ADDRESS status stage
    integer cfg_busy_us = 0;        // SET_CONFIGURATION sooner than this after the address
                                    // switch: status completes, EP1 NAKs until bus reset
    integer wake_us = 0;            // from suspend: time to wake before a reset can be seen
    integer fault = 0;              // 0: none, 1: EP1 STALLs, 2: no answer to anything, 3: EP1 NAKs
    reg fault_until_reset = 1;      // a bus reset clears `fault`
    integer miss = 0;               // ignore the next `miss` packets
    reg corrupt_next = 0;           // flip X (byte 5 bit 4) of the next EP1 report after its CRC
    reg trace = 0;                  // print the transactions
    reg [7:0] rpt [0:7];            // report contents (gamepad: X Y . . . btn btn .)

    // ---- observation
    integer n_resets = 0, n_suspends = 0, n_configs = 0, n_ep1_data = 0, n_ep1_nak = 0;
    integer n_bad_rx = 0;           // packets dropped for a bad CRC, PID or bit stuff
    integer max_ack_bits = 0;       // longest wait for the host's ACK after our data, bit times
    realtime t_addr_ack = 0, t_cfg_setup = 0;  // SET_ADDRESS status ACK, SET_CONFIGURATION SETUP
    reg suspended = 0, configured = 0;
    integer addr = 0;

    // ---- line
    reg clk = 0;
    always #(CLK_NS / 2) clk = ~clk;

    reg oe = 0, tx_dp = 0, tx_dm = 1;
    assign dp = oe ? tx_dp : 1'bz;
    assign dm = oe ? tx_dm : 1'bz;
    assign (pull1, highz0) dm = attached;          // 1.5k pull-up on D-

    wire [1:0] line = {dp === 1'b1, dm === 1'b1};

    // descriptors
    reg [7:0] cfg_desc [0:33];
    reg [7:0] rdesc [0:7];
    initial begin : descs
        integer i;
        reg [8*34-1:0] c;
        c = {72'h09_02_22_00_01_01_00_80_32,        // configuration, 34 bytes, 100 mA
             72'h09_04_00_00_01_03_00_00_00,        // interface 0: HID, subclass/protocol patched below
             72'h09_21_10_01_00_01_22_08_00,        // HID
             56'h07_05_81_03_08_00_0a};             // EP1 IN interrupt, 8 bytes, 10 ms
        for (i = 0; i < 34; i = i + 1) cfg_desc[i] = c[8*(33-i) +: 8];
        for (i = 0; i < 8; i = i + 1) rdesc[i] = 8'h00;
        rpt[0] = 8'h7f; rpt[1] = 8'h7f; rpt[2] = 8'h7f; rpt[3] = 8'h7f;
        rpt[4] = 8'h7f; rpt[5] = 8'h0f; rpt[6] = 8'h00; rpt[7] = 8'h00;
    end

    function [4:0] crc5(input [10:0] v);
        integer i; reg [4:0] c;
        begin
            c = 5'h1f;
            for (i = 0; i < 11; i = i + 1)
                c = (c[0] ^ v[i]) ? (c >> 1) ^ 5'h14 : c >> 1;
            crc5 = c ^ 5'h1f;
        end
    endfunction

    reg [15:0] c16;
    task crc16_add(input [7:0] b);
        integer i;
        for (i = 0; i < 8; i = i + 1)
            c16 = (c16[0] ^ b[i]) ? (c16 >> 1) ^ 16'ha001 : c16 >> 1;
    endtask

    // ---- transmitter: line states, one per bit, then SE0 SE0 J and release
    reg [1:0] tx_lv [0:255];
    integer tx_n = 0, tx_i = 0, tx_ph = 0, tx_wait = -1;
    reg [7:0] txb [0:11];
    reg [1:0] lv;
    integer ones;

    task tx_bit(input b);
        begin
            if (!b) lv = ~lv;
            tx_lv[tx_n] = lv; tx_n = tx_n + 1;
            ones = b ? ones + 1 : 0;
            if (ones == 6) begin lv = ~lv; tx_lv[tx_n] = lv; tx_n = tx_n + 1; ones = 0; end
        end
    endtask

    // send txb[0..n-1] (PID first) after the turnaround
    task tx_packet(input integer n);
        integer i, j;
        begin
            if (trace && n == 1) $display("%9.3f ms  dev -> %0s", $realtime / 1e6, pid_name(txb[0]));
            if (trace && n > 1) $display("%9.3f ms  dev -> %0s %0d bytes", $realtime / 1e6, pid_name(txb[0]), n - 3);
            lv = J; tx_n = 0; ones = 0;
            for (j = 0; j < 8; j = j + 1) tx_bit(j == 7);            // SYNC
            for (i = 0; i < n; i = i + 1)
                for (j = 0; j < 8; j = j + 1) tx_bit(txb[i][j]);
            tx_lv[tx_n] = SE0; tx_lv[tx_n+1] = SE0; tx_lv[tx_n+2] = J;
            tx_n = tx_n + 3;
            // we are called at the first SE0 sample of the host's EOP, mid-bit
            tx_wait = (OVS * 3) / 2 + turnaround * OVS;
            tx_i = 0; tx_ph = 0;
        end
    endtask

    function [8*5-1:0] pid_name(input [7:0] pid);
        case (pid)
        8'h2d: pid_name = "SETUP"; 8'h69: pid_name = "IN"; 8'he1: pid_name = "OUT";
        8'hc3: pid_name = "DATA0"; 8'h4b: pid_name = "DATA1"; 8'hd2: pid_name = "ACK";
        8'h5a: pid_name = "NAK"; 8'h1e: pid_name = "STALL"; default: pid_name = "?";
        endcase
    endfunction

    task tx_hs(input [7:0] pid);
        begin txb[0] = pid; tx_packet(1); end
    endtask

    task tx_data(input [7:0] pid, input integer n, input bad_crc);    // data in txb[1..n]
        integer i;
        begin
            txb[0] = pid; c16 = 16'hffff;
            for (i = 1; i <= n; i = i + 1) crc16_add(txb[i]);
            c16 = c16 ^ 16'hffff;
            txb[n+1] = c16[7:0]; txb[n+2] = c16[15:8];
            if (bad_crc) txb[6] = txb[6] ^ 8'h10;
            tx_packet(n + 3);
        end
    endtask

    // ---- protocol state
    localparam ST_IDLE = 0, ST_DATA_IN = 1, ST_STATUS_IN = 2, ST_STALL = 3;
    integer stage = ST_IDLE;
    integer ctl_len = 0, ctl_pos = 0, ctl_n = 0;
    reg ctl_tog = 0;
    reg [7:0] ctl_buf [0:63];
    integer act = 0;                // after the status stage: 1 set address, 2 set configuration
    integer new_addr = 0, cfg_val = 0;
    reg ep1_tog = 0, ep1_broken = 0, rpt_ready = 0, rpt_sent_bad = 0;
    // a keyboard or mouse report is sent once per change
    integer expect_ = 0;            // 0 nothing, 1 SETUP data, 2 OUT data, 3 our data's ACK
    integer ack_for = 0;            // 1 ep0 data, 2 ep0 status, 3 ep1 report
    integer ack_t = 0;              // clocks since our last EOP
    integer rx_start_t = 0;         // ack_t when the packet being received started
    integer addr_t = -1;            // clocks until the address switch
    integer since_addr = 0;         // clocks since the address switch
    integer rpt_t = 0;
    reg [7:0] last_rpt [0:7];
    integer i_;

    task bus_reset;
        begin
            if (trace) $display("%9.3f ms  dev: bus reset", $realtime / 1e6);
            n_resets = n_resets + 1;
            addr = 0; addr_t = -1; configured = 0; ep1_broken = 0; ep1_tog = 0;
            stage = ST_IDLE; expect_ = 0; act = 0; rpt_ready = 0; rpt_t = 0;
            since_addr = 0;
            if (fault_until_reset) fault = 0;
        end
    endtask

    task setup_req(input [7:0] rt, input [7:0] rq, input [15:0] wv, input [15:0] wl);
        integer i;
        begin
            stage = ST_STALL; act = 0;
            if (rt == 8'h80 && rq == 8'h06 && wv[15:8] == 8'h02) begin    // GET_DESCRIPTOR config
                for (i = 0; i < 34; i = i + 1) ctl_buf[i] = cfg_desc[i];
                ctl_buf[9+6] = kind == 0 ? 8'h00 : 8'h01;          // bInterfaceSubClass
                ctl_buf[9+7] = kind;                                // bInterfaceProtocol
                ctl_len = wl < 34 ? wl : 34; ctl_pos = 0; ctl_tog = 1;
                stage = ST_DATA_IN;
            end else if (rt == 8'h00 && rq == 8'h05) begin                 // SET_ADDRESS
                new_addr = wv[6:0]; act = 1; stage = ST_STATUS_IN;
            end else if (rt == 8'h00 && rq == 8'h09) begin                 // SET_CONFIGURATION
                cfg_val = wv[7:0]; act = 2; stage = ST_STATUS_IN; t_cfg_setup = $realtime;
            end else if (rt == 8'h21 && rq == 8'h0a) begin                 // SET_IDLE
                stage = ST_STATUS_IN;
            end
        end
    endtask

    // ---- receiver
    reg [1:0] ls = J, ls_d = J, prev;
    integer ph = 0, rx_ones = 0, nbit = 0, np = 0, se0_t = 0, j_t = 0, wake_t = 0;
    reg rx_on = 0, rx_bad = 0, reset_seen = 0, waking = 0;
    reg [7:0] sh;
    reg [7:0] pkt [0:15];

    task rx_packet;
        reg [7:0] pid;
        reg [6:0] ta;
        reg [3:0] te;
        integer i, n;
        begin
            pid = pkt[1];
            if (np < 2 || pkt[0] != 8'h80 || pid[7:4] != ~pid[3:0]) begin
                n_bad_rx = n_bad_rx + 1;
            end else if (miss > 0) begin
                miss = miss - 1;
                if (trace) $display("%9.3f ms  dev <- %0s, missed", $realtime / 1e6, pid_name(pid));
            end else if (fault == 2) begin
                if (trace) $display("%9.3f ms  dev <- %0s, deaf", $realtime / 1e6, pid_name(pid));
            end else if (pid == 8'h2d || pid == 8'h69 || pid == 8'he1) begin      // token
                ta = pkt[2][6:0]; te = {pkt[3][2:0], pkt[2][7]};
                if (trace) $display("%9.3f ms  dev <- %0s(%0d,%0d)%0s", $realtime / 1e6, pid_name(pid),
                                    ta, te, ta == addr ? "" : ", not for us");
                if (np != 4 || crc5({pkt[3][2:0], pkt[2]}) != pkt[3][7:3])
                    n_bad_rx = n_bad_rx + 1;
                else if (ta == addr) begin
                    expect_ = 0;            // a missing ACK: whatever we sent is sent again
                    if (pid == 8'h2d && te == 0) expect_ = 1;
                    else if (pid == 8'he1 && te == 0) expect_ = 2;
                    else if (pid == 8'h69 && te == 0) begin
                        if (stage == ST_DATA_IN) begin
                            n = ctl_len - ctl_pos > 8 ? 8 : ctl_len - ctl_pos;
                            for (i = 0; i < n; i = i + 1) txb[1+i] = ctl_buf[ctl_pos+i];
                            ctl_n = n;
                            tx_data(ctl_tog ? 8'h4b : 8'hc3, n, 0);
                            expect_ = 3; ack_for = 1;
                        end else if (stage == ST_STATUS_IN) begin
                            tx_data(8'h4b, 0, 0);
                            expect_ = 3; ack_for = 2;
                        end else if (stage == ST_STALL) tx_hs(8'h1e);
                        else tx_hs(8'h5a);
                    end else if (pid == 8'h69 && te == 1 && configured) begin
                        if (fault == 1) tx_hs(8'h1e);
                        else if (fault == 3 || ep1_broken || !rpt_ready) begin
                            tx_hs(8'h5a); n_ep1_nak = n_ep1_nak + 1;
                        end else begin
                            for (i = 0; i < 8; i = i + 1) txb[1+i] = last_rpt[i];
                            tx_data(ep1_tog ? 8'h4b : 8'hc3, kind == 2 ? 4 : 8, corrupt_next);
                            rpt_sent_bad = corrupt_next; corrupt_next = 0;
                            expect_ = 3; ack_for = 3;
                        end
                    end
                end else expect_ = 0;
            end else if (pid == 8'hc3 || pid == 8'h4b) begin                     // data
                c16 = 16'hffff;
                for (i = 2; i < np; i = i + 1) crc16_add(pkt[i]);
                if (trace) $display("%9.3f ms  dev <- %0s %0d bytes: %02x %02x", $realtime / 1e6, pid_name(pid),
                                    np - 4, pkt[2], pkt[3]);
                if (np < 4 || c16 != 16'hb001) begin                           // residual
                    n_bad_rx = n_bad_rx + 1;
                end else if (expect_ == 1 && np == 12 && pid == 8'hc3) begin
                    tx_hs(8'hd2);
                    setup_req(pkt[2], pkt[3], {pkt[5], pkt[4]}, {pkt[9], pkt[8]});
                end else if (expect_ == 2) begin
                    tx_hs(8'hd2);
                    if (stage == ST_DATA_IN) stage = ST_IDLE;      // status of a control read
                end
                expect_ = 0;
            end else if (pid == 8'hd2) begin                                    // ACK
                if (trace) $display("%9.3f ms  dev <- ACK", $realtime / 1e6);
                if (expect_ == 3) begin
                    if (rx_start_t / OVS > max_ack_bits) max_ack_bits = rx_start_t / OVS;
                    if (ack_for == 1) begin ctl_pos = ctl_pos + ctl_n; ctl_tog = ~ctl_tog; end
                    else if (ack_for == 2) begin
                        stage = ST_IDLE;
                        if (act == 1) begin
                            addr_t = addr_delay_us * (OVS * 3) / 2; t_addr_ack = $realtime;
                        end
                        if (act == 2) begin
                            configured = cfg_val != 0; ep1_tog = 0; rpt_t = 0;
                            ep1_broken = since_addr < cfg_busy_us * (OVS * 3) / 2;
                            n_configs = n_configs + 1;
                            if (trace) $display("%9.3f ms  dev: configured%0s", $realtime / 1e6,
                                                ep1_broken ? ", too soon: EP1 NAKs until reset" : "");
                        end
                        act = 0;
                    end else if (ack_for == 3) begin
                        if (!rpt_sent_bad) begin
                            ep1_tog = ~ep1_tog; rpt_ready = 0;
                            n_ep1_data = n_ep1_data + 1;
                        end
                    end
                end
                expect_ = 0;
            end
        end
    endtask

    always @(posedge clk) begin : dev
        reg b;
        ls_d = ls; ls = line;

        if (!attached) begin
            oe = 0; rx_on = 0; suspended = 0; configured = 0; addr = 0; addr_t = -1;
            stage = ST_IDLE; expect_ = 0; j_t = 0; se0_t = 0; tx_wait = -1;
        end else begin
            // transmit
            if (tx_wait == 0) begin
                oe = 1; rx_on = 0;
                {tx_dp, tx_dm} = tx_lv[tx_i];
                tx_ph = tx_ph + 1;
                if (tx_ph == OVS) begin
                    tx_ph = 0; tx_i = tx_i + 1;
                    if (tx_i == tx_n) begin oe = 0; tx_wait = -1; ack_t = 0; end
                end
            end else if (tx_wait > 0) tx_wait = tx_wait - 1;

            // bus state: reset, suspend, wake
            if (oe) begin j_t = 0; se0_t = 0; end
            else begin
                if (ls == J) j_t = j_t + 1; else j_t = 0;
                if (suspended && ls != J && !waking) begin waking = 1; wake_t = 0; end
                if (waking) begin
                    wake_t = wake_t + 1;
                    if (wake_t >= wake_us * (OVS * 3) / 2) begin waking = 0; suspended = 0; end
                end
                if (ls == SE0 && !suspended) se0_t = se0_t + 1; else se0_t = 0;
                if (se0_t == 4 * (OVS * 3) / 2) bus_reset;
                if (j_t == 3000 * (OVS * 3) / 2 && !suspended) begin
                    suspended = 1; n_suspends = n_suspends + 1;
                    if (trace) $display("%9.3f ms  dev: suspend", $realtime / 1e6);
                end
            end
            ack_t = ack_t + 1;
            since_addr = since_addr + 1;
            if (addr_t > 0) addr_t = addr_t - 1;
            else if (addr_t == 0) begin
                addr = new_addr; addr_t = -1; since_addr = 0;
                if (trace) $display("%9.3f ms  dev: now address %0d", $realtime / 1e6, addr);
            end
            if (configured && !suspended) begin
                if (kind == 0) begin                    // a report every rpt_ms
                    rpt_t = rpt_t + 1;
                    if (rpt_t >= rpt_ms * 1000 * (OVS * 3) / 2) begin
                        rpt_t = 0; rpt_ready = 1;
                        for (i_ = 0; i_ < 8; i_ = i_ + 1) last_rpt[i_] = rpt[i_];
                    end
                end else begin                          // a report when it changes
                    b = 0;
                    for (i_ = 0; i_ < 8; i_ = i_ + 1) if (last_rpt[i_] !== rpt[i_]) b = 1;
                    if (b) begin
                        rpt_ready = 1;
                        for (i_ = 0; i_ < 8; i_ = i_ + 1) last_rpt[i_] = rpt[i_];
                    end
                end
            end

            // receive
            ph = (ls != ls_d) ? 0 : (ph + 1) % OVS;
            if (oe || suspended) rx_on = 0;
            else if (!rx_on) begin
                if (ls == K && ls_d == J) begin
                    rx_on = 1; prev = J; rx_ones = 0; nbit = 0; np = 0; rx_bad = 0;
                    rx_start_t = ack_t;
                end
            end else if (ph == OVS / 2 - 1) begin
                if (ls == SE0) begin
                    rx_on = 0;
                    if (rx_bad || nbit != 0) n_bad_rx = n_bad_rx + 1;
                    else rx_packet;
                end else begin
                    b = (ls == prev); prev = ls;
                    if (ls == SE1) rx_bad = 1;
                    if (rx_ones == 6) begin
                        rx_ones = 0;
                        if (b) rx_bad = 1;
                    end else begin
                        rx_ones = b ? rx_ones + 1 : 0;
                        sh = {b, sh[7:1]}; nbit = nbit + 1;
                        if (nbit == 8) begin
                            if (np < 16) pkt[np] = sh;
                            np = np + 1; nbit = 0;
                        end
                    end
                end
            end
        end
    end
endmodule
