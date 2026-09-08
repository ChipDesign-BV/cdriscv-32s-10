#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# gen_padring.py -- generate the cdriscv-32s-10 FULL-CHIP pad ring.
#
# PORTED from cdriscv-32s-20/scripts/gen_padring.py.  Variant 1 differs
# from variant 2 in exactly two ways that touch the ring:
#   * NO JTAG.  Variant 1's subsystem has no tck_i/tms_i/tdi_i/trst_ni/
#     tdo_o/tdo_oe_o ports, so the four JTAG input pads and the single
#     tri-state TDO pad of variant 2 are removed (5 fewer pads).
#   * BootEnable.  Variant 1's cdriscv_subsys defaults BootEnable=0 (the
#     signed-off configuration), the OPPOSITE of variant 2.  This chip
#     is the flash-boot build, so the chip top instantiates the subsys
#     with BootEnable=1 and routes the five QSPI ports to pads.
# Everything else (AMS to the west face, APB/retire not padded,
# boot_addr_i tied to 0, the QSPI group beside the south-east corner) is
# a verbatim port of variant 2's decisions.
#
# Emits (never edits any tracked/existing flow input):
#   rtl/chip/cdriscv_chip.sv          chip top: IO cell instances + subsys
#   flow/config_chip.json             LibreLane 3 "Chip"-flow configuration
#   doc/chip.md                       pinout table refreshed between markers
#                                     (only if the file already exists)
#
# Design rules this generator enforces (CLAUDE.md section 3: a generator
# must assert against the reference it claims to implement, and never
# "fix" a mismatch by editing the reference):
#   * The subsystem port list is PARSED from rtl/cdriscv_subsys.sv and
#     asserted against the expected table below.  Drift aborts the run.
#   * Pad / corner / site geometry is READ from the PDK LEF, not hard-coded.
#   * The per-side placement arithmetic of LibreLane's pad_cfg.tcl is
#     reproduced here and every error branch of that script is asserted
#     against, so a die size that cannot place aborts at generation time.
#   * flow/config.json is READ (for the VERILOG_FILES list and the shared
#     settings) and never written.
import json
import math
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PDK = Path("/foss/pdks/ihp-sg13g2")
IO_LEF = PDK / "libs.ref/sg13g2_io/lef/sg13g2_io.lef"
SUBSYS_SV = REPO / "rtl/cdriscv_subsys.sv"
CONFIG_IN = REPO / "flow/config.json"
CHIP_SV = REPO / "rtl/chip/cdriscv_chip.sv"
CONFIG_OUT = REPO / "flow/config_chip.json"
DOC_MD = REPO / "doc/chip.md"

# ----------------------------------------------------------------------
# 1. PDK geometry, read from the LEF (do not hard-code -- CLAUDE.md 5)
# ----------------------------------------------------------------------
def lef_sizes(lef_path):
    text = lef_path.read_text()
    sizes = {}
    for m in re.finditer(r"(MACRO|SITE)\s+(\S+)\n(.*?)\nEND \2", text, re.S):
        sm = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)\s*;", m.group(3))
        if sm:
            sizes[m.group(2)] = (float(sm.group(1)), float(sm.group(2)))
    return sizes

SIZES = lef_sizes(IO_LEF)
PAD_W, PAD_D = SIZES["sg13g2_IOPadIn"]        # 80 x 180 expected
CORNER_W, _ = SIZES["sg13g2_Corner"]          # 180 x 180 expected
SITE_W, _ = SIZES["sg13g2_ioSite"]            # 1 x 180 expected
assert (PAD_W, PAD_D) == (80.0, 180.0), f"pad size changed: {PAD_W}x{PAD_D}"
assert CORNER_W == 180.0, f"corner size changed: {CORNER_W}"
assert SITE_W == 1.0, f"io site width changed: {SITE_W}"
for cell in ("sg13g2_IOPadOut4mA", "sg13g2_IOPadTriOut4mA",
             "sg13g2_IOPadInOut4mA", "sg13g2_IOPadVdd",
             "sg13g2_IOPadVss", "sg13g2_IOPadIOVdd", "sg13g2_IOPadIOVss"):
    assert SIZES[cell] == (80.0, 180.0), f"{cell} not 80x180: {SIZES[cell]}"

