#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# cdriscv-32s-10 FMEDA computation (verification plan O9).
#
# Everything in this file is one of exactly three kinds of number, and
# each row of the tables says which:
#
#   MEASURED  -- element populations counted from the E2E-inclusive
#                synthesised netlist (build/gate/cdriscv_subsys_fmeda.v,
#                the same netlist with yosys' attributes kept; V55/V56:
#                `python3 scripts/fmeda.py --netlist` re-derives every
#                row from it and fails on drift), and diagnostic
#                coverage from the fault-injection campaigns
#                (verification_findings.md V9/V29/V30/V33/V37, and the
#                V55 re-run on this RTL incl. the E2E sweep).
#   ASSUMED   -- base failure rates.  No foundry FIT data exists for
#                this design; the values are typical published figures
#                for a 130 nm-class process at sea level and are the
#                part a real safety case MUST replace.
#   DERIVED   -- everything computed from the above.
#
# Metrics follow the ISO 26262 definitions:
#   SPFM = 1 - sum(lambda_SPF) / sum(lambda_safety_related)
#   LFM  = 1 - sum(lambda_MPF_latent) / sum(lambda_SR - lambda_SPF)
# A fault is "safe" when it cannot violate the assumed safety goal
# (the campaigns' silent-ok class: correct result, configuration
# intact); a residual/single-point fault is dangerous and undetected;
# a latent multiple-point fault is a disabled mechanism nothing
# reported -- the class V29 measured at 46.4 % and V37 took to zero.

# ----------------------------------------------------------------- ASSUMED
# Soft-error rates, 130 nm-class, sea level, typical literature values.
SEU_SRAM_FIT_PER_MBIT = 700.0    # SRAM cell upsets
SEU_FF_FIT_PER_MBIT   = 400.0    # flip-flop upsets
# Permanent (hard) failures: a round SN 29500-class figure quoted for a
# ~2.6 mm^2 digital die, split over the cell population by count.
#
# It is NOT scaled to this design's 3.353 mm^2 die.  Permanent failure
# rate scales with area, so leaving it here makes the permanent
# contribution optimistic by roughly 3.353/2.6.  It is left unscaled
# deliberately: every rate in this block is a placeholder awaiting
# foundry data, and inventing a scaled number would dress an assumption
# up as a measurement.  A real safety case replaces the whole block.
PERM_FIT_TOTAL        = 20.0
MBIT = 1024.0 * 1024.0

# Fraction of SEU events assumed to upset more than one bit in a word
# (adjacent multi-bit upsets; layout interleaving not yet credited).
MBU_FRACTION = 0.02

# ----------------------------------------------------------------- MEASURED
SRAM_BITS   = 2 * 4096 * 39          # two TCMs, logical bits
NETLIST      = "build/gate/cdriscv_subsys_fmeda.v"  # attributes kept: `make fmeda`
NETLIST_PLAIN = "build/gate/cdriscv_subsys_pd.v"   # what `make fmax` places
TOTAL_FF_NETLIST = 5736               # sg13g2_dfrbpq_1 instances, E2E-inclusive (V55)
TOTAL_FF    = TOTAL_FF_NETLIST        # was 5658 pre-E2E (V44)

# Q-net -> row attribution, first match wins (bit index stripped).  A
# Q-net is named after the RTL register it implements or, where the
# register directly drives a wire of the subsystem, after that wire.
# The rules follow the RTL instance tree of rtl/cdriscv_subsys.sv.
# Two-stage attribution (V56).  Stage 1 matches the flip-flop's Q-net,
# which in a flattened netlist carries the RTL instance path, against the
# rules below.  Stage 2 covers the 536 flops whose net synthesis renamed
# to `_NNNN_`: each one still carries yosys' `src` attribute -- the RTL
# file and line of the register it implements -- and every OTHER flop
# from that same source line has a name, so the line says which row it
# belongs to.  519 of the 536 resolve that way; a line whose named flops
# straddle two different rows (cfg_parity, instantiated in eight blocks)
# and the handful with no src at all stay in the conservative row, which
# is 17 flops rather than 536.
ATTRIBUTION = [
    ("core pair (lockstep)",     r"^g_lockstep\.u_core\.u_core_(main|check)\."),
    ("lockstep delay+compare",   r"^g_lockstep\."),
    ("TCM control+ECC logic",    r"^u_[id]tcm\."),
    ("E2E link endpoints",       r"^u_e2e_"),
    ("safety controller",        r"^(u_safety\.|f_sw$|f_out_en$|inj_tcm_mask$|clkm_fault$)"),
    ("watchdog",                 r"^u_wdog\."),
    ("clock monitor",            r"^u_clkmon\."),
    ("interrupt controller",     r"^u_irq_ctrl"),
    ("timer",                    r"^u_timer\."),
    ("AMS interface",            r"^(u_ams\.|(adc_ch|dac_data|dac_we|atest_en|atest_sel)_o$)"),
    ("memory BIST (x2)",         r"^(u_mbist_[id]\.|[id]bist_)"),
    ("bus + sync + APB glue",    r"."),
]

