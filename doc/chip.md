# cdriscv-32s-10 — full-chip level

Chip top `rtl/chip/cdriscv_chip.sv` wraps `cdriscv_subsys` in an IHP SG13G2 IO
pad ring (`sg13g2_io` library) for hardening with LibreLane 3's `Chip` flow
(`flow/config_chip.json`, `flow/run_chip.sh`). Everything below is
generated/checked by `scripts/gen_padring.py`, which asserts the subsystem port
list from the RTL and the pad geometry from the PDK LEF before emitting
anything.

**Status: chip top and flow config GENERATED and lint-clean; hardening
DEFERRED.** The RTL2GDS run of this full-chip build is a deliberate
deferral — P&R sits below implementation, verification and documentation
for this IP, and the subsystem it wraps is already signed off to GDS
(V52). This document carries no hardening (DRC/LVS/timing) results because
the run has not been made; a missing status is not a pass. To harden,
follow the invocation below.

This chip is the flash-boot build: `cdriscv_subsys` is instantiated with
`BootEnable=1` (its default is `0` — the signed-off, TCM-preloaded
configuration), so the QSPI boot loader is elaborated and its five ports reach
pads. The chip *is* the hard top, so the subsystem is instantiated directly
with `boot_addr_i` tied to `32'h0000_0000`, mirroring
`flow/cdriscv_subsys_hard.sv` (finding V18).

## Difference from cdriscv-32s-20

This variant is a faithful port of variant 2's pad ring with exactly one
ring-level difference: **variant 1 has no JTAG**. Variant 2's four JTAG input
pads (`tck_i`/`tms_i`/`tdi_i`/`trst_ni`) and its single tri-state `tdo_o` pad
are absent, so the south side carries 17 pads instead of 22 and the chip has
**100 pads** where variant 2 has 105. Every other decision — AMS to the west
face, the QSPI group beside the south-east corner, APB/retire not padded,
`boot_addr_i` tied to 0, the power-pad quads — is identical.

## Die

| | |
|---|---|
| Die | **2400 × 3500 µm** (8.40 mm²) |
| Ring depth per edge | 140 µm sealring allowance (`PAD_EDGE_SPACING`) + 180 µm pad depth |
| Core area | [350, 350, 2050, 3150] (1700 × 2800 µm) |
| Pads | 100 (84 signal + 16 supply) + 4 × `sg13g2_Corner` |
| Pad cell pitch | 80 µm wide × 180 µm deep (from `sg13g2_io.lef`), ring gaps filled with `sg13g2_Filler*` |
| TCM macros | 6 × RM_IHPSG13 SRAM, same I-TCM-south / D-TCM-north arrangement as the subsys floorplan, relocated into the new core |

Side occupancy (pad count / spacing between pads): south 17 / 22 µm,
east 34 / 4 µm, north 19 / 12 µm, west 30 / 14 µm. The same 2400 × 3500 µm die
as variant 2 is kept (a faithful port); removing the five JTAG pads only widens
the south-side fill.

## Pinout plan

- **South** — system clock domain entry (`clk_i`, `rst_ni`, `fetch_enable_i`),
  the safety status outputs (`err_pin_o`, `reset_req_o`, `fault_any_o`,
  `core_sleep_o`), and the QSPI boot flash group (`qspi_sclk_o`, `qspi_cs_no`,
  `qspi_io[3:0]`) beside the south-east corner.
- **East** — `fault_ext_i[15:0]` and `irq_i[13:0]` (digital board face).
- **North** — DAC bundle at the west end (adjacent to the analog face) and the
  reference-clock domain (`ref_clk_i`, `ref_rst_ni`) at the east end.
- **West** — the analog companion die face: ADC interface, `atest_*`,
  `ana_flag_i`.

The four QSPI data lines are `sg13g2_IOPadInOut4mA` (the pad equation
`assign pad = c2p_en ? c2p : 1'bz;` plus the `p2c` input path), one chip
`inout qspi_io[3:0]`: per bit `c2p` ⇐ `qspi_io_o`, `p2c` ⇒ `qspi_io_i`,
`c2p_en` ⇐ `qspi_io_oe_o` — the boot loader drives the enables per SPI phase,
and in quad data phases all four lines are flash-driven.

