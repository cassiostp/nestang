// Build-variant header for the 120 Hz build: 480p120 (VIC 48, 54 MHz pixel
// clock) with runtime BFI modes. The RTL gates every 120 Hz difference on
// `ifdef HZ120; build.tcl points -include_path here when
// TANGCORE_VARIANT=hz120, the benches pass the same directory with -I.
`ifndef HZ120
`define HZ120
`endif