PAD_EDGE_SPACING = 140.0   # PDK sg13g2_io/config.tcl (sealring allowance)
SPACING_MULTIPLE = 2       # even spacing keeps space_side integral (below)

# ----------------------------------------------------------------------
# 2. Subsystem port list, parsed from the RTL and asserted
# ----------------------------------------------------------------------
PARAM_WIDTHS = {"NUM_EXT_FAULTS": 16}  # rtl/core/cdriscv_pkg.sv line 159

def parse_ports(sv_path):
    text = sv_path.read_text()
    m = re.search(r"module\s+cdriscv_subsys\b.*?\)\s*\((.*?)\);",
                  text, re.S)
    assert m, "cannot locate subsys port list"
    ports = {}
    for pm in re.finditer(
            r"^\s*(input|output)\s+logic\s*(?:\[([^\]]+):0\])?\s*(\w+)\s*,?\s*$",
            m.group(1), re.M):
        direction, msb, name = pm.groups()
        if msb is None:
            width = 1
        elif msb.isdigit():
            width = int(msb) + 1
        else:
            pmatch = re.fullmatch(r"(\w+)-1", msb.strip())
            assert pmatch and pmatch.group(1) in PARAM_WIDTHS, \
                f"unknown range [{msb}:0] on {name}"
            width = PARAM_WIDTHS[pmatch.group(1)]
        ports[name] = (direction, width)
    return ports

# Variant 1 subsystem port table -- IDENTICAL to variant 2 except the
# six JTAG ports (tck_i/tms_i/tdi_i/trst_ni/tdo_o/tdo_oe_o) do not exist.
EXPECTED = {
    "clk_i": ("input", 1), "rst_ni": ("input", 1),
    "ref_clk_i": ("input", 1), "ref_rst_ni": ("input", 1),
    "boot_addr_i": ("input", 32), "fetch_enable_i": ("input", 1),
    "irq_i": ("input", 14), "fault_ext_i": ("input", 16),
    "err_pin_o": ("output", 1), "reset_req_o": ("output", 1),
    "fault_any_o": ("output", 1),
    "adc_start_o": ("output", 1), "adc_ch_o": ("output", 3),
    "adc_valid_i": ("input", 1), "adc_data_i": ("input", 12),
    "dac_data_o": ("output", 12), "dac_we_o": ("output", 1),
    "atest_en_o": ("output", 1), "atest_sel_o": ("output", 4),
    "ana_flag_i": ("input", 4),
    "ext_psel_o": ("output", 1), "ext_penable_o": ("output", 1),
    "ext_paddr_o": ("output", 12), "ext_pwrite_o": ("output", 1),
    "ext_pwdata_o": ("output", 32), "ext_pstrb_o": ("output", 4),
    "ext_prdata_i": ("input", 32), "ext_pready_i": ("input", 1),
    "ext_pslverr_i": ("input", 1),
    "core_sleep_o": ("output", 1),
    "retire_valid_o": ("output", 1), "retire_pc_o": ("output", 32),
    "retire_instr_o": ("output", 32),
    "qspi_sclk_o": ("output", 1), "qspi_cs_no": ("output", 1),
    "qspi_io_i": ("input", 4), "qspi_io_o": ("output", 4),
    "qspi_io_oe_o": ("output", 4),
}

ports = parse_ports(SUBSYS_SV)
if ports != EXPECTED:
    missing = set(EXPECTED) - set(ports)
    extra = set(ports) - set(EXPECTED)
    diff = {k: (ports.get(k), EXPECTED.get(k))
            for k in set(ports) | set(EXPECTED)
            if ports.get(k) != EXPECTED.get(k)}
    sys.exit(f"FATAL: subsys port list drifted from this generator's "
             f"reference.\n  missing={missing}\n  extra={extra}\n  diff={diff}\n"
             "Update EXPECTED (and the pinout) deliberately -- do not edit "
             "the RTL to match.")

