#include "Vsoak_top.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <stdexcept>
#include <string>
#include <vector>

#ifndef CLK_HZ
#define CLK_HZ 21505376ULL
#endif
static constexpr uint64_t HZ = CLK_HZ, BAUD = 2000000;

struct Soak {
    Vsoak_top d;
    uint64_t cycle = 0, tx_count = 0, rx_count = 0, frames = 0, aa_payloads = 0;
    std::array<uint64_t, 256> types{};
    std::array<uint8_t, 8192> ram{};
    std::deque<uint8_t> input, expected_rx, expected_tx;
    std::vector<uint8_t> frame;
    uint64_t in_phase = 0, out_start = 0, fault_until = 0;
    int in_bit = -1, out_bit = -1, mem_wait = 0;
    uint8_t in_byte = 0, out_byte = 0;
    bool prev_tx = true, ack_pending = false, fault = false, injected = false;
    uint16_t blk = 0, pending_addr = 0;
    uint8_t pending_data = 0;
    bool pending_we = false, pending_level = false;
    int saves_left = 0;

    [[noreturn]] void fail(const std::string &s) {
        char p[128];
        snprintf(p, sizeof p, "FAIL cycle=%llu t=%.9fs tx_state=%u sv_idx=%u: ",
                 (unsigned long long)cycle, double(cycle)/HZ, d.tx_state, d.sv_idx);
        if (fault) {
            printf("partial frame (%zu bytes):", frame.size());
            for (auto b : frame) printf(" %02x", b);
            printf("\n");
        }
        throw std::runtime_error(std::string(p) + s);
    }
    void command(uint8_t cmd, std::vector<uint8_t> payload = {}) {
        uint16_t len = payload.size() + 1;
        for (uint8_t b : {uint8_t(0xaa), uint8_t(len >> 8), uint8_t(len), cmd}) input.push_back(b);
        for (uint8_t b : payload) input.push_back(b);
    }
    void fetch() { command(0x12, {0, uint8_t(blk)}); }

    void byte(uint8_t b) {
        tx_count++;
        if (expected_tx.empty() || expected_tx.front() != b)
            fail("wire byte differs from UART's accepted-byte stream");
        expected_tx.pop_front();
        if (frame.empty() && b != 0xaa) fail("byte outside frame: " + std::to_string(b));
        frame.push_back(b);
        if (frame.size() < 4) return;
        unsigned len = (frame[1] << 8) | frame[2], type = frame[3];
        unsigned required = type == 1 || type == 11 ? 2 : type == 3 ? 5 : type == 10 ? 515 : type == 2 ? 74 : 0;
        if (!required || len != required)
            fail("invalid frame header len=" + std::to_string(len) + " type=" + std::to_string(type));
        if (frame.size() != len + 3) return;
        if (type == 1 && frame[4] != 1) fail("wrong core ID");
        if (type == 11 && frame[4] != 0) fail("wrong dirty payload");
        if (type == 3 && ((frame[4] | frame[6]) & 0xf0)) fail("invalid joy high bits");
        if (type == 10) {
            unsigned got_blk = (frame[4] << 8) | frame[5];
            if (got_blk != blk) fail("wrong block number");
            for (int i = 0; i < 512; ++i)
                if (frame[6+i] != ram[(blk*512+i)&8191]) fail("wrong save data");
            if (--saves_left > 0) { blk = (blk+1)&15; fetch(); }
        }
        for (unsigned i = 4; i < frame.size(); ++i) aa_payloads += frame[i] == 0xaa;
        types[type]++; frames++;
        frame.clear();
    }

    void step() {
        // MCU sends ideal 2 Mbaud 8N1, independent of the FPGA baud generator.
        if (in_bit < 0 && !input.empty()) {
            in_byte = input.front(); input.pop_front(); expected_rx.push_back(in_byte);
            in_bit = 0; in_phase = 0; d.uart_rx = 0;
        }
        if (in_bit >= 0) {
            in_phase += BAUD;
            if (in_phase >= HZ) {
                in_phase -= HZ;
                if (++in_bit == 10) { in_bit = -1; d.uart_rx = 1; }
                else d.uart_rx = in_bit == 9 ? 1 : (in_byte >> (in_bit-1)) & 1;
            }
        }
        // Bounded SDRAM-like req/ack latency; data stays stable until next read.
        if (!ack_pending && d.sv_req != d.sv_ack) {
            ack_pending = true; mem_wait = 3 + (cycle % 9);
            pending_addr = d.sv_addr; pending_data = d.sv_din;
            pending_we = d.sv_we; pending_level = d.sv_req;
        }
        if (fault && !injected && d.tx_state == 10 && d.sv_idx == 18) {
            injected = true; fault_until = cycle + HZ/500;
            printf("INJECT save acknowledgement delayed 2ms at %.9fs\n", double(cycle)/HZ);
        }
        if (ack_pending && cycle >= fault_until && --mem_wait <= 0) {
            if (pending_we) ram[pending_addr] = pending_data;
            else d.sv_q = ram[pending_addr];
            d.sv_ack = pending_level; ack_pending = false;
        }
        d.clk = 0; d.eval();
        unsigned old_state = d.tx_state;
        bool launch = d.tx_launch, received = d.rx_valid;
        uint8_t launched_byte = d.tx_byte, received_byte = d.rx_byte;
        d.clk = 1; d.eval();
        if (fault && injected && old_state == 10 && d.tx_state == 0)
            printf("ABORT t=%.9fs sv_idx=%u partial_bytes=%zu\n", double(cycle)/HZ,
                   d.sv_idx, frame.size());
        if (d.resetn && launch) expected_tx.push_back(launched_byte);
        if (d.resetn && received) {
            if (expected_rx.empty() || expected_rx.front() != received_byte)
                fail("FPGA decoded wrong MCU byte");
            expected_rx.pop_front(); rx_count++;
        }
        bool tx = d.uart_tx;
        // Strict independent 8N2 UART decoder, including both stop bits.
        if (out_bit < 0 && prev_tx && !tx) { out_start = cycle; out_bit = 0; out_byte = 0; }
        if (out_bit >= 0 && (cycle - out_start)*2*BAUD >= (uint64_t(2*out_bit)+1)*HZ) {
            if (out_bit == 0 && tx) fail("short start bit");
            if (out_bit >= 1 && out_bit <= 8) out_byte |= uint8_t(tx) << (out_bit-1);
            if (out_bit >= 9 && !tx) fail("bad stop bit");
            if (++out_bit == 11) { out_bit = -1; byte(out_byte); }
        }
        prev_tx = tx;
        cycle++;
    }