# Flip-flop populations per functional element, counted from the
# netlist's Q-net names.  "dc_*" are the measured diagnostic coverages:
# dc_seu for single-bit upsets (campaigns), dc_mbu for the multi-bit
# fraction, dc_perm for permanent faults (mechanism-based argument).
# safe_frac is the campaigns' silent-ok share for that element class --
# upsets that provably cannot violate the goal (masked/overwritten).
ELEMENTS = [
    # name,                ffs,  safe, dc_seu, dc_mbu, dc_perm, mechanism
    ("core pair (lockstep)", 3363, 0.45, 0.99,  0.99,  0.99,
     "DCLS compares every output; V9/V37/V55 campaigns: 0 SDC; "
     "residual is the comparator itself and common-mode"),
    ("lockstep delay+compare", 556, 0.10, 0.90,  0.90,  0.90,
     "self-checking by construction (a delay-line upset causes a "
     "mismatch); residual: faults forcing permanent agreement"),
    ("TCM control+ECC logic",   91, 0.30, 0.95,  0.95,  0.95,
     "ECC datapath faults surface as detected errors or bus faults; "
     "BIST covers permanent"),
    ("E2E link endpoints",      91, 0.10, 0.90,  0.90,  0.90,
     "self-evidencing like the comparator: a corrupted held address or "
     "check-bit register mismatches the next beat it qualifies "
     "(block-e2e-link 12 024 checks, mutants 10/10).  The LINK WIRES "
     "they guard were swept (fi-e2e, V55): 400/400 wire-bit transients "
     "detected, 0 silent, 0 SDC, median 4 cycles"),
    ("safety controller",      307, 0.05, 0.999, 0.90,  0.90,
     "config parity (V37: 0 latent / 2600); sticky status is "
     "self-evidencing; residual: reaction wiring"),
    ("watchdog",                 104, 0.05, 0.999, 0.90,  0.90,
     "config parity + timeout is self-revealing (a dead watchdog "
     "fires or never fires -- external pin protocol catches both)"),
    ("clock monitor",          197, 0.10, 0.999, 0.90,  0.85,
     "config parity; ref-domain copies reload each heartbeat (V37)"),
    ("interrupt controller",    97, 0.20, 0.999, 0.90,  0.90,
     "config parity on ENABLE/MODE; pending is dynamic"),
    ("timer",                   162, 0.30, 0.999, 0.90,  0.90,
     "config parity on MTIMECMP/CTRL; mtime dynamic"),
    ("AMS interface",          505, 0.30, 0.999, 0.90,  0.85,
     "config parity incl. limits and mask (V37); results dynamic"),
    ("memory BIST (x2)",       146, 0.60, 0.50,  0.50,  0.70,
     "dormant in mission; faults surface at next BIST run -- "
     "detected late, so counted mostly latent for SEU"),
    ("bus + sync + APB glue",  100, 0.30, 0.90,  0.90,  0.90,
     "APB bridge / bus / reset-sync / output registers: bus errors "
     "trap, reset-sync faults are fail-stop, APB output upsets are "
     "read back by the software mitigation (V30) -- assigned, not "
     "swept"),
    ("unresolved (conservative)", 17, 0.00, 0.50,  0.50,  0.50,
     "the 17 flops of 5 736 (0.30 %) that the netlist cannot place in a "
     "block: 8 from cfg_parity.sv, whose eight instances sit in eight "
     "different blocks, and 9 that carry no src attribute at all.  "
     "Carried with NO safe share and the lowest diagnostic coverage in "
     "the table -- the figure an argued row gets when its argument is "
     "discarded -- because 17 flops cannot move a metric and guessing "
     "would be the only reason to do better"),
    ("registers: core RF",       0, 0.60, 0.99,  0.50,  0.99,
     "parity per word (in core-pair count; kept for the record)"),
]

SRAM = ("TCM arrays (SEC-DED)", SRAM_BITS, 0.40, 0.996, 0.996, 0.996,
        "Hsiao SEC-DED corrects 1, detects 2; campaigns: 0 latent; "
        "March C- BIST at start-up for permanent")

