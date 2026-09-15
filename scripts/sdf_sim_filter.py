#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Prepare the placed netlist's SDF (`make fmax`) for Icarus.  Every
# removal is counted and printed: a silent filter is a silent lie.
#
# 1. INTERCONNECT entries.  Icarus cannot create an intermodpath for
#    an entry whose end is a top-level port bit and follows the failed
#    insertion with a NULL-handle assertion (vvp SIGABRT).  Gate-level
#    simulation therefore runs on cell IOPATH delays and timing checks
#    only; the interconnect delays this removes are the placement
#    estimates OpenSTA analyses in `make fmax` -- verified in the
#    right tool, not here.
# 2. The SRAM macro CELL blocks (V55).  Since the V49 split the flat
#    netlist keeps the macros' hierarchical names as escaped
#    identifiers (\u_dtcm.g_bank[0].u_bank); OpenSTA writes them
#    u_dtcm\.g_bank\[0\]\.u_bank, Icarus splits that on the dots
#    ("Cannot find u_dtcm in scope"), rejects the A_DOUT[0] bit-select
#    port specs, and after eleven errors declares the WHOLE DELAYFILE
#    invalid -- so the run that hit this simulated with no annotation
#    at all and reported only a TIMEOUT.  The macros compile
#    -DFUNCTIONAL (no specify block), so these blocks could never have
#    annotated; dropped whole.
# 3. The header's min::max triples (VOLTAGE 1.200::1.200) have an
#    empty typ field Icarus reports as "Chosen value not defined";
#    written X:X:X.  A CELL left with nothing but an empty (ABSOLUTE)
#    list -- the top-level one, once its wires are gone -- is dropped.
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
MACRO_RE = re.compile(r'\(CELLTYPE\s+"RM_IHPSG13_')
TRIPLE_RE = re.compile(r'^(\s*\((?:VOLTAGE|PROCESS|TEMPERATURE)\s+"?)([^\s":]+)::([^\s")]+)("?\))')
CONTENT = ("(IOPATH ", "(INTERCONNECT ", "(TIMINGCHECK", "(PORT ", "(DEVICE ", "(COND")

ic = macro_cells = macro_lines = empty_cells = hdr = kept = 0
pending, in_cell, depth, depth_at_cell, drop = [], False, 0, 0, False


def settle(g):
    global macro_lines, macro_cells, empty_cells, kept
    if drop:
        macro_lines += len(pending)
    elif not any(any(t in l for t in CONTENT) for l in pending):
        empty_cells += 1
    else:
        for l in pending:
            g.write(l)
        kept += len(pending)
    pending.clear()


with open(src) as f, open(dst, "w") as g:
    for line in f:
        s = line.lstrip()
        if s.startswith("(INTERCONNECT "):
            ic += 1
            continue
        m = TRIPLE_RE.match(line)
        if m and not in_cell:
            line = "%s%s:%s:%s%s\n" % (m.group(1), m.group(2), m.group(2), m.group(3), m.group(4))
            hdr += 1
        opens, closes = line.count("("), line.count(")")
        if s.startswith("(CELL") and not s.startswith("(CELLTYPE"):
            if in_cell:
                settle(g)
            in_cell, drop, depth_at_cell = True, False, depth
            pending.append(line)
            depth += opens - closes
            continue
        if in_cell:
            if MACRO_RE.search(line):
                drop = True
                macro_cells += 1
            pending.append(line)
            depth += opens - closes
            if depth <= depth_at_cell:
                settle(g)
                in_cell = False
            continue
        depth += opens - closes
        g.write(line)
        kept += 1
    if in_cell:
        settle(g)

print("sdf_sim_filter: dropped %d INTERCONNECT entries, %d SRAM macro CELL blocks "
      "(%d lines), %d emptied CELL blocks; rewrote %d header triples; kept %d lines"
      % (ic, macro_cells, macro_lines, empty_cells, hdr, kept))
