# UART stream soak

This bench runs the real `iosys_bl616` and `uart_fixed` at the Console 138K
clock (21,505,376 Hz) without changing the joy timer. An independent C++
2 Mbaud 8N2 decoder checks both stop bits and compares every transmitted
byte with the byte accepted by the UART. A strict frame parser checks
headers, lengths, core ID, joy high bits, dirty notices, block numbers, and
synthetic save data. It does not scan past unexpected bytes to resynchronise.
An independent 8N1 transmitter drives MCU commands; every received byte is
compared with the input stream.

```sh
bash build.sh
nice -n 10 build/obj/Vsoak_top 120         # concurrent saves, pads, polls, menus
nice -n 10 build/obj/Vsoak_top 120 idle    # no ROM, save requests, or dirty strobes
nice -n 10 build/obj/Vsoak_top 3 dense     # much heavier bidirectional traffic
nice -n 10 build/obj/Vsoak_top 1 fault     # expected to fail: delayed save ack
```

The normal scenario changes pads every 1,000,001 clocks (about 46.5 ms),
polls the core every 250 ms, toggles the menu every 500 ms, pulses dirty
every 333 ms, and fetches four consecutive blocks every second. Both pad
low bytes sweep through all 256 values, including `0xAA`. Initial save
restore and a config-string request exercise the receive path too.
The dense scenario polls every 500 us, sends menu/HID/config commands every
1 ms, streams all byte values as synthetic ROM data every 10 ms, and fetches
16-block dumps every 50 ms. All scenarios drain pending traffic for 200 ms
at the end. No game ROMs or game-derived data are used.

The save port is a C++ req/ack RAM model with a bounded 3–11-clock response
delay. `fault` delays one response for 2 ms, exposing the existing
`SV_WAIT_MAX` path that abandons an incomplete frame. Its nonzero exit is a
demonstration of that injected failure, not evidence of a spontaneous
failure on hardware. The real `clk`/`fclk` SDRAM crossing is covered by
`../saveram/run.sh`, including the three `tb_link_soak.PHASE` cases.

`build.sh` uses a uniquely named Docker container and two compiler jobs.
Generated source copies only soften the unused keyboard declaration and
assignment and remove dummy parameter-error instances for Verilator, as
the existing co-sim build does. `SIM` suppresses the text display. This
bench does not model FPGA propagation hazards, metastability, electrical
noise, the BL616 UART peripheral, or FreeRTOS scheduling. Passing it bounds
the RTL investigation; it cannot establish the cause of a hardware stall.