def fit_ff(n):    return n * SEU_FF_FIT_PER_MBIT / MBIT
def fit_sram(n):  return n * SEU_SRAM_FIT_PER_MBIT / MBIT

FF_CELL    = "sg13g2_dfrbpq_1"   # the only sequential cell in the netlist
UNRESOLVED = "unresolved (conservative)"
DOMINANCE  = 0.90               # share of a src line's named flops that fixes its row


def _parse_flops(path):
    """[(src, q-net)] for every flip-flop in the netlist, in file order.
    The `src` attribute is emitted on the line before the cell."""
    import re
    flops, pend, in_ff, cur = [], None, False, None
    with open(path) as f:
        for line in f:
            t = line.strip()
            m = re.match(r'\(\* src = "(.*?)" \*\)', t)
            if m:
                pend = m.group(1)
                continue
            if t.startswith(FF_CELL + " "):
                cur, in_ff, pend = pend, True, None
                continue
            if in_ff and ".Q(" in line:
                q = line.split(".Q(", 1)[1].rsplit(")", 1)[0].strip()
                flops.append((cur, re.sub(r"\[\d+\]", "", q.lstrip("\\").strip())))
                in_ff = False
                continue
            if t.startswith("sg13g2") or t.startswith("RM_"):
                pend = None
    return flops


def _row_of(q, rules):
    for name, rx in rules:
        if rx.search(q):
            return name
    return UNRESOLVED


def count_netlist(path):
    """Per-row flip-flop populations.  Stage 1: the Q-net's instance path.
    Stage 2: for a net synthesis renamed to `_NNNN_`, the row its source
    line's named siblings agree on.  Returns (counts, total, unresolved)."""
    import collections, re
    rules = [(name, re.compile(pat)) for name, pat in ATTRIBUTION]
    renamed = re.compile(r"^_\d+_$")
    flops = _parse_flops(path)

    src_rows = collections.defaultdict(collections.Counter)
    for src, q in flops:
        if src and not renamed.match(q):
            src_rows[src][_row_of(q, rules)] += 1

    counts, unresolved = collections.Counter(), []
    for src, q in flops:
        if not renamed.match(q):
            counts[_row_of(q, rules)] += 1
            continue
        # A source line's named flops may straddle rows when a register
        # drives a port that flattening renamed into an enclosing module's
        # wire -- safety_ctrl.sv:163 has 115 siblings in the safety
        # controller and one that reads as lockstep wiring.  One row
        # holding at least DOMINANCE of them is the register's row; a line
        # genuinely shared between blocks (cfg_parity, instantiated in
        # eight of them) is left in the conservative row rather than
        # guessed at.
        sib = src_rows.get(src)
        if sib:
            row, n = sib.most_common(1)[0]
            if n >= DOMINANCE * sum(sib.values()):
                counts[row] += 1
                continue
        counts[UNRESOLVED] += 1
        unresolved.append((src, len(sib) if sib else 0))
    return counts, len(flops), unresolved


def check_netlist(path):
    """Compare the table against a fresh recount of `path`, and check that
    the attributed netlist is the same netlist the flow places."""
    import collections, os, re
    counts, total, unresolved = count_netlist(path)
    ok = True
    print("recount of %s" % path)
    print("%-28s %8s %8s" % ("element", "table", "netlist"))
    for name, ffs, *_ in ELEMENTS:
        if name == "registers: core RF":
            continue
        flag = "" if counts[name] == ffs else "   <-- DRIFT"
        ok = ok and not flag
        print("%-28s %8d %8d%s" % (name, ffs, counts[name], flag))
    print("%-28s %8d %8d" % ("TOTAL", TOTAL_FF_NETLIST, total))
    if total != TOTAL_FF_NETLIST or sum(counts.values()) != total:
        ok = False
    # the placed netlist must hold exactly the same flops
    if os.path.exists(NETLIST_PLAIN):
        n = sum(1 for l in open(NETLIST_PLAIN) if l.strip().startswith(FF_CELL + " "))
        same = (n == total)
        ok = ok and same
        print("placed netlist %s: %d %s%s"
              % (NETLIST_PLAIN, n, FF_CELL, "" if same else "   <-- DIFFERENT NETLIST"))
    by = collections.Counter(s.split(":")[0].split("/")[-1] if s else "<no src>"
                             for s, _ in unresolved)
    print("unresolved %d flop(s) (%.2f %% of %d): %s"
          % (counts[UNRESOLVED], 100.0 * counts[UNRESOLVED] / max(total, 1), total,
             ", ".join("%s x%d" % (k, v) for k, v in by.most_common()) or "none"))
    print("attributed %d + unresolved %d = %d (netlist %d): %s"
          % (total - counts[UNRESOLVED], counts[UNRESOLVED], sum(counts.values()),
             total, "OK" if ok else "MISMATCH"))
    return ok