# Ports deliberately NOT padded (documented in the chip-top header):
UNPADDED_TIED = {          # inputs tied benign inside the chip top
    "boot_addr_i": "32'h0000_0000",   # hard boot address (mirrors _hard.sv)
    "ext_prdata_i": "32'h0000_0000",
    "ext_pready_i": "1'b1",           # expansion APB always ready, no stall
    "ext_pslverr_i": "1'b0",
}
UNPADDED_OPEN = [          # outputs left unconnected
    "ext_psel_o", "ext_penable_o", "ext_paddr_o", "ext_pwrite_o",
    "ext_pwdata_o", "ext_pstrb_o",
    "retire_valid_o", "retire_pc_o", "retire_instr_o",
]
#
# The three QSPI io buses (qspi_io_i / qspi_io_o / qspi_io_oe_o) map onto
# FOUR bidirectional pads and ONE chip-level inout port qspi_io[3:0]:
# per bit, c2p = io_o, p2c = io_i, c2p_en = io_oe_o (the pad model
# implements `assign pad = c2p_en ? c2p : 1'bz; assign p2c = pad;`).
QSPI_IO_PORTS = ("qspi_io_i", "qspi_io_o", "qspi_io_oe_o")

# ----------------------------------------------------------------------
# 3. The pinout: ordered per side.  List order == ascending coordinate
#    (south/north rows run west->east, west/east rows run south->north).
# ----------------------------------------------------------------------
IN_ = "sg13g2_IOPadIn"
OUT4 = "sg13g2_IOPadOut4mA"
BID4 = "sg13g2_IOPadInOut4mA"
PWR = {"vdd": "sg13g2_IOPadVdd", "vss": "sg13g2_IOPadVss",
       "iovdd": "sg13g2_IOPadIOVdd", "iovss": "sg13g2_IOPadIOVss"}

def sig(port, bit=None):
    d, w = EXPECTED[port]
    assert bit is None if w == 1 else (bit is not None and 0 <= bit < w)
    cell = IN_ if d == "input" else OUT4
    return ("sig", port, bit, cell)

def pwr(kind, side_letter):
    return ("pwr", f"{kind}_{side_letter}", None, PWR[kind])

def qio(bit):
    # one bidirectional QSPI data pad; serves one bit of ALL THREE
    # qspi_io_* subsystem ports at once
    assert 0 <= bit < 4
    return ("qio", "qspi_io", bit, BID4)

def bus(port):
    return [sig(port, b) for b in range(EXPECTED[port][1])]

PINOUT = {
    # SOUTH: system clock domain entry, safety status outputs, and the
    # QSPI boot flash grouped at the south-east corner.  Variant 1 has no
    # JTAG, so this side carries 17 pads (variant 2's 22 minus 5).
    "south": [
        pwr("iovss", "s"), pwr("iovdd", "s"),
        pwr("vdd", "s"), pwr("vss", "s"),
        sig("clk_i"), sig("rst_ni"), sig("fetch_enable_i"),
        sig("err_pin_o"), sig("reset_req_o"), sig("fault_any_o"),
        sig("core_sleep_o"),
        sig("qspi_sclk_o"), sig("qspi_cs_no"),
        qio(0), qio(1), qio(2), qio(3),
    ],
    # EAST: external fault inputs then interrupts (digital board side).
    "east": (
        bus("fault_ext_i")
        + [pwr("vdd", "e"), pwr("vss", "e"), pwr("iovdd", "e"), pwr("iovss", "e")]
        + bus("irq_i")
    ),
    # NORTH: DAC bundle at the west end (adjacent to the analog west side),
    # reference-clock domain at the east end near the clock monitor.
    "north": (
        [sig("dac_we_o")] + bus("dac_data_o")
        + [pwr("vdd", "n"), pwr("vss", "n"), pwr("iovdd", "n"), pwr("iovss", "n")]
        + [sig("ref_clk_i"), sig("ref_rst_ni")]
    ),
    # WEST: the analog companion die face -- ADC, analog test, analog flags.
    "west": (
        [sig("atest_en_o")] + bus("atest_sel_o") + bus("ana_flag_i")
        + [pwr("vdd", "w"), pwr("vss", "w")]
        + [sig("adc_start_o")] + bus("adc_ch_o") + [sig("adc_valid_i")]
        + bus("adc_data_i")
        + [pwr("iovdd", "w"), pwr("iovss", "w")]
    ),
}

