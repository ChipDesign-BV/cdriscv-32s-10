# cdriscv-32s-10 FMEDA

**Computed 2026-09-18 by `scripts/fmeda.py` on the E2E-inclusive RTL (V55/V56) —
rerun it, do not edit the numbers here by hand; `python3 scripts/fmeda.py
--netlist` re-derives every population from the netlist and fails on drift.**
The 2026-08-25 edition (V44: SPFM 99.63 / LFM 91.42 / 0.87 FIT, 5 658
flops, no E2E) and the 2026-09-14 one (V55: 99.56 / 91.27 / 1.03 FIT, with
536 flops in an "unattributed" row at an assigned diagnostic coverage) are
both superseded: **every flip-flop but 17 is now attributed to the block it
belongs to** (V56, section 2a).

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
core pair (lockstep)            7.146      3.216     0.0393
lockstep delay+compare          1.181      0.118     0.1063
TCM control+ECC logic           0.193      0.058     0.0068
E2E link endpoints              0.193      0.019     0.0174
safety controller               0.652      0.033     0.0512
watchdog                        0.221      0.011     0.0173
clock monitor                   0.419      0.042     0.0466
interrupt controller            0.206      0.041     0.0136
timer                           0.344      0.103     0.0199
AMS interface                   1.073      0.322     0.0928
memory BIST (x2)                0.310      0.186     0.0417
bus + sync + APB glue           0.212      0.064     0.0149
unresolved (conservative)       0.036      0.000     0.0181
TOTAL                         235.469     93.525     1.0217

SPFM = 99.57 %   (ASIL B >= 90, C >= 97, D >= 99)
LFM  = 91.14 %   (ASIL B >= 60, C >= 80, D >= 90)  [mechanism subset: 0.447 of 5.042 FIT undetected]
residual dangerous-undetected rate: 1.0217 FIT
```

**SPFM 99.57 %, LFM 91.14 %, residual 1.02 FIT** under the stated
assumptions — numerically above the ASIL D targets (SPFM ≥ 99 %,
LFM ≥ 90 %), with the caveats of section 1. Against the pre-E2E
edition the residual rose from 0.87 to 1.02 FIT: not because E2E made
anything worse — its row is 0.017 FIT of residual — but because 536
flip-flops the first edition did not count at all are now counted, and
since V56 counted *in the blocks they belong to* rather than in a row of
their own. Honest counting costs a fraction of a point; what it buys is
in section 2a.

## 2a. Every flip-flop is attributed (V56)

The populations above are counted by matching each flip-flop's Q-net
against the RTL instance path it carries in the flattened netlist. 536 of
the 5 736 had no such name: synthesis renames a net whose register was
merged, re-encoded or re-driven, and `write_verilog` prints those as
`_NNNN_`. The 2026-09-14 edition therefore carried them in an
"unattributed" row at a diagnostic coverage of 0.90 — a figure nobody had
measured, and the one figure in the table that could move a metric across
a threshold: at 0.50 that row put LFM at 89.84 %, below the ASIL D line.

They are attributed now, and nothing about the design changed to do it.
yosys records the RTL file and line of the register each flop implements
in a `src` attribute, which survives every rename; `write_verilog -noattr`
was simply throwing it away. The flow now writes the same netlist twice —
`cdriscv_subsys_pd.v` for the tools, `cdriscv_subsys_fmeda.v` with
attributes for this analysis — and `--netlist` asserts the two hold the
same 5 736 flip-flops before it believes either. Attribution is then two
stages: the Q-net's instance path where there is one, and otherwise the
row that the *other* flops from the same source line agree on. 519 of the
536 resolve, of which 107 need the dominance rule (`safety_ctrl.sv:163`
has 115 named siblings in the safety controller and one that flattening
renamed into lockstep wiring, so 99.1 % settles it).

**17 flops remain unresolved — 0.30 %.** Eight come from
`cfg_parity.sv:48`, whose eight instances sit in eight different blocks
with no majority, and nine carry no `src` at all. They are carried with no
safe share and the lowest diagnostic coverage in the table. The point of
the exercise is what that does to the sensitivity: **at dc 0.00 for that
row the metrics are SPFM 99.56 %, LFM 90.79 % — still above ASIL D.** The
result no longer depends on a figure that was assigned rather than
measured, which is what the row was flagged for.

## 3. What the configuration parity is worth, in metric terms

Recomputing with the V37 configuration parity removed — single-bit
diagnostic coverage of every configuration register set to the zero
that V29 measured — gives **LFM 82.9 %** (83.4 % in the 2026-08-25
edition; the V56 attribution moves 350 flops into the parity-protected
rows, so the mechanism is worth more, not less): below the ASIL D bar,
ASIL C territory. The one mechanism added in V37 is the difference
between the architecture clearing the latent-fault target and missing
it, which is the quantified form of what the campaign said in counts:
1 207 latent upsets out of 2 600 before, zero after.

## 4. Where the residual lives

Half the 1.02 FIT residual (0.54) is the TCM arrays' triple-bit-and-beyond
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
in-mission BIST would move it). **No row now rests on an assigned
attribution**: the unattributed row that used to sit here — 536 flops
whose dc of 0.90, set at 0.50, put LFM below ASIL D — was resolved in
V56 (section 2a), and what is left of it is 17 flops whose worst case
is already inside the headline figure.

## 5a. The same test, applied to every row (added 2026-09-21)

Section 2a closed the unattributed row by the argument that a verdict
must not rest on a figure nobody measured, tested by setting that
figure to 0.50. Applying the identical test to every other row — done
mechanically while generalising this script — shows the closure was
narrower than this document claimed:

| row set to DC 0.50 (safe share kept) | fault injection into the row? | LFM |
|---|---|---|
| TCM control+ECC logic (91 flops) | no — the *arrays* are targets 6/7, the control logic is not | **89.94 %** |
| E2E link endpoints (91 flops) | no — the link *wires* are swept (fi-e2e), the endpoint registers are argued | **89.76 %** |
| bus + sync + APB glue (100 flops) | no ("assigned, not swept") | **89.96 %** |
| memory BIST ×2 (146 flops) | no | 90.74 % |
| unresolved (17 flops) | — | 91.14 % |
| all five together | | **86.97 %** |

Rows with at least one register among the 27 random-campaign targets
(core pair, lockstep delay pipeline 86/86 detected, safety controller,
watchdog, clock monitor, interrupt controller, timer, AMS) are not in
this table; their figures are supported by a sample of their registers,
which is weaker than "measured" and is what it is.

So three rows, 282 flops, each carry an **argued** diagnostic coverage
(0.90–0.95) that holds LFM above 90 % by less than its own uncertainty.
"No row now rests on an assigned attribution" (section 5) is true of
*attribution* and was read — by this document's author too — as true of
the *verdict*. It is not. The honest status: **SPFM is robust (≥ 99.48 %
in every case above); LFM is past ASIL D only if the three argued rows'
coverage is accepted.** The way to close it is the one variant 2 used
for its loader row: a directed sweep into those registers
(`fi_campaign.py --sweep` with new targets). Not done.

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