def main():
    import argparse, sys
    ap = argparse.ArgumentParser()
    ap.add_argument("--netlist", nargs="?", const=NETLIST, metavar="NETLIST_V",
                    help="re-derive every row's population from this "
                         "netlist and exit non-zero on drift (default: %s)"
                         % NETLIST)
    args = ap.parse_args()
    if args.netlist:
        sys.exit(0 if check_netlist(args.netlist) else 1)
    rows = []
    tot = dict(lam=0.0, safe=0.0, spf=0.0, lat=0.0)

    def add(name, lam, safe_frac, dc_s, dc_m, mech, perm_lam, dc_p):
        # transient part
        lam_t   = lam
        safe    = lam_t * safe_frac
        resid   = lam_t - safe
        sb, mb  = resid * (1 - MBU_FRACTION), resid * MBU_FRACTION
        det     = sb * dc_s + mb * dc_m
        undet   = resid - det
        # permanent part
        p_safe  = perm_lam * safe_frac
        p_res   = perm_lam - p_safe
        p_det   = p_res * dc_p
        p_undet = p_res - p_det
        lam_all  = lam_t + perm_lam
        safe_all = safe + p_safe
        spf      = undet + p_undet          # dangerous, undetected
        # a detected fault in a *mechanism* element is a potential
        # latent contributor only if the report path itself is the
        # casualty; V37's ungated bit closes that structurally, so
        # detected faults count as perceived, undetected mechanism
        # faults as latent.  For this single-goal analysis latent ==
        # undetected mechanism-side faults, already inside spf for the
        # primary goal; LFM uses the mechanism subset (below).
        rows.append((name, lam_all, safe_all, spf, mech))
        tot['lam']  += lam_all
        tot['safe'] += safe_all
        tot['spf']  += spf

    # SRAM
    n, sname = SRAM[1], SRAM[0]
    perm_share = PERM_FIT_TOTAL * 0.5           # ASSUMED: half the hard
    add(sname, fit_sram(n), SRAM[2], SRAM[3], SRAM[4], SRAM[6],
        perm_share, SRAM[5])

    # logic elements share the other half of the permanent budget by
    # flop count (ASSUMED apportionment)
    perm_logic = PERM_FIT_TOTAL * 0.5
    for (name, ffs, safe, dcs, dcm, dcp, mech) in ELEMENTS:
        if ffs == 0:
            continue
        add(name, fit_ff(ffs), safe, dcs, dcm, mech,
            perm_logic * ffs / TOTAL_FF, dcp)

    lam, spf, safe = tot['lam'], tot['spf'], tot['safe']
    spfm = 1 - spf / lam
    # LFM over the mechanism elements: undetected faults in the things
    # that do the detecting.  Mechanism set = everything except the two
    # mission datapaths (core pair handled by DCLS, TCM arrays by ECC).
    mech_rows = [r for r in rows if r[0] not in
                 ("core pair (lockstep)", SRAM[0])]
    lam_mech = sum(r[1] for r in mech_rows)
    lat_mech = sum(r[3] for r in mech_rows)
    lfm = 1 - lat_mech / lam_mech

    print("cdriscv-32s-10 FMEDA -- computed %s" % "2026-09-14")
    print("ASSUMED rates: SRAM %.0f FIT/Mbit, FF %.0f FIT/Mbit, "
          "permanent %.0f FIT total, MBU fraction %.0f%%"
          % (SEU_SRAM_FIT_PER_MBIT, SEU_FF_FIT_PER_MBIT,
             PERM_FIT_TOTAL, MBU_FRACTION * 100))
    print()
    print("%-26s %10s %10s %10s" % ("element", "lambda FIT", "safe FIT", "SPF FIT"))
    for name, l, s, d, mech in rows:
        print("%-26s %10.3f %10.3f %10.4f" % (name, l, s, d))
    print("%-26s %10.3f %10.3f %10.4f" % ("TOTAL", lam, safe, spf))
    print()
    print("SPFM = %.2f %%   (ASIL B >= 90, C >= 97, D >= 99)" % (100 * spfm))
    print("LFM  = %.2f %%   (ASIL B >= 60, C >= 80, D >= 90)  "
          "[mechanism subset: %.3f of %.3f FIT undetected]"
          % (100 * lfm, lat_mech, lam_mech))
    print("residual dangerous-undetected rate: %.4f FIT" % spf)

if __name__ == "__main__":
    main()