    void run(unsigned seconds, bool do_fault, bool dense, bool idle) {
        fault = do_fault;
        d.clk=0; d.resetn=0; d.uart_rx=1; d.sv_ack=0; d.sv_q=0;
        d.joy1=0; d.joy2=0; d.core_we=0;
        for (unsigned i=0; i<ram.size(); ++i) ram[i] = uint8_t(i*37 + (i>>8));
        for (int i=0; i<100; ++i) step();
        d.resetn=1;
        if (!idle) {
            command(6, {1});
            for (unsigned b=0; b<16; ++b) {
                std::vector<uint8_t> p{0,uint8_t(b)};
                for (unsigned i=0; i<512; ++i) p.push_back(uint8_t((b*512+i)*37 + ((b*512+i)>>8)));
                command(0x11,p);
            }
            command(6, {0}); command(2);
        }
        uint64_t end = cycle + seconds*HZ, next_poll = cycle+1000;
        uint64_t next_joy = cycle+500, next_menu = cycle+HZ/10, next_save = cycle+HZ/5;
        uint64_t next_dirty = cycle+HZ/8;
        uint32_t joy_n=0, menu_n=0;
        while (cycle < end) {
            if (cycle == next_poll) {
                command(1); next_poll += dense ? HZ/2000 : HZ/4;
            }
            if (cycle == next_joy) {
                // Exhaustive low-byte payload sweep, including 0xAA on both pads.
                d.joy1 = (joy_n & 255) | ((joy_n & 1) << 8);
                d.joy2 = ((joy_n+170)&255) | (((joy_n>>1)&1) << 9);
                joy_n++; next_joy += dense ? 1009 : 1000001;
            }
            if (cycle == next_menu) {
                bool open = (++menu_n & 1);
                command(3, {0, uint8_t(open ? 2 : 0), 0, 0}); command(8, {uint8_t(open)});
                command(4, {18, 12}); command(5, {'S','o','a','k',' ',0xaa,' ',uint8_t(menu_n)});
                command(9, {0x04,0x0c,0,0}); command(0x13, {0,0,0,0});
                if (dense && menu_n % 10 == 0) {
                    std::vector<uint8_t> data;
                    for (unsigned i=0; i<256; ++i) data.push_back(i);
                    command(7,data);
                }
                next_menu += dense ? HZ/1000 : HZ/2;
            }
            if (!idle && cycle == next_dirty) { d.core_we=1; next_dirty += dense ? HZ/500 : HZ/3; }
            else d.core_we=0;
            if (!idle && cycle == next_save) {
                if (!saves_left) { blk=0; saves_left = dense ? 16 : 4; fetch(); }
                next_save += dense ? HZ/20 : HZ;
            }
            step();
            if (cycle % (HZ*10) == 0) {
                printf("progress %.0fs frames=%llu bytes=%llu\n", double(cycle)/HZ,
                       (unsigned long long)frames, (unsigned long long)tx_count); fflush(stdout);
            }
        }
        for (uint64_t i=0; i<HZ/5; ++i) step();
        if (!expected_rx.empty() || !expected_tx.empty() || !frame.empty() || !input.empty()) fail("unfinished stream");
        printf("PASS seconds=%u dense=%u idle=%u freq=%llu frames=%llu bytes=%llu rx=%llu id=%llu joy=%llu save=%llu dirty=%llu payload_AA=%llu\n",
               seconds, dense, idle, (unsigned long long)HZ, (unsigned long long)frames,
               (unsigned long long)tx_count, (unsigned long long)rx_count,
               (unsigned long long)types[1], (unsigned long long)types[3],
               (unsigned long long)types[10], (unsigned long long)types[11], (unsigned long long)aa_payloads);
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc,argv);
    unsigned seconds = argc > 1 ? std::stoul(argv[1]) : 120;
    bool fault = argc > 2 && std::string(argv[2]) == "fault";
    bool dense = argc > 2 && std::string(argv[2]) == "dense";
    try { Soak s; s.run(seconds,fault,dense,argc > 2 && std::string(argv[2]) == "idle"); }
    catch (const std::exception &e) { fprintf(stderr,"%s\n",e.what()); return 1; }
}