## Power pads

One quad per side (16 total): `sg13g2_IOPadVdd`/`Vss` (core 1.2 V) and
`sg13g2_IOPadIOVdd`/`IOVss` (3.3 V pad ring) — at least one pair per side of
each domain, per the IO library's ring-abutment scheme. Supply distribution is
by ring abutment (`connect_by_abutment` in `OpenROAD.PadRing`); the pad
instances exist in the netlist as `(* keep *)` shells with no logic terminals.
IR-drop-driven addition of further pairs is a post-layout decision.

## What is absent, and why

- **JTAG**: variant 1 has no debug TAP; the JTAG/TDO pads are not present.
- **ADC/analog**: this chip contains **no ADC**. All AMS interface signals
  (`adc_*`, `dac_*`, `atest_*`, `ana_flag_*`) go to pads for the external
  analog companion die on the west face.
- **Expansion APB** (`ext_p*`, 78 wires): unused on this die. Inputs tied
  benign (`ext_pready_i = 1`, `ext_pslverr_i = 0`, `ext_prdata_i = 0`);
  outputs unconnected.
- **Retire trace** (`retire_*`, 66 wires): verification-only; unconnected.
- **`boot_addr_i`**: tied to `32'h0000_0000` inside the chip top, mirroring
  `flow/cdriscv_subsys_hard.sv` (finding V18) — the chip *is* the hard top, so
  `cdriscv_subsys` is instantiated directly.
- **Bondpads**: the PDK's LibreLane IO config names `bondpad_70x70`, but no
  such macro exists in `sg13g2_io.lef`/`.gds`; `PAD_BONDPAD_NAME` is nulled in
  `config_chip.json` (placing it would abort the pad step). Assembly-level
  decision, later.

## Lint

`cdriscv_chip` lints clean (exit 0, no warnings) under:

```
verilator --lint-only -sv --timing -Wall --timescale 1ns/1ps \
  --top-module cdriscv_chip \
  verif/lint/waivers.vlt $(grep -v '^//' rtl/cdriscv_files.f) \
  rtl/chip/cdriscv_chip.sv \
  $PDK_ROOT/ihp-sg13g2/libs.ref/sg13g2_io/verilog/sg13g2_io.v
```

The PDK pad-cell models (`sg13g2_io.v`) must be read so the pad instances
resolve — a missing module is a hard `MODMISSING` error, not a warning.
`--timescale 1ns/1ps` gives every module a default timescale so the vendor
models (which carry one) do not raise `TIMESCALEMOD` against our RTL (which does
not), mirroring the `lint-tb` target's rationale. Four rules are waived
file-scoped in `verif/lint/waivers.vlt` (a "FULL-CHIP lint only" section), each
justified there and none of which touches the strict `-Wall` lint of
`cdriscv_subsys`: `SPECIFYIGN` and `DECLFILENAME` on the vendor `sg13g2_io.v`,
and `PINMISSING` (pad supply ports unconnected — the same waiver
`config_chip.json` hands LibreLane's linter) and `PINCONNECTEMPTY` (the unpadded
APB/retire outputs left open) on `cdriscv_chip.sv`. See `flow/run_chip.sh` for
the hardening invocation (out of scope here).

## Pinout table

Pad numbering counter-clockwise from the south-west corner; per-side positions
ascend west→east (S, N) and south→north (E, W). List order in
`PAD_SOUTH/EAST/NORTH/WEST` *is* the placement data — `OpenROAD.PadRing`
spreads each side evenly.

