#!/bin/bash
# cdriscv-32s-10 subsystem RTL2GDS at 90 % utilisation on the minimal-width
# die (config_u85d.json, V56).  Pass a run tag as $1, optionally a final step
# id as $2 (e.g. OpenROAD.DetailedPlacement) to stop early.
cd /foss/designs/cdriscv-32s-10/flow || exit 1
TAG=${1:-u85d}
TO=${2:-}
export PATH=/foss/tools/verilator/bin:/foss/tools/openroad-librelane/bin:/foss/tools/magic/bin:/foss/tools/netgen/bin:/foss/tools/iverilog/bin:/foss/tools/klayout:/foss/tools/bin:$PATH
EXTRA=()
[ -n "$TO" ] && EXTRA+=(--to "$TO")
librelane --manual-pdk --pdk-root /foss/pdks --run-tag "$TAG" "${EXTRA[@]}" \
          config_u85d.json > "librelane_$TAG.log" 2>&1
echo "[$TAG] exited $? at $(date +%H:%M:%S)" | tee -a "librelane_$TAG.log"