def inst_name(entry):
    _, port, bit, _ = entry
    return f"pad_{port}" if bit is None else f"pad_{port}_{bit}"

# every signal port padded exactly once, full width; each qio pad covers
# one bit of all three qspi_io_* ports
padded_bits = {}
qio_bits = set()
for side, entries in PINOUT.items():
    for e in entries:
        if e[0] == "sig":
            key = (e[1], e[2])
            assert key not in padded_bits, f"double pad: {key}"
            padded_bits[key] = side
        elif e[0] == "qio":
            assert e[2] not in qio_bits, f"double qio pad: {e[2]}"
            qio_bits.add(e[2])
assert qio_bits == {0, 1, 2, 3}, qio_bits
for port, (d, w) in EXPECTED.items():
    if port in UNPADDED_TIED or port in UNPADDED_OPEN:
        assert not any(p == port for p, _ in padded_bits), f"{port} padded"
        continue
    if port in QSPI_IO_PORTS:
        continue                       # covered by the qio pads, asserted above
    want = {(port, None)} if w == 1 else {(port, b) for b in range(w)}
    have = {k for k in padded_bits if k[0] == port}
    assert have == want, f"{port}: padded bits {have} != {want}"

N_SIG = sum(1 for k in padded_bits) + len(qio_bits)
N_PWR = sum(1 for es in PINOUT.values() for e in es if e[0] == "pwr")
assert N_SIG == 84 and N_PWR == 16, (N_SIG, N_PWR)

# ----------------------------------------------------------------------
# 4. Die size + the exact pad_cfg.tcl placement arithmetic
# ----------------------------------------------------------------------
DIE_W, DIE_H = 2400.0, 3500.0
CORE_MARGIN = 30.0          # gap between inner pad edge and the core rows
ring_depth = PAD_EDGE_SPACING + PAD_D           # 320 from each die edge
CORE = [ring_depth + CORE_MARGIN, ring_depth + CORE_MARGIN,
        DIE_W - ring_depth - CORE_MARGIN, DIE_H - ring_depth - CORE_MARGIN]

placement_report = {}
for side, entries in PINOUT.items():
    n = len(entries)
    sum_w = PAD_W * n
    span = (DIE_W if side in ("south", "north") else DIE_H)
    side_width = span - 2 * PAD_EDGE_SPACING - 2 * CORNER_W
    fill = side_width - sum_w
    assert fill >= 0, f"{side}: pads ({sum_w}) exceed side width ({side_width})"
    sbp = math.floor(fill / (n + 1) / SPACING_MULTIPLE) * SPACING_MULTIPLE
    space_side = (fill - sbp * (n - 1)) / 2
    # pad_cfg.tcl errors unless space_side is a multiple of the site width
    assert space_side >= 0 and space_side == math.floor(space_side / SITE_W) * SITE_W, \
        f"{side}: corner gap {space_side} not a multiple of site width {SITE_W}"
    placement_report[side] = dict(pads=n, fill=fill, spacing=sbp,
                                  corner_gap=space_side)

# ----------------------------------------------------------------------
# 5. Chip-top Verilog
# ----------------------------------------------------------------------
side_order = ["south", "east", "north", "west"]   # counter-clockwise numbering
rows = []
padno = 0
for side in side_order:
    for i, e in enumerate(PINOUT[side], 1):
        padno += 1
        kind, port, bit, cell = e
        if kind == "sig":
            netname = port if bit is None else f"{port}[{bit}]"
            drive = ("4 mA" if cell == OUT4 else "-")
        elif kind == "qio":
            netname = f"{port}[{bit}]"
            drive = "4 mA"
        else:
            netname = "(pad ring)"
            drive = "-"
        rows.append((padno, side.upper()[0] + f"{i:02d}", netname, cell, drive))

tablelines = ["// pad  pos  chip net          cell                    drive",
              "// ---  ---  ----------------  ----------------------  -----"]
for pn, pos, net, cell, drv in rows:
    tablelines.append(f"// {pn:3d}  {pos}  {net:<16s}  {cell:<22s}  {drv}")
pad_table = "\n".join(tablelines)

