# cdriscv-32s-10 FMEDA

**Computed 2026-09-14 by `scripts/fmeda.py` on the E2E-inclusive RTL (V55) —
rerun it, do not edit the numbers here by hand; `python3 scripts/fmeda.py
--netlist` re-derives every population from the netlist and fails on drift.**
The 2026-08-25 edition (V44: SPFM 99.63 / LFM 91.42 / 0.87 FIT, 5 658
flops, no E2E) is superseded.

## 1. What this is, and what it is not

This is a Failure Modes, Effects and Diagnostic Analysis of the
subsystem at the architecture level, built from three kinds of number,
each labeled throughout:

* **MEASURED** — element populations counted from the E2E-inclusive
  synthesised netlist (`build/gate/cdriscv_subsys_pd.v`, the one
  `make fmax` places: **5 736 flip-flops**, of which 5 200 are
  attributed per block by Q-net name and 536 carry synthesis-renamed
  nets and form the unattributed row — attributed + unattributed =
  5 736, asserted by the script; 319 488 logical SRAM bits), and
  diagnostic coverage from the fault-injection campaigns of findings
  V9/V29/V30/V33/V37 re-run on this RTL in V55 (~10⁴ classified
  single-event upsets, zero silent data corruption, zero latent
  configuration faults), plus the V55 E2E link sweep (400 of 400 wire
  bits detected). Placement adds no flip-flops, so the synthesised
  count is the placed count; the V52 GDS predates E2E and is not what
  these populations describe.
* **ASSUMED** — base failure rates. **No foundry reliability data for
  IHP SG13G2 was available to this analysis.** The rates are typical
  published figures for a 130 nm-class process at sea level:
  700 FIT/Mbit SRAM soft errors, 400 FIT/Mbit flip-flop soft errors,
  20 FIT total permanent — a round SN 29500-class figure quoted for a
  ~2.6 mm² digital die and **not scaled to this design's 3.353 mm²**,
  which makes the permanent contribution optimistic by roughly the area
  ratio; 2 % multi-bit-upset
  fraction. **A real safety case replaces every one of these** with
  foundry data and a mission profile; the script makes that a
  five-line edit.
* **DERIVED** — the metrics.

This document is an architectural statement, not a certification. The
metrics landing above the ASIL D thresholds means the *architecture*
carries no structural gap under the stated assumptions — it does not
mean ASIL D compliance, which additionally requires qualified tools,
process evidence, foundry data and an assessed safety case.

## 2. Result

```
cdriscv-32s-10 FMEDA -- computed 2026-09-14
ASSUMED rates: SRAM 700 FIT/Mbit, FF 400 FIT/Mbit, permanent 20 FIT total, MBU fraction 2%

element                    lambda FIT   safe FIT    SPF FIT
TCM arrays (SEC-DED)          223.281     89.312     0.5359
core pair (lockstep)            7.010      3.154     0.0386
lockstep delay+compare          1.181      0.118     0.1063
TCM control+ECC logic           0.193      0.058     0.0068
E2E link endpoints              0.193      0.019     0.0174
safety controller               0.425      0.021     0.0333
watchdog                        0.019      0.001     0.0015
clock monitor                   0.317      0.032     0.0352
interrupt controller            0.206      0.041     0.0136
timer                           0.206      0.062     0.0119
AMS interface                   0.776      0.233     0.0671
memory BIST (x2)                0.310      0.186     0.0417
bus + sync + APB glue           0.212      0.064     0.0149
unattributed (renamed)          1.139      0.114     0.1025
TOTAL                         235.469     93.416     1.0267

SPFM = 99.56 %   (ASIL B >= 90, C >= 97, D >= 99)
LFM  = 91.27 %   (ASIL B >= 60, C >= 80, D >= 90)  [mechanism subset: 0.452 of 5.178 FIT undetected]
residual dangerous-undetected rate: 1.0267 FIT
```

**SPFM 99.56 %, LFM 91.27 %, residual 1.03 FIT** under the stated
assumptions — numerically above the ASIL D targets (SPFM ≥ 99 %,
LFM ≥ 90 %), with the caveats of section 1. Against the pre-E2E
edition the residual rose from 0.87 to 1.03 FIT and LFM fell from
91.42 to 91.27 %: not because E2E made anything worse — its row is
0.017 FIT of residual — but because the 536 renamed flops that the
first edition did not count are now carried, deliberately, at a
diagnostic coverage below every named row's. Honest counting costs a
tenth of a point; the margin to the ASIL D line is 1.3 points and the
next paragraph says what it rests on.

## 3. What the configuration parity is worth, in metric terms

Recomputing with the V37 configuration parity removed — single-bit
diagnostic coverage of every configuration register set to the zero
that V29 measured — gives **LFM 86.0 %** (was 83.4 % in the 2026-08-25
edition; the unattributed row now dilutes the mechanism subset): below the ASIL D bar,
ASIL C territory. The one mechanism added in V37 is the difference
between the architecture clearing the latent-fault target and missing
it, which is the quantified form of what the campaign said in counts:
1 207 latent upsets out of 2 600 before, zero after.

## 4. Where the residual lives

Half the 1.03 FIT residual (0.54) is the TCM arrays' triple-bit-and-beyond
tail past SEC-DED — reducible with layout interleaving (credit for
which is deliberately not taken here). Most of the rest is the
lockstep delay-and-compare structure and the reaction wiring of the
safety controller: the checkers themselves, which is where any DCLS
architecture's residual lives. The self-test hooks (SELFTEST, INJECT)
exist precisely to exercise these at start-up; crediting them would
raise DC on those rows and is left to the safety case.

## 5. Sensitivity

The metrics are ratios, so they are insensitive to the absolute FIT
scale (doubling every rate changes neither SPFM nor LFM). They are
sensitive to: the MBU fraction (2 % assumed; interleaving data would
justify less), the DCLS coverage figure (0.99 assumed, supported by
zero SDC in ~10⁴ injections but not proven to three nines), and the
BIST-dormancy treatment (counted mostly latent between runs; periodic
in-mission BIST would move it), and — since V55 — the unattributed
row's assigned dc of 0.90: at 0.50 the metrics are SPFM 99.53 % and
**LFM 89.84 % — below the ASIL D line**. That row is the one whose
assigned figure can move a metric across a threshold, so naming those
536 flops (most are the cores' pipeline and CSR state by count, which
DCLS covers at 0.99 — a `keep_hierarchy`/name-preserving synthesis
pass would settle it) is the cheapest and most necessary lever left in
this table.

## 6. Handoff checklist for the safety-case owner

1. Replace the ASSUMED block in `scripts/fmeda.py` with foundry FIT
   data and the mission profile.
2. Decide the multi-bit story: SRAM column interleaving factor, and
   whether the software scrub (V30) is claimed for double-bit
   configuration coverage.
3. Common-cause analysis for the lockstep pair (shared clock, reset,
   voltage) — outside what fault injection can measure.
4. Credit or discard the start-up self-tests in the permanent-fault DC.
5. **Done (V55, 2026-09-14).** The end-to-end bus protection
   (`FLT_E2E`, SM11) is in the population (91 flops, its own row) and
   its coverage of the core↔TCM path is measured, not argued: the
   `fi-e2e` sweep forces every wire bit of the two protected links on
   a live beat — 400 of 400 detected, 0 silent, 0 SDC, median 4
   cycles. The endpoint *registers* themselves are argued
   self-evidencing (a corrupted held address or check-bit register
   mismatches the next beat), as the comparator is.
6. Re-run the script; the tables regenerate.
