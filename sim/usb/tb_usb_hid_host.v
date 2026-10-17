// usb_hid_host against the behavioural low-speed device in usb_ls_dev.v.
// One scenario per run:  vvp tb_usb_hid_host.out +test=<name> [+trace]
// Prints the checks that failed and a final "RESULT <name> PASS|FAIL" line.
`timescale 1ns/1ps

module tb;
    reg clk = 0;
    always #41.6667 clk = ~clk;                     // 12 MHz
    reg rst_n = 0;

    wire dp, dm;
    assign (highz1, weak0) dp = 1'b0;               // 15k pull-downs on the host side
    assign (highz1, weak0) dm = 1'b0;

    wire [1:0] typ;
    wire report, conerr;
    wire [7:0] key_modifiers, key1, key2, key3, key4, mouse_btn;
    wire signed [7:0] mouse_dx, mouse_dy;
    wire [11:0] snes;                               // R L X A RT LT DN UP START SELECT Y B
    wire [63:0] hid_report;

    usb_hid_host host(
        .usbclk(clk), .usbrst_n(rst_n), .usb_dm(dm), .usb_dp(dp),
        .typ(typ), .report(report), .conerr(conerr),
        .key_modifiers(key_modifiers), .key1(key1), .key2(key2), .key3(key3), .key4(key4),
        .mouse_btn(mouse_btn), .mouse_dx(mouse_dx), .mouse_dy(mouse_dy),
        .game_snes(snes), .game_l(), .game_r(), .game_u(), .game_d(),
        .game_a(), .game_b(), .game_x(), .game_y(), .game_sel(), .game_sta(),
        .game_lb(), .game_rb(), .dbg_hid_report(hid_report));

    usb_ls_dev dev(.dp(dp), .dm(dm));

    wire connected = host.ukp.connected;

    localparam B_B = 12'h001, B_Y = 12'h002, B_SEL = 12'h004, B_STA = 12'h008, B_U = 12'h010,
               B_D = 12'h020, B_L = 12'h040, B_R = 12'h080, B_A = 12'h100, B_X = 12'h200,
               B_LB = 12'h400, B_RB = 12'h800;

    // ---- checks
    integer fails = 0;
    reg [8*24-1:0] test;
    task fail(input string msg);
        begin
            fails = fails + 1;
            $display("%9.3f ms  FAIL: %0s", $realtime / 1e6, msg);
        end
    endtask

    task ms(input real n);
        #(n * 1e6);
    endtask

    // the pad: buttons in the SNES layout -> Sipeed report
    reg [11:0] held = 0, held_prev = 0;
    realtime held_t = 0;
    task pad(input [11:0] b);
        begin
            held_prev = held; held = b; held_t = $realtime;
            dev.rpt[0] = b & B_L ? 8'h00 : b & B_R ? 8'hff : 8'h7f;
            dev.rpt[1] = b & B_U ? 8'h00 : b & B_D ? 8'hff : 8'h7f;
            dev.rpt[5] = {|(b & B_Y), |(b & B_B), |(b & B_A), |(b & B_X), 4'hf};
            dev.rpt[6] = {2'b00, |(b & B_STA), |(b & B_SEL), 2'b00, |(b & B_RB), |(b & B_LB)};
        end
    endtask

    // phantom buttons: anything the pad did not hold now or within the last 60 ms
    integer phantoms = 0;
    reg [11:0] phantom_val = 0;
    realtime phantom_t = 0, phantom_len = 0, phantom_start = 0;
    reg in_phantom = 0;
    always @(posedge clk) begin : phantom_check
        reg [11:0] ok;
        ok = held | ($realtime - held_t < 60e6 ? held_prev : 12'h0);
        if (dev.kind == 0 && (snes & ~ok) != 0) begin
            if (!in_phantom) begin
                phantoms = phantoms + 1; phantom_start = $realtime;
                if (phantoms == 1) begin phantom_val = snes; phantom_t = $realtime; end
            end
            in_phantom = 1;
        end else if (in_phantom) begin
            in_phantom = 0;
            if ($realtime - phantom_start > phantom_len) phantom_len = $realtime - phantom_start;
        end
    end

    // bus: contention and the shortest bus reset
    realtime se0_t = 0, min_reset = 1e12;
    reg se0 = 0;
    integer contention = 0;
    always @(dp or dm) begin
        if (dp === 1'bx || dm === 1'bx) contention = contention + 1;
        if (dp === 1'b0 && dm === 1'b0 && dev.attached) begin
            if (!se0) se0_t = $realtime;
            se0 = 1;
        end else begin
            if (se0 && $realtime - se0_t > 1e6 && $realtime - se0_t < min_reset)
                min_reset = $realtime - se0_t;
            se0 = 0;
        end
    end

    // +trace: what the host took from each packet
    always @(negedge host.ukp.ukprdy)
        if (dev.trace) #1000 $display("%9.3f ms  host: %016x, regs %02x %02x %02x, typ %0d", $realtime / 1e6,
                                      hid_report, host.regs[4], host.regs[5], host.regs[6], typ);

    // ---- helpers
    task wait_connected(input integer max_ms, input [1:0] t);
        integer i;
        begin
            for (i = 0; i < max_ms * 10 && !(connected && typ == t); i = i + 1) #100000;
            if (!(connected && typ == t)) fail($sformatf("not connected as type %0d after %0d ms", t, max_ms));
        end
    endtask

    // the pad presses b; the host must follow within max_ms
    task follow(input [11:0] b, input integer max_ms);
        integer i;
        begin
            pad(b);
            for (i = 0; i < max_ms * 10 && snes !== b; i = i + 1) #100000;
            if (snes !== b) fail($sformatf("buttons %03x, pad holds %03x (%0d ms)", snes, b, max_ms));
        end
    endtask

    task check_buttons_work;
        begin
            follow(B_A, 40); follow(0, 40);
            follow(B_L | B_U | B_STA, 40); follow(0, 40);
        end
    endtask

    // buttons must read 0 within max_ms
    task expect_released(input integer max_ms);
        integer i;
        begin
            for (i = 0; i < max_ms * 10 && snes != 0; i = i + 1) #100000;
            if (snes != 0) fail($sformatf("buttons stuck at %03x %0d ms after the pad stopped answering", snes, max_ms));
        end
    endtask

    task plug_in;
        begin
            ms(1); rst_n = 1;
            ms(5); dev.attached = 1;
            wait_connected(1000, dev.kind == 1 ? 1 : dev.kind == 2 ? 2 : 3);
        end
    endtask

    integer r0, i;
    realtime t0;
    initial begin
        if (!$value$plusargs("test=%s", test)) test = "plug";
        if ($test$plusargs("trace")) dev.trace = 1;
        if ($value$plusargs("ta=%d", i)) dev.turnaround = i;     // device answer delay, bit times
        if ($test$plusargs("vcd")) begin $dumpfile("usb.vcd"); $dumpvars(0, tb); end
        pad(0);

        case (test)
        "plug": begin                       // plug in, use, check the spec timings
            plug_in;
            check_buttons_work;
            ms(100);
            if (min_reset < 50e6) fail($sformatf("bus reset %0.1f ms, need 50", min_reset / 1e6));
            if (dev.t_cfg_setup - dev.t_addr_ack < 2e6)
                fail($sformatf("SET_CONFIGURATION %0.3f ms after the SET_ADDRESS status, need 2",
                               (dev.t_cfg_setup - dev.t_addr_ack) / 1e6));
            $display("bus reset %0.1f ms, SET_ADDRESS status -> SET_CONFIGURATION %0.3f ms, host ACK within %0d bit times",
                     min_reset / 1e6, (dev.t_cfg_setup - dev.t_addr_ack) / 1e6, dev.max_ack_bits);
            if (dev.max_ack_bits > 16) fail("host ACK later than 16 bit times");
        end
        "fastdev", "slowdev": begin         // answers 2 / 7 bit times after the EOP (spec: 2 to 7.5)
            dev.turnaround = test == "fastdev" ? 2 : 7;
            plug_in;
            check_buttons_work;
        end
        "slowaddr": begin                   // the pad takes the full 2 ms to switch address
            dev.addr_delay_us = 2000;
            plug_in;
            check_buttons_work;
        end
        "cfgbusy": begin                    // SET_CONFIGURATION too soon after the address switch:
            dev.cfg_busy_us = 5000;         // completes, but EP1 NAKs until a bus reset
            plug_in;
            check_buttons_work;
        end
        "restart": begin                    // FPGA reload: the pad stays powered and suspends
            plug_in;
            check_buttons_work;
            r0 = dev.n_resets;
            rst_n = 0; ms(300);
            if (!dev.suspended || !dev.configured) fail("pad not configured and suspended during the reload");
            rst_n = 1;
            wait_connected(1000, 3);
            check_buttons_work;
            if (dev.n_resets == r0) fail("pad never saw a bus reset");
        end
        "restart2": begin                   // MODE restart: flash image starts enumerating, reload again
            plug_in;
            rst_n = 0; ms(300); rst_n = 1;
            wait(dev.addr == 1 && !dev.configured);     // half way through setup
            ms(0.5);
            rst_n = 0; ms(300); rst_n = 1;
            wait_connected(1000, 3);
            check_buttons_work;
        end
        "sleepy": begin                     // from suspend the pad needs 15 ms to see a reset
            dev.wake_us = 15000;
            plug_in;
            rst_n = 0; ms(300); rst_n = 1;
            wait_connected(1000, 3);
            check_buttons_work;
        end
        "stall", "drop": begin              // the pad STALLs / stops answering until a bus reset
            plug_in;
            pad(B_A); ms(40);
            r0 = dev.n_resets;
            dev.fault = test == "stall" ? 1 : 2;
            expect_released(100);
            wait_connected(1000, 3);
            if (dev.n_resets == r0) fail("pad never saw a bus reset");
            follow(B_A, 40);
            check_buttons_work;
        end
        "glitch": begin                     // one poll goes unanswered, twice
            plug_in;
            pad(B_A); ms(40);
            r0 = dev.n_resets;
            dev.miss = 1; ms(40);
            dev.miss = 2; ms(40);
            follow(0, 40);
            check_buttons_work;
            if (dev.n_resets != r0) fail("enumerated again after a missed poll");
        end
        "dead": begin                       // the pad stops answering for good, then comes back
            plug_in;
            pad(B_A); ms(40);
            dev.fault_until_reset = 0; dev.fault = 2;
            expect_released(100);
            ms(1000);
            if (connected) fail("still connected to a dead pad");
            dev.fault = 0;
            wait_connected(1000, 3);
            follow(B_A, 40);
            check_buttons_work;
        end
        "nakpad": begin                     // a pad that only reports changes: NAKs for 2 s
            plug_in;
            r0 = dev.n_resets; i = dev.n_ep1_nak;
            dev.fault_until_reset = 0; dev.fault = 3;
            ms(2000);
            if (dev.n_resets != r0) fail("NAKing pad was enumerated again");
            if (dev.n_ep1_nak - i < 150) fail($sformatf("only %0d polls in 2 s", dev.n_ep1_nak - i));
            dev.fault = 0;
            check_buttons_work;
        end
        "kbd": begin                        // boot keyboard, reports only changes
            dev.kind = 1;
            for (i = 0; i < 8; i = i + 1) dev.rpt[i] = 0;
            plug_in;
            r0 = dev.n_resets;
            ms(2000);
            if (dev.n_resets != r0) fail("idle keyboard was enumerated again");
            if (key1 != 0 || key_modifiers != 0) fail("key held while idle");
            dev.rpt[0] = 8'h02; dev.rpt[2] = 8'h04;     // shift + a
            ms(40);
            if (key1 != 8'h04 || key_modifiers != 8'h02) fail($sformatf("keys %02x %02x", key_modifiers, key1));
            dev.rpt[0] = 0; dev.rpt[2] = 0;
            ms(40);
            if (key1 != 0 || key_modifiers != 0) fail("key stuck after release");
        end
        "mouse": begin                      // boot mouse, 4-byte reports
            dev.kind = 2;
            for (i = 0; i < 8; i = i + 1) dev.rpt[i] = 0;
            plug_in;
            dev.rpt[0] = 8'h01; dev.rpt[1] = 8'h05; dev.rpt[2] = 8'hfb;
            fork
                begin : wait_report
                    @(posedge report);
                    #1 if (mouse_btn != 1 || mouse_dx != 5 || mouse_dy != -5)
                        fail($sformatf("mouse %02x %0d %0d", mouse_btn, mouse_dx, mouse_dy));
                    @(negedge report);
                    #1 if (mouse_dx != 0 || mouse_dy != 0) fail("mouse movement not cleared");
                end
                begin ms(40); fail("no mouse report"); disable wait_report; end
            join_any
            disable fork;
        end
        "badcrc": begin                     // a report with a bad CRC must not be used
            plug_in;
            ms(30);
            dev.corrupt_next = 1;           // the next report is sent with X flipped on
            ms(40);
            check_buttons_work;
        end
        "unplug": begin
            plug_in;
            pad(B_A); ms(40);
            dev.attached = 0;
            ms(1500);
            if (typ != 0 || connected) fail("unplugged pad still connected");
            if (snes != 0) fail("buttons held after unplug");
            pad(0);
            dev.attached = 1;
            wait_connected(1000, 3);
            check_buttons_work;
        end
        default: begin $display("unknown test %0s", test); $finish; end
        endcase

        if (phantoms) fail($sformatf("%0d phantom button reading(s), first %03x at %0.3f ms, longest %0.3f ms",
                                     phantoms, phantom_val, phantom_t / 1e6, phantom_len / 1e6));
        if (contention) fail("bus contention");
        if (dev.trace) $display("host: pc %03x, ROM %x, watchdog %0d", host.ukp.pc,
                                host.ukp.inst, host.ukp.conct);
        $display("RESULT %0s %0s  (bus resets %0d, configs %0d, reports %0d, bad packets %0d, %0.0f ms)",
                 test, fails ? "FAIL" : "PASS", dev.n_resets, dev.n_configs, dev.n_ep1_data,
                 dev.n_bad_rx, $realtime / 1e6);
        $finish;
    end
endmodule