def port_decl(port):
    if port == "qspi_io":
        return "    inout  wire [3:0] qspi_io"
    d, w = EXPECTED[port]
    dstr = "input  wire" if d == "input" else "output wire"
    wstr = f"[{w-1}:0] " if w > 1 else ""
    return f"    {dstr} {wstr}{port}"

chip_ports = [p for p, _ in sorted(
    ((p, EXPECTED[p]) for p in EXPECTED
     if p not in UNPADDED_TIED and p not in UNPADDED_OPEN
     and p not in QSPI_IO_PORTS),
    key=lambda kv: list(EXPECTED).index(kv[0]))] + ["qspi_io"]

core_nets = []
for p in chip_ports:
    if p == "qspi_io":
        continue                     # its core nets are the three below
    d, w = EXPECTED[p]
    wstr = f"[{w-1}:0] " if w > 1 else ""
    core_nets.append(f"  wire {wstr}{p}_core;")
for p in QSPI_IO_PORTS:
    core_nets.append(f"  wire [3:0] {p}_core;")

pad_insts = []
for side in side_order:
    pad_insts.append(f"  // ---- {side.upper()} row (listed west->east / south->north) ----")
    for e in PINOUT[side]:
        kind, port, bit, cell = e
        name = inst_name(e)
        if kind == "pwr":
            pad_insts.append(f"  (* keep *) {cell} {name} ();")
            continue
        sel = "" if bit is None else f"[{bit}]"
        if kind == "qio":
            conn = (f".pad(qspi_io{sel}), .c2p(qspi_io_o_core{sel}), "
                    f".p2c(qspi_io_i_core{sel}), "
                    f".c2p_en(qspi_io_oe_o_core{sel})")
        elif cell == IN_:
            conn = f".pad({port}{sel}), .p2c({port}_core{sel})"
        else:  # OUT4
            conn = f".pad({port}{sel}), .c2p({port}_core{sel})"
        pad_insts.append(f"  (* keep *) {cell} {name} ({conn});")

sub_conns = []
for p in EXPECTED:
    if p in UNPADDED_TIED:
        sub_conns.append(f"      .{p:<16s}({UNPADDED_TIED[p]})")
    elif p in UNPADDED_OPEN:
        sub_conns.append(f"      .{p:<16s}()")
    else:
        sub_conns.append(f"      .{p:<16s}({p}_core)")
sub_conn_str = ",\n".join(sub_conns)

power_note = """\
// Power pads (one quad VDD/VSS core 1.2 V + IOVDD/IOVSS pad-ring 3.3 V per
// side, 16 total): supply-only cells with no logic terminals.  Their supply
// nets connect by ring abutment in layout (OpenROAD connect_by_abutment);
// in this netlist they are instance shells kept alive by (* keep *).
//
// NO pad instance references its vdd/vss/iovdd/iovss supply ports: the
// liberty view librelane hands to synthesis as the blackbox has no such
// ports (supplies are pg_pins), so naming them is an elaboration error
// there, while leaving them unconnected is correct everywhere."""

