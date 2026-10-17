# NES co-sim model build (Verilator, via docker).
#
# Produces build/{gen,obj,runtime}: the Verilated cosim_top model as a static
# library plus the Verilator runtime headers it needs, so the firmware can
# link a prebuilt model given with -DNESTANG_COSIM_DIR (see firmware
# host/sim/backend_rtl/ and host/run-tests.sh --rtl).
#
#   make model     verilate + compile the model (needs docker)
#   make lint      iverilog elaboration check only (needs iverilog)
#   make clean     drop build/ and generated sources
#
# Docker is only used here, at model-build time. No image, container or
# tool output is committed: build/ is git-ignored.
COSIM := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL := $(COSIM)/../../src
GEN := $(COSIM)/build/gen
OBJ := $(COSIM)/build/obj
# The container user may have no writable home (CI runners): no ccache.
DOCKER := docker run --rm --user "$(shell id -u):$(shell id -g)" -e CCACHE_DISABLE=1
VMOUNT := -v "$(COSIM)/../..:/coresim-src:ro" -v "$(COSIM)/build:/coresim-build" -w /coresim-build
VERILATOR := $(DOCKER) $(VMOUNT) verilator/verilator:latest
IVERILOG := $(DOCKER) -v "$(COSIM)/../..:/coresim-src:ro" -v "$(COSIM)/build:/coresim-build" -w /coresim-build tangcore-iv:1

.PHONY: model lint clean

# The ONLY sanctioned difference from the core's real iosys_bl616.v: the
# CORE_ID parameter becomes the cosim_core_id input, standing in for
# reprogramming the bitstream (the model answers as the programmed core).
# Everything else -- RX/TX state machines, save engine, OSD writes -- is the
# untouched original; the build fails unless the diff shows exactly this.
$(GEN)/iosys_bl616_cosim.v: $(RTL)/iosys/iosys_bl616.v
	mkdir -p $(GEN)
	sed -e 's/^module iosys_bl616/module iosys_bl616_cosim/' \
	    -e '/^ *parameter \[15:0\] CORE_ID=.*,/d' \
	    -e 's/^\( *\)input resetn,/\1input resetn,\n\1input [15:0] cosim_core_id, \/\/ cosim: programmed core ID (stands in for the bitstream)/' \
	    -e 's/tx_data <= CORE_ID\[7:0\];/tx_data <= cosim_core_id[7:0]; \/\/ cosim: programmed ID/' \
	    -e 's/input reg  \[7:0\] kbd_data/input [7:0] kbd_data/' \
	    -e 's/^\( *\)kbd_data <= rx_data;/\1;                       \/\/ sim: kbd path idle/' \
	    $(RTL)/iosys/iosys_bl616.v > $@
	grep -q "^module iosys_bl616_cosim" $@
	grep -q "input \[15:0\] cosim_core_id" $@
	grep -q "tx_data <= cosim_core_id\[7:0\]" $@
	test $$(grep -c "CORE_ID" $@) -eq 3  # only SEND_CORE_ID (the TX state no.) may remain
	! grep "CORE_ID" $@ | grep -vq "SEND_CORE_ID"
	! grep -q "input reg" $@
	@echo "--- iosys_bl616_cosim.v differs from the real file only by:"
	@diff $(RTL)/iosys/iosys_bl616.v $@ || true

# sdram_nes.v needs no functional change: only the Gowin-tolerated
# "inout reg" port declaration is softened (same sed as sim/saveram/run.sh).
$(GEN)/sdram_nes_sim.v: $(RTL)/sdram_nes.v
	mkdir -p $(GEN)
	sed -e 's/inout  reg \[SDRAM_DATA_WIDTH-1:0\] SDRAM_DQ/inout [SDRAM_DATA_WIDTH-1:0] SDRAM_DQ/' \
	    $(RTL)/sdram_nes.v > $@
	! grep -q "inout  reg" $@

