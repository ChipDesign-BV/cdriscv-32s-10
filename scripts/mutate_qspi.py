#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
"""Mutation-validate the QSPI boot loader benches (`block-qspi`, `make bootsim`).

    python3 scripts/mutate_qspi.py       # from the repository root

Ported from cdriscv-32s-20.  Each mutant is a single, plausible design
error in the loader (rtl/boot/cdriscv_qspi_boot.sv) or its subsystem
integration.  For each mutant the targets are run cheapest first --
block-qspi, then bootsim, then bootsim-fault -- and the mutant is
killed by the FIRST one that fails.  A mutant that survives all is a
hole in the benches, not a pass.  The originals are restored
unconditionally in a finally block.

What each mutant proves the benches can see:

* crc-ignored: the CRC verdict term is deleted from fail_w, so a
  corrupt payload boots.  Scenario 4 (corrupt CRC must fault, never
  release) is the check that owns this.
* magic-ignored: any flash content is accepted as a header.  Scenario 5
  requires a bad magic to fault with ZERO bus writes.
* bounds-dropped: the per-segment TCM range check is forced true, so a
  wild segment would be written.  Scenarios 6/7 require a fault with
  ZERO bus writes.
* retry-cap-dropped: the retry counter comparison is forced false, so
  a persistent failure retries for ever instead of latching boot_fault.
  Scenario 4's fault/verdict checks and its exact CS-session count see
  it.
* release-before-verdict: boot_done is asserted when the payload
  transfer ends, BEFORE the CRC compare.  Scenario 4 requires that a
  corrupt image never releases (done_rises must stay 0).
* quad-ignores-flag: the payload command no longer follows FLAGS[0].
  Scenario 2 checks the flash saw EBh exactly when the flag said so.
* fault-not-sticky: S_FAULT clears boot_fault after one cycle.
  Scenario 4 re-reads boot_fault 1000 cycles after the verdict.
* timeout-dropped: the progress watchdog can never fire, so a bus that
  stops granting hangs the loader for ever.  Scenario 8 (gnt withheld)
  requires a bounded fault, and its wait is finite.
* flt-boot-not-routed (cdriscv-32s-10 specific): fault_int[FLT_BOOT]
  is severed in cdriscv_subsys, so a failed boot never reaches the
  safety controller and err_pin stays low.  bootsim-fault requires
  err_pin high after a corrupt image.  (cdriscv-32s-20 surfaced
  boot_fault as an ungated err_pin OR plus a STATUS2 register; this
  variant had FLT bit 14 spare, so the routing goes the normal way and
  this is the mutant that guards it.)

A surviving mutant is a claim about the bench, so first be sure the
mutant is a real change (the anchor must be unique in the file).
"""
import subprocess, sys, os

BOOT = 'rtl/boot/cdriscv_qspi_boot.sv'
SUBSYS = 'rtl/cdriscv_subsys.sv'

MUTANTS = [
 (SUBSYS,
  "    fault_int[FLT_BOOT]          = boot_fault;",
  "    fault_int[FLT_BOOT]          = 1'b0;",
  "boot fault not routed into the safety controller (FLT_BOOT severed)",
  "bootsim-fault"),
 (BOOT, "      ((state_q == S_CRC) && (crc_calc_w != hdr_crc_w)) ||\n",
        "",
        "boot: CRC check ignored (verdict term deleted from fail_w)"),
 (BOOT, "assign hdr_magic_ok_w = (hdr_magic_w == BootMagic);",
        "assign hdr_magic_ok_w = 1'b1;",
        "boot: magic check ignored"),
 (BOOT, "assign seg_bounds_ok_w = seg0_ok_w && seg1_ok_w;",
        "assign seg_bounds_ok_w = 1'b1;",
        "boot: segment bounds check dropped"),
 (BOOT, "if (retries_q >= 4'(RetryMax)) begin",
        "if (1'b0) begin",
        "boot: retry cap dropped (retries for ever, never faults)"),
 (BOOT, """            else begin
              phase_q <= P_NONE;
              state_q <= S_CRC;
            end""",
        """            else begin
              phase_q <= P_NONE;
              state_q <= S_CRC;
              boot_done_q <= 1'b1;
            end""",
        "boot: fetch released before the CRC verdict"),
 (BOOT, "assign use_quad_w     = hdr_flags_w[0];",
        "assign use_quad_w     = 1'b0;",
        "boot: quad switch ignores the header flag"),
 (BOOT, "        S_FAULT: state_q <= S_FAULT;",
        "        S_FAULT: begin state_q <= S_FAULT; boot_fault_q <= 1'b0; end",
        "boot: boot_fault not sticky (one-cycle pulse)"),
 (BOOT, "assign timeout_w = (wdog_q >= 32'(TimeoutCycles));",
        "assign timeout_w = 1'b0;",
        "boot: progress watchdog disabled (timeout never fires)"),
]

# Cheapest first; a mutant is killed by the first failing target.
TARGETS = ['block-qspi', 'bootsim', 'bootsim-fault']

ENV = dict(os.environ)
ENV['PATH'] = ('/foss/tools/iverilog/bin:/foss/tools/verilator/bin:'
               '/foss/tools/riscv-gnu-toolchain/bin:/foss/tools/yosys/bin:'
               + ENV['PATH'])


def run(target):
    r = subprocess.run(['make', target],
                       capture_output=True, text=True, timeout=1200, env=ENV)
    return r.returncode


orig = {f: open(f).read() for f in {m[0] for m in MUTANTS} | {BOOT}}
killed, survived = [], []
try:
    # the unmutated design must pass, or nothing below means anything
    for t in TARGETS:
        if run(t) != 0:
            print("BASELINE FAILS on %s -- aborting" % t); sys.exit(2)
    print("baseline passes\n")

    for m in MUTANTS:
        f, old, new, desc = m[0], m[1], m[2], m[3]
        # optional 5th element: the one target that can see this mutant
        # -- tried first, then the rest as usual
        mut_targets = ([m[4]] + [t for t in TARGETS if t != m[4]]) if len(m) > 4 else TARGETS
        s = orig[f]
        if s.count(old) != 1:
            print(f"SKIP (anchor not unique): {desc}"); survived.append(desc + " [ANCHOR]")
            continue
        open(f, 'w').write(s.replace(old, new, 1))
        killer = None
        for t in mut_targets:
            if run(t) != 0:
                killer = t
                break
        open(f, 'w').write(orig[f])          # restore straight away
        if killer:
            killed.append(desc);  print(f"killed   {desc}  [{killer}]")
        else:
            survived.append(desc); print(f"SURVIVED {desc}")
finally:
    for f, s in orig.items():
        open(f, 'w').write(s)

print(f"\n{len(killed)}/{len(MUTANTS)} mutants killed")
if survived:
    print("survivors:")
    for d in survived: print("  -", d)
sys.exit(1 if survived else 0)