CHIP_SV.parent.mkdir(parents=True, exist_ok=True)
CHIP_SV.write_text(f"""\
// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 FULL-CHIP top: cdriscv_subsys wrapped in an IHP
// SG13G2 IO pad ring (sg13g2_io library).  GENERATED by
// scripts/gen_padring.py -- edit the generator, not this file.
//
// THIS CHIP CONTAINS NO ADC.  All AMS interface signals (adc_*, dac_*,
// atest_*, ana_flag_*) go to pads on the WEST side (DAC bundle on the
// adjacent north-west corner) for an external analog companion die.
//
// THIS CHIP HAS NO JTAG.  Variant 1's subsystem does not carry the
// debug TAP, so the four JTAG input pads and the tri-state TDO pad of
// variant 2 are absent -- the only pad-count difference from variant 2.
//
// FLASH BOOT: cdriscv_subsys is instantiated with BootEnable=1 (its
// default is 0 -- the signed-off, TCM-preloaded configuration), so the
// QSPI boot loader is elaborated and its five ports reach pads.  The
// chip IS the hard top: cdriscv_subsys is instantiated directly with
// boot_addr_i tied to 32'h0000_0000, mirroring
// flow/cdriscv_subsys_hard.sv (finding V18: a non-constant PC reset
// load is an async-load flop no standard cell implements).
//
// NOT PADDED (documented decision, not an omission):
//   * SoC expansion APB (ext_p*, 78 wires): unused on this die.  Inputs
//     tied benign (ext_pready_i=1 so a stray access completes,
//     ext_pslverr_i=0, ext_prdata_i=0); outputs unconnected.
//   * Retire trace (retire_*, 66 wires): verification-only interface.
//     Outputs unconnected.
//
// QSPI boot flash: four sg13g2_IOPadInOut4mA data pads expose ONE chip
// inout bus qspi_io[3:0]; per bit c2p = qspi_io_o, p2c = qspi_io_i,
// c2p_en = qspi_io_oe_o (the pad model implements
//   assign pad = c2p_en ? c2p : 1'bz;
// plus the p2c input path).  The loader drives io_oe per SPI phase; in
// quad data phases all four lines are flash-driven inputs.  Grouped with
// qspi_sclk_o / qspi_cs_no beside the south-east corner.
//
// Die {DIE_W:.0f} x {DIE_H:.0f} um, {len(rows)} pads + 4 corners.
// Pad numbering runs counter-clockwise from the south-west corner;
// per-side positions ascend west->east (S, N) and south->north (E, W).
//
{pad_table}
//
{power_note}
`default_nettype none
module cdriscv_chip (
{",\n".join(port_decl(p) for p in chip_ports)}
);

  // core-side nets (pad p2c/c2p terminals)
{chr(10).join(core_nets)}

{chr(10).join(pad_insts)}

  cdriscv_subsys #(.BootEnable(1'b1)) u_sub (
{sub_conn_str}
  );

endmodule
`default_nettype wire
""")

# ----------------------------------------------------------------------
# 6. flow/config_chip.json -- derived from flow/config.json (read-only)
# ----------------------------------------------------------------------
cfg = json.loads(CONFIG_IN.read_text())
old_core = cfg["CORE_AREA"]

chip = dict(cfg)  # shallow copy; we replace what differs
chip["meta"] = {"version": 2, "flow": "Chip"}
chip["//"] = ("cdriscv-32s-10 FULL-CHIP -- LibreLane 3 'Chip' flow: "
              "subsys RTL + sg13g2_io pad ring.  GENERATED by "
              "scripts/gen_padring.py from flow/config.json; regenerate, "
              "do not hand-edit.")
chip["DESIGN_NAME"] = "cdriscv_chip"
# config.json still carries OpenLane-1-era keys.  This librelane build
# (3.1.0.dev2) hard-errors on PL_MACRO_HALO and warns on the FP_PDN_*
# names; translate them rather than inherit them.
if "PL_MACRO_HALO" in chip:
    halo = chip.pop("PL_MACRO_HALO").split()
    chip["FP_MACRO_HORIZONTAL_HALO"] = float(halo[0])
    chip["FP_MACRO_VERTICAL_HALO"] = float(halo[1])
if "FP_PDN_MACRO_HOOKS" in chip:
    hooks = chip.pop("FP_PDN_MACRO_HOOKS")
    chip["PDN_MACRO_CONNECTIONS"] = hooks
if "FP_PDN_ENABLE_MACROS_GRID" in chip:
    chip["PDN_CONNECT_MACROS_TO_GRID"] = chip.pop("FP_PDN_ENABLE_MACROS_GRID")
vf = [f for f in cfg["VERILOG_FILES"] if not f.endswith("cdriscv_subsys_hard.sv")]
assert len(vf) == len(cfg["VERILOG_FILES"]) - 1
chip["VERILOG_FILES"] = vf + ["dir::../rtl/chip/cdriscv_chip.sv"]
chip["FP_SIZING"] = "absolute"
chip["DIE_AREA"] = [0, 0, DIE_W, DIE_H]
chip["CORE_AREA"] = CORE
chip["//die"] = (f"Die {DIE_W:.0f}x{DIE_H:.0f}: ring depth is "
                 f"{PAD_EDGE_SPACING:.0f} (sealring, PAD_EDGE_SPACING) + "
                 f"{PAD_D:.0f} (pad depth) per edge, core inset a further "
                 f"{CORE_MARGIN:.0f}.  Sides hold S/E/N/W = "
                 f"{'/'.join(str(len(PINOUT[s])) for s in side_order)} pads "
                 f"of {PAD_W:.0f} um; per-side fill checked against "
                 "librelane pad_cfg.tcl arithmetic by the generator.")

