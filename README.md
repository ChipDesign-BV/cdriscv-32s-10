# cdriscv-32s-10

**A 32-bit RISC-V core subsystem for safety-critical mixed-signal SoCs.**

**On the name.** The `s` denotes what the part is *designed for*, not what
it has been *certified as*. It is an architectural statement — dual-core
lockstep, SEC-DED memories, configuration parity, a watchdog and a clock
monitor are in the design because safety-critical use is the target — and
it carries no compliance claim whatsoever. The distinction is the same one
the banner below draws between "verified for project use" and "not
qualified for safety-critical use": intent is not qualification, and
neither implies the other. A reader who notices the tension between a
safety-oriented name and a disclaimer of any safety claim is reading
correctly; both statements are true because they describe different
things.

(c) 2026 ChipDesign B.V. — [Apache-2.0](LICENSE)

> [!IMPORTANT]
> **Verified for project use — not qualified for safety-critical use.**
>
> As of 2026-09-14 (V55) the O1–O7 gate of
> [doc/verification_plan.md](doc/verification_plan.md) is met **on the
> E2E-inclusive RTL** — the plan's own definition of "may be used in a
> project"; the 2026-08-24 numbers were re-produced on the current
> design, not carried over. The audit, from runs in this repository:
>
> | # | Objective | Criterion | State |
> |---|-----------|-----------|-------|
> | O1 | ISA conformance | `riscv-arch-test` passes vs Spike | **met** — 85 of 85, current suite, unmodified |
> | O2 | golden-model random co-simulation | ≥ 10⁹ instructions, zero mismatches | **met** — 1 035 684 199 instructions, 35 600 programs, zero mismatches (V55; V40's 1 008 435 332 was the pre-E2E run) |
> | O3 | block benches | all directed tests pass | **met** |
> | O4 | safety mechanisms fire, and only then | fires + stays-quiet test per mechanism | **met** — benches plus 10 400 random and 400 swept fault injections (V55) |
> | O5 | structural cleanliness | lint clean, documented waivers | **met** |
> | O6 | code coverage | 100 % stmt/branch, ≥ 95 % toggle, reviewed waivers | **met** — 95.9 % line (100 % with 16 reviewed waivers), 96.2 % toggle, loader included (V55) |
> | O7 | functional coverage | cross matrices closed | **met** — 66 of 66 cover points, incl. `FLT_E2E` |
>
> Also measured: configuration-register upsets hardware-detected
> (latent 46.4 % → 0), diagnostic latency median 2–4 cycles, zero
> silent data corruption over 10 400 injections, every wire bit of the
> E2E-protected TCM links detected when flipped (400 of 400), and
> **timing closed at
> the 25 MHz integration target across all three PVT corners** (setup
> +2.698 ns worst, hold +0.133 ns worst, TNS 0 on the routed netlist —
> the V52 GDS, which predates E2E; the E2E netlist's placement estimate
> is +13.9 ns reg2reg at the same constraint, and its harden is
> deferred). An earlier closure figure against a shorter target was
> typical-corner only and was withdrawn in V45. Twelve
> functional defects were found and fixed on the way; CI re-runs the
> gate on every push.
>
> **The full plan, O1–O9, has a result for every objective on the
> current RTL.** The FMEDA ([doc/fmeda.md](doc/fmeda.md), recomputed
> from the E2E netlist, every flop but 17 attributed to its block):
> SPFM 99.57 %, LFM 91.14 %, residual 1.02 FIT
> — **under assumed failure rates**, clearly labeled,
> that a real safety case must replace with foundry data. An
> architectural statement, not a certification: no ISO 26262 or
> IEC 61508 compliance of any kind is claimed, and the remaining work
> (foundry FIT data, common-cause analysis, safety-case ownership) is
> listed in the document's handoff checklist. No functional
> safety claim of any kind is made, and no compliance with ISO 26262,
> IEC 61508 or any other standard. The safety mechanisms are measured,
> not certified.

## What it is

A small, deterministic RISC-V control subsystem meant to sit in the
digital corner of a mixed-signal SoC — a sensor front-end, a motor or
power controller, a battery monitor — where a failure of the control
loop has to be *detected and signalled*, not tolerated.

The design goal is not performance. It is that every structure in the
subsystem is small enough to reason about, and that a fault in it is
either detected by a mechanism that reports it, or bounded by one.

* **Core** — RV32IM_Zicsr_Zifencei, machine mode only, two stages, one
  instruction in the execute stage at a time. No forwarding, no
  speculation, no caches: every instruction has a statically known
  worst-case latency. Straight-line code retires one instruction per
  cycle (measured CPI 1.20 on a dependent ALU loop, the residual being
  the taken-branch redirect).
* **Dual core lockstep (DCLS)** — a checker core runs the same program
  delayed by a configurable number of cycles, and every output is
  compared. The delay makes the pair diverse in time, so a disturbance
  that hits both cores in the same cycle hits them in different parts of
  the program.
* **SEC-DED protected memories** — 39-bit words (Hsiao code) in both
  tightly coupled memories, single bit errors corrected, double bit
  errors reported as a bus error and as a fault.
* **March C- memory BIST** — over the raw 39-bit words, so the check bit
  storage is tested too.
* **Register file parity**, checked on every register an instruction
  actually reads.
* **Windowed watchdog** with a two step key sequence: catches servicing
  too late *and* too early, and locks its own configuration.
* **Clock monitor** in an independent reference clock domain, so it can
  report the loss of the clock it is watching.
* **Safety controller** — one sticky status bit per fault source, a
  configurable reaction per source (interrupt, warm reset, external
  error pin), a lockable configuration, and fault injection so that the
  detection paths themselves can be proven in the field.
* **Mixed-signal interface** — ADC sequencer with per-channel result
  range checking and conversion time-out, trim/DAC output, analog test
  bus control, and analog supervisor flag inputs routed into the safety
  controller. The analog domain becomes a monitored safety element
  rather than an unobserved black box.
* **APB expansion slot** for the SoC's own mixed-signal registers.

## Repository layout

| Path | Contents |
|------|----------|
| [rtl/core/](rtl/core/) | core: fetch, decode, ALU, multiply/divide, LSU, CSR, register file |
| [rtl/safety/](rtl/safety/) | lockstep, SEC-DED, safety controller, watchdog, clock monitor, memory BIST, end-to-end bus protection |
| [rtl/bus/](rtl/bus/) | interconnect, TCM, APB bridge |
| [rtl/periph/](rtl/periph/) | timer, interrupt controller, AMS interface |
| [rtl/common/](rtl/common/) | clock domain crossing primitives |
| [rtl/boot/](rtl/boot/) | optional QSPI-master firmware boot loader (`BootEnable=1`, off by default) |
| [rtl/chip/](rtl/chip/) | full-chip top: the subsystem in an IHP SG13G2 IO pad ring (generated, `BootEnable=1`) |
| [rtl/cdriscv_subsys.sv](rtl/cdriscv_subsys.sv) | subsystem top level |
| [tb/](tb/) | smoke bench and smoke program |
| [verif/models/](verif/models/) | behavioural SPI-NOR model and the Verilog-A / OpenVAF ADC-interface emulator |
| [xschem/](xschem/) | xschem symbol for the IP block |
| [scripts/](scripts/) | ECC generator, memory image builder, boot-image packer, pad-ring and symbol generators |
| [flow/](flow/) | LibreLane 3 hardening flow: config and wrapper |
| [doc/](doc/) | architecture, register map, safety manual draft, verification plan, integration guide |

## Physical implementation (RTL2GDS)

The subsystem hardens with **LibreLane 3** on the IHP SG13G2 PDK;
`flow/` holds the configuration and the hardening wrapper, and
`doc/integration.md` §8 is the integrator-facing summary.

```sh
cd flow && librelane --manual-pdk --pdk-root $PDK_ROOT config.json
```

**State: DRC clean, LVS matches, setup and hold both met at all three
corners** — at **25 MHz on a 1100 x 2346 um die (2.581 mm², V56, on the
E2E-inclusive RTL)**, whose width is the SRAM macro row and nothing
else. That is the main configuration and the one to design against.
The V52 die (1330 × 2521 µm, 3.353 mm², pre-E2E) and the 1.90 mm square
(3.610 mm²) are kept as the earlier, more conservative points. The flow runs floorplan -> PDN -> placement ->
CTS -> detailed routing -> extraction -> IR-drop -> streamout -> DRC ->
LVS.

A **full-chip pad ring** is also provided (`rtl/chip/cdriscv_chip.sv`,
generated by `scripts/gen_padring.py`, flow in `flow/config_chip.json`,
pinout in `doc/chip.md`): the subsystem wrapped in the IHP SG13G2 IO
library — **84 signal + 16 supply pads + 4 corners on a 2400 × 3500 µm
die**, with the QSPI boot flash on four bidirectional pads at the
south-east corner. This is the **`BootEnable=1` flash-boot build**; it
is lint-clean but has **not** been hardened here, and it is a separate
configuration from the signed-off macro above (whose default
`BootEnable=0` is unchanged). No ADC is on the die — the AMS signals go
to west-side pads for an external analog companion.

The rectangle is worth 7.1 % of the area against the square at the same
frequency and on the same fabric. It is not a geometry trick — die area is instance area over
utilization — it is that six macros in two full-width rows leave a
square with four corner regions the placer fills badly, and leave a
rectangle with two contiguous bands. Utilization goes 0.445 -> 0.587.

| Gate | Result |
|---|---|
| Detailed routing | 0 violations |
| Antenna, post-route | **0 nets, 0 pins** |
| **DRC** (IHP KLayout signoff deck) | **clean** |
| GDS XOR (Magic vs KLayout streamouts) | **0 differences** |
| **LVS** (netgen) | **circuits match** — 0 errors, 0 unmatched devices or nets (V56); V52: matched uniquely, 95 962 devices / 49 499 nets |
| Setup, 3 corners | slow **+2.698 ns**, typ +13.70, fast +20.05; TNS 0 |
| **Hold**, 3 corners | **closed** — fast **+0.133 ns**, typ +0.348, slow +0.704; TNS 0 |
| TCM split-macro mapping | **verified functionally** — 6 600-check equivalence vs the behavioural TCM, mutation-proved (V49); `make block-tcm` |
| Max slew / max cap | **not gated by the flow** — see V46/V48; unchanged as a caveat |

**Area (V56).** The die is **1100.08 × 2345.94 µm (2.581 mm²)** at
**84.5 % utilisation**, and its width is the SRAM macro row exactly:
416.64 + 5 + 416.64 + 5 + 236.8 = 1080.08 µm of core, plus a 10 µm die
margin. Four changes got there from the original 2.40 mm square: the
TCM check bits moved into their own `4096x8` macros so no array bit is
wasted (macro area 1.967 → 1.337 mm², −32 %), the die shrank around
them (2.40 → 1.90 mm square), the square became a rectangle one macro
row wide (3.61 → 3.353 mm²), and then **the pre-emptive antenna diodes
went away** (3.353 → 2.581 mm², −23 %).

That last one corrects what this section used to claim. The floor was
bracketed at 3.353 mm² and attributed to antenna-diode legalisation —
"~46 700 diodes each need a free site beside the pin they protect" —
which was true of the flow and not of the design.
`RUN_HEURISTIC_DIODE_INSERTION` pre-inserts those diodes to pre-empt
violations; the checker found **84 nets and 92 pins** actually
violating. With the pre-emption off, the detailed router repairs the
real ones and the signed-off die carries **164 diodes instead of
46 689**, with **zero** antenna violations either way. The area floor
was a flow setting.

**90 % utilisation was asked for and does not route**, on this width or
a wider one: the six macros are 50.9 % of the core and no standard cell
can sit inside a macro band, so 90 % forces the logic band to ~82 %
local density against 52 % at V52. Nine builds measure it, ending in a
detailed route stuck at 41 137 DRC violations and shedding 2.5 % per
iteration. Finding V56 has the ladder — each build failed somewhere
different, and two of them show that *widening* the die makes
congestion worse, not better, because at constant area the width comes
out of the height.

**This is not a tapeout.** No clock-tree review, signal integrity, ESD,
packaging or test structures; the FMEDA still runs on assumed failure
rates. What it is: evidence that the RTL hardens, that the layout
matches the netlist that was verified, and that the timing claim
survives the corner that matters.

| | Main configuration (V56) | previous (V52, pre-E2E) |
|---|---|---|
| Die | **1100.08 × 2345.94 µm (2.581 mm²)** — the width IS the SRAM macro row; 51.8 % macros, 30.3 % standard cells, the rest fill and routing. **Utilisation 84.5 %** | 1330 × 2521 µm (3.353 mm²), 71.7 % |
| Content | **50 194 standard cells** (12 961 timing-repair buffers, **164 antenna diodes**), **6 SRAM macros**, 39 605 fill | 95 958 cells, 46 689 diodes, 85 176 fill |
| Memories | per TCM: `RM_IHPSG13_1P_2048x32` × 2 (data) + `RM_IHPSG13_1P_4096x8` × 1 (check bits); banded, 10 µm halos | same |
| Clock | **40 ns (25 MHz)** | same |
| IR drop | worst-case 1.20 V — negligible | same |

**A correction worth keeping.** An early run met its constraint at the
typical corner while missing **by 8.99 ns at slow** (1.08 V, 125 °C),
3 636 register-to-register paths failing, because the script read a
single Liberty file. **One Liberty file is not a signoff.** The
constraint is 40 ns and `make fmax` reads all three corners, slow first,
so the binding number is the one you see. Sign off setup at slow, hold
at fast — finding V45.

Eleven environment and configuration obstacles were found bringing
this up, from an unparseable vendor SRAM model to the SRAM's third supply
pin (`VDDARRAY!`) and OpenROAD's undriven constant nets; each is fixed
in `flow/config.json` and explained in the findings. Two of them —
missing tie cells and the undriven constants — would have produced a
broken netlist for layout regardless of simulation, which is the
argument for running the physical flow at all.

## Documentation

* [doc/architecture.md](doc/architecture.md) — how it is built and why
* [doc/programming_manual.md](doc/programming_manual.md) — firmware view: ISA, traps, peripherals, safety duties, idioms
* [doc/register_map.md](doc/register_map.md) — address map, CSRs, every peripheral register
* [doc/integration.md](doc/integration.md) — integration manual: deliverables, checklist, ports, clocking, reset, CDC, boot, safety hooks, DFT, physical implementation
* [doc/safety_manual.md](doc/safety_manual.md) — mechanisms, assumptions of use, remaining gaps
* [doc/verification_plan.md](doc/verification_plan.md) — the objectives and their results
* [doc/verification_findings.md](doc/verification_findings.md) — the evidence log, V0–V52
* [doc/fmeda.md](doc/fmeda.md) — FMEDA: measured populations and coverage, assumed rates, derived metrics

## Building

```sh
make lint     # verilator --lint-only
make sw       # build the smoke program and its ECC encoded memory image
make sim      # iverilog + vvp, boots the smoke program
make synth    # yosys generic synthesis, area statistics
make ecc      # regenerate rtl/safety/cdriscv_ecc_secded.sv
```

Inside the IIC-OSIC-TOOLS container the tools need an explicit path:

```sh
export PATH="/foss/tools/bin:/foss/tools/verilator/bin:$PATH"
```

## Status

Every objective of [doc/verification_plan.md](doc/verification_plan.md)
has a result. The banner above audits the gate; the detail and every
number's provenance live in
[doc/verification_findings.md](doc/verification_findings.md) (phases
V0–V55, newest first). Summary, one line per area:

| Area | State | Evidence |
|------|-------|----------|
| Lint & structure | **clean** | `make lint lint-tb`, hard gate; waivers argued in [verif/lint/waivers.vlt](verif/lint/waivers.vlt) |
| Directed benches | **all pass** | 17 targets: blocks (ALU, SEC-DED, mul/div, clkmon), safety both halves, reactions, peripherals, traps, AMS, register walk, read-back, FENCE/FENCE.I, back-pressure |
| Co-simulation vs Spike | **O2 met, on the E2E RTL** | 1 035 684 199 random instructions, 35 600 programs, zero mismatches on PC, instruction, register and memory writes (V55, six runners with disjoint seeds, 3 h); plus directed and stall-sweep runs |
| Architectural suite | **85 of 85** | current `riscv-arch-test`, unmodified, built `-mno-relax` (V36); `make riscof` |
| Formal | **6 benches pass** | re-run on the E2E RTL (V55): full proofs for SEC-DED (all 2³² words, every 1–2-bit error) and decoder (all 2³² encodings); BMC elsewhere; ungated config-parity contract proven; mutation tested |
| Coverage | **O6/O7 met** | 95.9 % line (100 % with 16 [reviewed waivers](verif/coverage_waivers.md)), 96.2 % toggle, 100 % functional over 66 cover points, on the E2E RTL with the loader's boot benches in the merge (V55; toggle had read 93.9 % and was recovered by stimulus, not waivers) |
| Fault injection | **0 SDC, 0 hangs, 0 latent** | 10 400 classified upsets over four workloads on the E2E RTL (V55) plus the 400-upset E2E link sweep, **400 of 400 detected**; latent was **46.4 %** before the V37 configuration parity, zero after, detection median 2–4 cycles; `make fi` (incl. `fi-e2e`) |
| Timing | **closed at 25 MHz, 3 corners, on the E2E RTL** | setup **+10.05 ns** (slow) / +18.23 typ / +21.40 fast, hold **+0.169 ns** (fast) / +0.379 typ / +0.758 slow, TNS 0 both — the V56 harden, 1100 × 2346 µm at 84.5 % utilisation, DRC and LVS clean (V52's pre-E2E numbers were +2.698 / +0.133 on a 23 % bigger die) |
| Gate level | **O8 met, on the E2E netlist** | zero-delay netlist all pass (blocks, 5 FSM recoveries, subsystem programs); smoke + 12 architectural tests on the placed E2E netlist with OpenROAD SDF cell delays at the 40 ns signoff clock, signatures bit-exact vs Spike (V55; V42/V43 were pre-E2E); `make gate gate-sdf gate-arch` — the SDF path had four stale pre-split traces, all found and fixed in V55 |
| FMEDA | **SPFM 99.57 % / LFM 91.14 %, 1.02 FIT** | recomputed from the E2E netlist (5 736 flops, `scripts/fmeda.py --netlist` asserts the count), E2E row measured by the sweep, under stated assumed failure rates (V55/V56). **No row rests on an assigned attribution**: the 536 synthesis-renamed flops are attributed to their blocks from yosys' `src`, leaving 17 (0.30 %) whose worst case — dc 0.00 — still gives LFM 90.79 %, above ASIL D ([doc/fmeda.md](doc/fmeda.md) §2a) |
| CI | **green** | [verify.yml](.github/workflows/verify.yml): full gate on every push; gate-level, `sta`, `fmax`, SDF smoke and fault injection (incl. the E2E sweep) nightly |
| QSPI boot loader (optional) | **verified, off by default** | block bench 41 checks, end-to-end boot 1-bit + quad, corrupt-image sticky-fault path, mutation 10/10 (V53/V54); `make block-qspi bootsim bootsim-fault`. `BootEnable=0` folds it away completely |
| E2E bus protection (always-on) | **verified and measured (V54/V55)** | check bits over {payload, address, byte-enables} on both TCM links; `make block-e2e` 154 096 checks / `block-e2e-link` 12 024 checks; `fi-e2e` sweeps every wire bit of both links on live beats — 400 of 400 detected, median 4 cycles; two system-level scenarios in `tb_safety`; its own FMEDA row |

> **What the V55 re-run did and did not cover.** E2E (V54, always-on)
> re-opened the V52 signoff; every objective row above has since been
> re-produced on the E2E-inclusive RTL (finding V55). What has *not*
> been redone is the physical implementation: the Timing row is the
> pre-E2E V52 GDS, and the full-chip harden of the current RTL is a
> deliberate deferral ([doc/chip.md](doc/chip.md)).

Twelve functional defects and two flow defects were found and fixed on
the way; four tool defects were reported upstream. The wrong guesses
are preserved in the findings next to the measurements that corrected
them.
