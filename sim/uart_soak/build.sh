#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
python3 - <<'PY'
from pathlib import Path
src=Path('../../src/iosys')
s=(src/'iosys_bl616.v').read_text()
s=s.replace('input reg  [7:0] kbd_data', 'input [7:0] kbd_data')
s=s.replace('kbd_data <= rx_data;', '; // sim: keyboard path idle')
Path('build/iosys.v').write_text(s)
s=(src/'uart_fixed.v').read_text()
import re
s=re.sub(r'ASSERTION_ERROR PARAMETER_OUT_OF_RANGE\("[^"]*"\);', 'begin end', s)
Path('build/uart.v').write_text(s)
PY
nice -n 10 docker run --rm --name r6solnes_uart_build --user "$(id -u):$(id -g)" \
    -e CCACHE_DISABLE=1 -v "$PWD:/work" -w /work verilator/verilator:latest \
    --cc --exe --build -j 2 -O3 --top-module soak_top -DSIM \
    -Wno-fatal --Mdir build/obj -CFLAGS '-O3' \
    soak_top.sv build/iosys.v build/uart.v /work/soak.cpp