# relocate the TCM macros into the new, larger core (same arrangement:
# I-TCM row on the south edge of the core, D-TCM row on the north edge)
dx = CORE[0] - old_core[0]
dy_south = CORE[1] - old_core[1]
dy_north = CORE[3] - old_core[3]
macros = json.loads(json.dumps(cfg["MACROS"]))  # deep copy
for mac in macros.values():
    for inst in mac["instances"].values():
        x, y = inst["location"]
        south_row = y < (old_core[1] + old_core[3]) / 2
        inst["location"] = [x + dx, y + (dy_south if south_row else dy_north)]
chip["MACROS"] = macros

# pad ring
chip["PAD_SOUTH"] = [inst_name(e) for e in PINOUT["south"]]
chip["PAD_EAST"] = [inst_name(e) for e in PINOUT["east"]]
chip["PAD_NORTH"] = [inst_name(e) for e in PINOUT["north"]]
chip["PAD_WEST"] = [inst_name(e) for e in PINOUT["west"]]
# PAD_CFG must survive every regeneration: it wires the terminal
# placement (pad_cfg_chip.tcl) without which global placement dies
# with GPL-0326.
chip["PAD_CFG"] = "dir::pad_cfg_chip.tcl"
chip["PAD_SPACING_MULTIPLE"] = SPACING_MULTIPLE
chip["//pads"] = ("Pad instance lists are ordered: ascending x for "
                  "south/north, ascending y for east/west.  Placement "
                  "coordinates are computed by OpenROAD.PadRing "
                  "(even spacing); this list order IS the placement data.")
chip["LINTER_DISABLE_WARNINGS"] = ["DECLFILENAME", "EOFNEWLINE", "PINMISSING"]
chip["//lint"] = ("PINMISSING added to the default waivers: pad supply ports "
                  "(vdd/vss/iovdd/iovss) are deliberately unconnected in the "
                  "netlist -- they connect by ring abutment, and the liberty "
                  "blackbox used by synthesis does not even declare them.")
chip["PAD_BONDPAD_NAME"] = None
chip["//bondpad"] = ("PDK sg13g2_io config.tcl names bondpad_70x70, but no "
                     "such macro exists in sg13g2_io.lef/gds -- placing it "
                     "would fail.  Bondpads are a later assembly decision.")
CONFIG_OUT.write_text(json.dumps(chip, indent=2) + "\n")

# ----------------------------------------------------------------------
# 7. doc/chip.md pinout table (between markers, if the doc exists)
# ----------------------------------------------------------------------
md = ["| pad | pos | chip net | IO cell | drive |",
      "|---|---|---|---|---|"]
for pn, pos, net, cell, drv in rows:
    md.append(f"| {pn} | {pos} | `{net}` | `{cell}` | {drv} |")
md_table = "\n".join(md)
B, E = "<!-- BEGIN GENERATED PINOUT -->", "<!-- END GENERATED PINOUT -->"
if DOC_MD.exists():
    doc = DOC_MD.read_text()
    if B in doc and E in doc:
        pre, rest = doc.split(B, 1)
        _, post = rest.split(E, 1)
        DOC_MD.write_text(pre + B + "\n" + md_table + "\n" + E + post)
        print(f"updated pinout table in {DOC_MD}")

print(f"wrote {CHIP_SV}")
print(f"wrote {CONFIG_OUT}")
print(f"die {DIE_W:.0f} x {DIE_H:.0f} um ({DIE_W*DIE_H/1e6:.2f} mm^2), "
      f"core {CORE}")
print(f"pads: {N_SIG} signal + {N_PWR} power = {N_SIG+N_PWR}, + 4 corners")
for side in side_order:
    print(f"  {side:5s}: {placement_report[side]}")
