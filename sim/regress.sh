#!/bin/sh
# Run the catalog with Python 3; defaults: quick, both variants.
# REGRESS_JOBS=1 reserves one of the two bench slots for another simulation.
set -eu
exec python3 "$(dirname "$0")/regress.py" "$@"
