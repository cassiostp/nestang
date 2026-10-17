#!/bin/sh
# usb_hid_host sims (iverilog). From this directory:  ./run.sh [test ...]
# Every scenario of tb_usb_hid_host.v against src/usb_hid_host.v must pass. With the
# original from prep.sh (git, on the host) the scenarios in ORIG_FAIL must fail.
# Logs in build/fix/<test>.log and build/orig/<test>.log; +trace in a log: TRACE=1.
set -e
cd "$(dirname "$0")"
RTL=../../src
TESTS=${*:-"plug fastdev slowdev slowaddr cfgbusy restart restart2 sleepy stall drop glitch dead nakpad kbd mouse badcrc unplug"}
ORIG_FAIL="plug fastdev slowaddr cfgbusy sleepy stall drop glitch dead badcrc"
JOBS=${JOBS:-8}
if command -v git >/dev/null 2>&1; then sh prep.sh; fi

mkdir -p build/fix
cp $RTL/usb_hid_host_rom.hex build/fix/
iverilog -g2012 -o build/fix/tb.out tb_usb_hid_host.v usb_ls_dev.v $RTL/usb_hid_host.v
if [ -f build/orig/usb_hid_host.v ]; then
    iverilog -g2012 -o build/orig/tb.out tb_usb_hid_host.v usb_ls_dev.v build/orig/usb_hid_host.v
    VERS="fix orig"
else
    echo "NOTE: no build/orig (run prep.sh on the host), only the fixed host is simulated"
    VERS=fix
fi

for v in $VERS; do
    for t in $TESTS; do echo "$v $t"; done
done | xargs -P "$JOBS" -n 2 sh -c \
    'cd build/$0 && vvp -n tb.out +test=$1 ${TRACE:++trace} > $1.log 2>&1; grep "^RESULT" $1.log || echo "RESULT $1 ERROR"' \
    > build/results.txt

st=0
echo "== fixed"
for t in $TESTS; do
    grep -h "^RESULT $t " build/fix/$t.log || { echo "RESULT $t ERROR"; st=1; continue; }
    grep -q "^RESULT $t PASS" build/fix/$t.log || { grep "FAIL:" build/fix/$t.log; st=1; }
done
if [ "$VERS" != fix ]; then
    echo "== original"
    for t in $TESTS; do
        grep -h "^RESULT $t " build/orig/$t.log || { echo "RESULT $t ERROR"; st=1; continue; }
        grep "FAIL:" build/orig/$t.log | sed 's/^/    /' || true
        case " $ORIG_FAIL " in *" $t "*)
            grep -q "^RESULT $t FAIL" build/orig/$t.log || { echo "    expected the original to fail $t"; st=1; } ;;
        esac
    done
fi
[ $st = 0 ] && echo "usb sims: OK" || echo "usb sims: FAILED"
exit $st