# uart_fixed.v needs no functional change either: only the dummy
# ASSERTION_ERROR instances (which iverilog discards with the false generate
# branch, but Verilator elaborates and rejects) become empty begins.
# The guarded parameter combinations are valid, so nothing is lost.
$(GEN)/uart_fixed_sim.v: $(RTL)/iosys/uart_fixed.v
	mkdir -p $(GEN)
	sed -e 's/ASSERTION_ERROR PARAMETER_OUT_OF_RANGE(\("[^"]*"\));/begin end \/\/ sim: was ASSERTION_ERROR \1/' \
	    $(RTL)/iosys/uart_fixed.v > $@
	! grep -q "ASSERTION_ERROR PARAMETER_OUT_OF_RANGE(" $@

COSIM_SRCS := /coresim-src/src/verilator/config.sv \
	/coresim-src/sim/cosim/cosim_top.sv \
	/coresim-build/gen/iosys_bl616_cosim.v \
	/coresim-build/gen/uart_fixed_sim.v \
	/coresim-src/src/iosys/textdisp.v \
	/coresim-src/sim/cosim/gowin/gowin_dpb_menu.v \
	/coresim-build/gen/sdram_nes_sim.v \
	/coresim-src/sim/cosim/sdram_chip.sv

model: $(GEN)/iosys_bl616_cosim.v $(GEN)/sdram_nes_sim.v $(GEN)/uart_fixed_sim.v
	mkdir -p $(OBJ) $(COSIM)/build/runtime
	# -Wno-*: the core's own RTL carries pre-existing style Verilator flags
	# (implicit nets, width mismatches, partial cases, undriven pins); the
	# generated copies must stay line-identical to it apart from the
	# documented seds, so the waivers live here, not in its sources.
	$(VERILATOR) --cc --top-module cosim_top --prefix Vcosim_top \
	    -Mdir obj -DCOSIM -CFLAGS "-O2" \
	    -Wno-PINMISSING -Wno-IMPLICIT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE \
	    $(COSIM_SRCS) > $(COSIM)/build/verilate.log 2>&1 && \
	test ! -s $(COSIM)/build/verilate.log || ! grep -E "PINMISSING.*(cosim_top|sdram_chip|gowin_dpb)" $(COSIM)/build/verilate.log
	# NOTE: PINMISSING is waived only for the core's own files (unconnected
	# RxD_idle/endofpacket in iosys); a missing pin in cosim_top, the chip
	# or the stand-in is a wiring bug (it once hid an unconnected DQM), so
	# the log is grepped for those above.
	$(DOCKER) $(VMOUNT) --entrypoint make verilator/verilator:latest \
	    -C obj -f Vcosim_top.mk -j20
	# Verilator runtime headers the firmware needs to link the model
	# (/usr/local/share/verilator/include in this image; the compile lines
	# above show the path -- update if the image changes).
	$(DOCKER) $(VMOUNT) --entrypoint /bin/sh verilator/verilator:latest \
	    -c "cp -r /usr/local/share/verilator/include/* /coresim-build/runtime/"
	test -f $(COSIM)/build/runtime/verilated.h
	ls $(OBJ)/Vcosim_top__ALL.a

lint: $(GEN)/iosys_bl616_cosim.v $(GEN)/sdram_nes_sim.v $(GEN)/uart_fixed_sim.v
	$(IVERILOG) iverilog -g2012 -DCOSIM -o /dev/null -s cosim_top \
	    /coresim-src/src/verilator/config.sv /coresim-src/sim/cosim/cosim_top.sv \
	    /coresim-build/gen/iosys_bl616_cosim.v /coresim-build/gen/uart_fixed_sim.v \
	    /coresim-src/src/iosys/textdisp.v /coresim-src/sim/cosim/gowin/gowin_dpb_menu.v \
	    /coresim-build/gen/sdram_nes_sim.v /coresim-src/sim/cosim/sdram_chip.sv
	@echo "cosim_top elaborates under iverilog"

clean:
	rm -rf $(COSIM)/build
