#!/bin/sh
# Host-side preparation for run.sh: needs git.
#   build/orig/  usb_hid_host.v and its ROM before the fix ($BASE), to show the failures
set -e
cd "$(dirname "$0")"
BASE=${BASE:-5ab5d15}       # the last commit with the original usb_hid_host
mkdir -p build/orig
git show $BASE:src/usb_hid_host.v > build/orig/usb_hid_host.v
git show $BASE:src/usb_hid_host_rom.hex > build/orig/usb_hid_host_rom.hex
echo "prep: usb_hid_host from $BASE ready"
