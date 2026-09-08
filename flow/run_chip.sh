#!/bin/bash
# FULL-CHIP hardening run: cdriscv_chip (cdriscv_subsys + sg13g2_io pad
# ring) through LibreLane 3's "Chip" flow (selected by meta.flow in
# config_chip.json: pad ring, seal ring, filler, density steps included).
#
# Pass a run tag as $1 (defaults to chip1) and optionally a final step id
# as $2 to stop early, e.g.:
#
#   ./run_chip.sh chipfp1 OpenROAD.PadRing
#
# runs synthesis -> floorplan -> pad ring only, which is the cheap way to
# validate the ring geometry before committing to a full RTL2GDS run.
# The chipfp1 tag is exactly that probe; do not reuse its tag for a full
# run.
cd /foss/designs/cdriscv-32s-10/flow || exit 1
TAG=${1:-chip1}
TO=${2:-}
export PATH=/foss/tools/verilator/bin:/foss/tools/openroad-librelane/bin:/foss/tools/magic/bin:/foss/tools/netgen/bin:/foss/tools/iverilog/bin:/foss/tools/klayout:/foss/tools/bin:$PATH
EXTRA=()
[ -n "$TO" ] && EXTRA+=(--to "$TO")
# Seal ring and density fill are skipped deliberately (ported from
# variant 2, same PDK bugs):
#  - the PDK sealring PCell emits INT32_MIN edge-arm coordinates on all
#    20 layers for EVERY size, and its output crashes the density filler;
#  - the density filler itself OOMs on this ~8.4 mm^2 die.  Both are
#    tapeout-preparation geometry, added post-fix without floorplan
#    impact (PAD_EDGE_SPACING reserves the ring allowance).  See
#    doc/chip.md.
SKIPS=(--skip KLayout.SealRing --skip KLayout.Filler
       --skip KLayout.Density --skip Checker.KLayoutDensity)
librelane --manual-pdk --pdk-root /foss/pdks --run-tag "$TAG" "${EXTRA[@]}" "${SKIPS[@]}" \
          config_chip.json > "librelane_chip_$TAG.log" 2>&1
echo "[$TAG] exited $? at $(date +%H:%M:%S)"
