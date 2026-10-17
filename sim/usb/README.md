# usb_hid_host sims

`src/usb_hid_host.v` (with `src/usb_hid_host_rom.hex`) against a behavioural low-speed
USB HID device. From this directory, `./run.sh [test ...]` (iverilog; see the header of
run.sh). On the host, `prep.sh` takes the original usb_hid_host from git, and run.sh then
also checks that the original fails the scenarios it should.

## The device (`usb_ls_dev.v`)

- Line: NRZI, bit stuffing, SYNC/PID/CRC5/CRC16, EOP, received by a DPLL on its own clock
  (1000 ppm off). Bus reset is SE0 for 4 us. The device suspends after 3 ms of idle J and
  wakes on any other line state.
- Control endpoint: GET_DESCRIPTOR (configuration), SET_ADDRESS, SET_CONFIGURATION,
  SET_IDLE; STALL for anything else. It switches address `addr_delay_us` after the
  SET_ADDRESS status stage and answers the old address until then.
- Tokens to another address, and to EP1 before SET_CONFIGURATION, get no answer.
- Interrupt IN EP1, once configured: a Sipeed-style gamepad (081f:e401: X in byte 0,
  Y in byte 1, buttons in bytes 5 and 6) with an 8-byte report every 10 ms. The boot
  keyboard and boot mouse variants report only changes and NAK in between.
- Knobs: answer delay (`turnaround`), `addr_delay_us`, `cfg_busy_us`, `wake_us`, `fault`
  (EP1 STALL, no answer at all, EP1 NAK), `fault_until_reset`, `miss`, `corrupt_next`.
- `+trace` prints the transactions, and what the host took from each packet.

## Scenarios (`tb_usb_hid_host.v`)

Every scenario fails on phantom buttons: a button the pad did not hold within the last
60 ms.

| test | what happens |
|---|---|
| plug | plug in and use; bus reset >= 50 ms, SET_CONFIGURATION >= 2 ms after the SET_ADDRESS status, host ACK within 16 bit times |
| fastdev, slowdev | the device answers 2 / 7 bit times after the EOP |
| slowaddr | the device takes 2 ms to switch address |
| cfgbusy | SET_CONFIGURATION within 5 ms of the address switch completes, but EP1 NAKs until a bus reset |
| restart | FPGA reload: host held in reset 300 ms while the pad stays configured and suspends |
| restart2 | two reloads, the second half way through setup |
| sleepy | from suspend, the pad needs 15 ms before it sees a bus reset |
| stall, drop | mid-session, EP1 STALLs / the pad stops answering, until a bus reset: buttons clear, the host sets it up again |
| glitch | one poll goes unanswered, then two in a row: no new setup |
| dead | the pad stops answering for 1 s: buttons clear, the host keeps retrying, and finds it again |
| nakpad | the pad NAKs for 2 s: the host keeps polling and does not set it up again |
| kbd | boot keyboard, idle for 2 s (NAKs): not set up again; keys |
| mouse | boot mouse, 4-byte report |
| badcrc | a report with a bad CRC is neither used nor ACKed |
| unplug | unplug with a button held, plug in again |
