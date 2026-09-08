#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Generate the xschem symbol for cdriscv_subsys from the RTL
# port list, so the symbol cannot drift from the module.  Rules honoured
# (see the tree's CLAUDE.md): solid lines and normal colours; the B
# (pin) records appear in EXACT module port order, because xschem's
# netlist pin order is the order of the B records and must match the
# subcircuit; every label sits on a short stub so text direction cannot
# put it on the body.
#
#   python3 scripts/gen_xschem_sym.py   # writes xschem/cdriscv_subsys.sym
#
# Buses are one pin each with verilog-style name[n:0]; xschem carries
# the name through verbatim.
import re, sys

SRC = 'rtl/cdriscv_subsys.sv'
OUT = 'xschem/cdriscv_subsys.sym'

text = open(SRC).read()
m = re.search(r'module\s+cdriscv_subsys.*?\)\s*\(\s*(.*?)\n\);', text, re.S)
if not m: sys.exit("port list not found")
body = m.group(1)

ports = []   # (name, dir, width)
for line in body.splitlines():
    line = line.split('//')[0].strip().rstrip(',')
    pm = re.match(r'(input|output|inout)\s+logic\s*(\[\s*(\d+)\s*:\s*0\s*\])?\s*(\w+)', line)
    if pm:
        d, _, hi, name = pm.groups()
        ports.append((name, d, int(hi)+1 if hi else 1))

ins  = [p for p in ports if p[1] == 'input']
outs = [p for p in ports if p[1] != 'input']

PITCH = 20; STUB = 20
H = (max(len(ins), len(outs)) + 1) * PITCH
W = 360
lines = []
lines.append('v {xschem version=3.4.5 file_version=1.2}')
lines.append('G {}')
lines.append('K {type=subcircuit')
lines.append('format="@name @pinlist @symname"')
lines.append('template="name=x1"')
lines.append('verilog_format="@name ( @@pinlist )"')
lines.append('}')
lines.append('V {}')
lines.append('S {}')
lines.append('E {}')
# body rectangle, layer 4 (symbol outline), solid
lines.append(f'L 4 {{0}} {{0}} ... placeholder')
lines = lines[:-1]
lines.append(f'B 5 0 0 0 0 {{name=__PLACEHOLDER__}}')
lines = lines[:-1]

def pin(x, y, name, direction):
    # B record: layer 5, small square centred on the pin end
    return (f'B 5 {x-2.5} {y-2.5} {x+2.5} {y+2.5} '
            f'{{name={name} dir={direction}}}')

recs, wires, texts = [], [], []
ypos = {}
for i,(name,d,w) in enumerate(ins):  ypos[name] = (i+1)*PITCH
for i,(name,d,w) in enumerate(outs): ypos.setdefault(name, (i+1)*PITCH)

# EXACT module port order for the B records:
for name,d,w in ports:
    label = name if w == 1 else f'{name}[{w-1}:0]'
    y = ypos[name]
    if d == 'input':
        recs.append(pin(-STUB, y, label, 'in'))
        wires.append(f'L 4 {-STUB} {y} 0 {y} {{}}')
        texts.append(f'T {{{label}}} {5} {y-4} 0 0 0.2 0.2 {{}}')
    else:
        recs.append(pin(W+STUB, y, label, 'out'))
        wires.append(f'L 4 {W} {y} {W+STUB} {y} {{}}')
        texts.append(f'T {{{label}}} {W-5} {y-4} 0 1 0.2 0.2 {{}}')

out = []
out.append('v {xschem version=3.4.5 file_version=1.2}')
out.append('K {type=subcircuit')
out.append('format="@name @pinlist @symname"')
out.append('template="name=x1"')
out.append('}')
out.append('V {}'); out.append('S {}'); out.append('E {}'); out.append('G {}')
# outline (solid, default layer 4)
out.append(f'L 4 0 0 {W} 0 {{}}')
out.append(f'L 4 {W} 0 {W} {H} {{}}')
out.append(f'L 4 {W} {H} 0 {H} {{}}')
out.append(f'L 4 0 {H} 0 0 {{}}')
out += wires + recs + texts
out.append(f'T {{cdriscv_subsys}} {W/2-110} {-18} 0 0 0.3 0.3 {{}}')
out.append(f'T {{@name}} {W/2-30} {H+6} 0 0 0.25 0.25 {{}}')

open(OUT,'w').write('\n'.join(out) + '\n')
print(f"{OUT}: {len(ports)} pins ({len(ins)} in, {len(outs)} out), body {W}x{H}")