<!-- BEGIN GENERATED PINOUT -->
| pad | pos | chip net | IO cell | drive |
|---|---|---|---|---|
| 1 | S01 | `(pad ring)` | `sg13g2_IOPadIOVss` | - |
| 2 | S02 | `(pad ring)` | `sg13g2_IOPadIOVdd` | - |
| 3 | S03 | `(pad ring)` | `sg13g2_IOPadVdd` | - |
| 4 | S04 | `(pad ring)` | `sg13g2_IOPadVss` | - |
| 5 | S05 | `clk_i` | `sg13g2_IOPadIn` | - |
| 6 | S06 | `rst_ni` | `sg13g2_IOPadIn` | - |
| 7 | S07 | `fetch_enable_i` | `sg13g2_IOPadIn` | - |
| 8 | S08 | `err_pin_o` | `sg13g2_IOPadOut4mA` | 4 mA |
| 9 | S09 | `reset_req_o` | `sg13g2_IOPadOut4mA` | 4 mA |
| 10 | S10 | `fault_any_o` | `sg13g2_IOPadOut4mA` | 4 mA |
| 11 | S11 | `core_sleep_o` | `sg13g2_IOPadOut4mA` | 4 mA |
| 12 | S12 | `qspi_sclk_o` | `sg13g2_IOPadOut4mA` | 4 mA |
| 13 | S13 | `qspi_cs_no` | `sg13g2_IOPadOut4mA` | 4 mA |
| 14 | S14 | `qspi_io[0]` | `sg13g2_IOPadInOut4mA` | 4 mA |
| 15 | S15 | `qspi_io[1]` | `sg13g2_IOPadInOut4mA` | 4 mA |
| 16 | S16 | `qspi_io[2]` | `sg13g2_IOPadInOut4mA` | 4 mA |
| 17 | S17 | `qspi_io[3]` | `sg13g2_IOPadInOut4mA` | 4 mA |
| 18 | E01 | `fault_ext_i[0]` | `sg13g2_IOPadIn` | - |
| 19 | E02 | `fault_ext_i[1]` | `sg13g2_IOPadIn` | - |
| 20 | E03 | `fault_ext_i[2]` | `sg13g2_IOPadIn` | - |
| 21 | E04 | `fault_ext_i[3]` | `sg13g2_IOPadIn` | - |
| 22 | E05 | `fault_ext_i[4]` | `sg13g2_IOPadIn` | - |
| 23 | E06 | `fault_ext_i[5]` | `sg13g2_IOPadIn` | - |
| 24 | E07 | `fault_ext_i[6]` | `sg13g2_IOPadIn` | - |
| 25 | E08 | `fault_ext_i[7]` | `sg13g2_IOPadIn` | - |
| 26 | E09 | `fault_ext_i[8]` | `sg13g2_IOPadIn` | - |
| 27 | E10 | `fault_ext_i[9]` | `sg13g2_IOPadIn` | - |
| 28 | E11 | `fault_ext_i[10]` | `sg13g2_IOPadIn` | - |
| 29 | E12 | `fault_ext_i[11]` | `sg13g2_IOPadIn` | - |
| 30 | E13 | `fault_ext_i[12]` | `sg13g2_IOPadIn` | - |
| 31 | E14 | `fault_ext_i[13]` | `sg13g2_IOPadIn` | - |
| 32 | E15 | `fault_ext_i[14]` | `sg13g2_IOPadIn` | - |
| 33 | E16 | `fault_ext_i[15]` | `sg13g2_IOPadIn` | - |
| 34 | E17 | `(pad ring)` | `sg13g2_IOPadVdd` | - |
| 35 | E18 | `(pad ring)` | `sg13g2_IOPadVss` | - |
| 36 | E19 | `(pad ring)` | `sg13g2_IOPadIOVdd` | - |
| 37 | E20 | `(pad ring)` | `sg13g2_IOPadIOVss` | - |
| 38 | E21 | `irq_i[0]` | `sg13g2_IOPadIn` | - |
| 39 | E22 | `irq_i[1]` | `sg13g2_IOPadIn` | - |
| 40 | E23 | `irq_i[2]` | `sg13g2_IOPadIn` | - |
| 41 | E24 | `irq_i[3]` | `sg13g2_IOPadIn` | - |
| 42 | E25 | `irq_i[4]` | `sg13g2_IOPadIn` | - |
| 43 | E26 | `irq_i[5]` | `sg13g2_IOPadIn` | - |
| 44 | E27 | `irq_i[6]` | `sg13g2_IOPadIn` | - |
| 45 | E28 | `irq_i[7]` | `sg13g2_IOPadIn` | - |
| 46 | E29 | `irq_i[8]` | `sg13g2_IOPadIn` | - |
| 47 | E30 | `irq_i[9]` | `sg13g2_IOPadIn` | - |
| 48 | E31 | `irq_i[10]` | `sg13g2_IOPadIn` | - |
| 49 | E32 | `irq_i[11]` | `sg13g2_IOPadIn` | - |
| 50 | E33 | `irq_i[12]` | `sg13g2_IOPadIn` | - |
| 51 | E34 | `irq_i[13]` | `sg13g2_IOPadIn` | - |
| 52 | N01 | `dac_we_o` | `sg13g2_IOPadOut4mA` | 4 mA |
| 53 | N02 | `dac_data_o[0]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 54 | N03 | `dac_data_o[1]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 55 | N04 | `dac_data_o[2]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 56 | N05 | `dac_data_o[3]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 57 | N06 | `dac_data_o[4]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 58 | N07 | `dac_data_o[5]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 59 | N08 | `dac_data_o[6]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 60 | N09 | `dac_data_o[7]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 61 | N10 | `dac_data_o[8]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 62 | N11 | `dac_data_o[9]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 63 | N12 | `dac_data_o[10]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 64 | N13 | `dac_data_o[11]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 65 | N14 | `(pad ring)` | `sg13g2_IOPadVdd` | - |
| 66 | N15 | `(pad ring)` | `sg13g2_IOPadVss` | - |
| 67 | N16 | `(pad ring)` | `sg13g2_IOPadIOVdd` | - |
| 68 | N17 | `(pad ring)` | `sg13g2_IOPadIOVss` | - |
| 69 | N18 | `ref_clk_i` | `sg13g2_IOPadIn` | - |
| 70 | N19 | `ref_rst_ni` | `sg13g2_IOPadIn` | - |
| 71 | W01 | `atest_en_o` | `sg13g2_IOPadOut4mA` | 4 mA |
| 72 | W02 | `atest_sel_o[0]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 73 | W03 | `atest_sel_o[1]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 74 | W04 | `atest_sel_o[2]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 75 | W05 | `atest_sel_o[3]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 76 | W06 | `ana_flag_i[0]` | `sg13g2_IOPadIn` | - |
| 77 | W07 | `ana_flag_i[1]` | `sg13g2_IOPadIn` | - |
| 78 | W08 | `ana_flag_i[2]` | `sg13g2_IOPadIn` | - |
| 79 | W09 | `ana_flag_i[3]` | `sg13g2_IOPadIn` | - |
| 80 | W10 | `(pad ring)` | `sg13g2_IOPadVdd` | - |
| 81 | W11 | `(pad ring)` | `sg13g2_IOPadVss` | - |
| 82 | W12 | `adc_start_o` | `sg13g2_IOPadOut4mA` | 4 mA |
| 83 | W13 | `adc_ch_o[0]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 84 | W14 | `adc_ch_o[1]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 85 | W15 | `adc_ch_o[2]` | `sg13g2_IOPadOut4mA` | 4 mA |
| 86 | W16 | `adc_valid_i` | `sg13g2_IOPadIn` | - |
| 87 | W17 | `adc_data_i[0]` | `sg13g2_IOPadIn` | - |
| 88 | W18 | `adc_data_i[1]` | `sg13g2_IOPadIn` | - |
| 89 | W19 | `adc_data_i[2]` | `sg13g2_IOPadIn` | - |
| 90 | W20 | `adc_data_i[3]` | `sg13g2_IOPadIn` | - |
| 91 | W21 | `adc_data_i[4]` | `sg13g2_IOPadIn` | - |
| 92 | W22 | `adc_data_i[5]` | `sg13g2_IOPadIn` | - |
| 93 | W23 | `adc_data_i[6]` | `sg13g2_IOPadIn` | - |
| 94 | W24 | `adc_data_i[7]` | `sg13g2_IOPadIn` | - |
| 95 | W25 | `adc_data_i[8]` | `sg13g2_IOPadIn` | - |
| 96 | W26 | `adc_data_i[9]` | `sg13g2_IOPadIn` | - |
| 97 | W27 | `adc_data_i[10]` | `sg13g2_IOPadIn` | - |
| 98 | W28 | `adc_data_i[11]` | `sg13g2_IOPadIn` | - |
| 99 | W29 | `(pad ring)` | `sg13g2_IOPadIOVdd` | - |
| 100 | W30 | `(pad ring)` | `sg13g2_IOPadIOVss` | - |
<!-- END GENERATED PINOUT -->
