#!/usr/bin/env python3
"""Characterize a 3-input combinational cell (Majority or One Hot) with Spectre.

One transient per corner walks through all 56 ordered transitions between the 8
input states (single-input and simultaneous changes), so every case is exercised.
Measures, per transition: Y delay, glitch size, supply energy and average dynamic
power over one input period.  Eight more runs measure leakage in each static state.
Every transition is also checked against the truth table.

It reuses the cell's subcircuit from the newest ADE netlist (input.scs) containing
it, so run a testbench once in ADE first.  For the final report, run that testbench
through a config view pointing at the extracted view; the header of the results
then says POST-LAYOUT.

Usage:
    python3 logic_char.py --cell MAJ3 --func maj --area 3.8
    python3 logic_char.py --cell ONEHOT3 --func onehot --area 6.9
    python3 logic_char.py --cell MAJ3 --func maj --corners tt --netlist /path/input.scs

Outputs go to ~/logic_char_runs/<cell>/ : results.txt, transitions.csv, leakage.csv,
and netlist.scs (the subcircuit text used, for the report's extracted netlist).
"""
import argparse
import bisect
import csv
import glob
import os
import re
import shutil
import subprocess
import sys

CORNERS = [("ss", 125, 1.62), ("tt", 25, 1.80), ("ff", 0, 1.98)]
LICENSE = "27002@license.ece.vt.edu"
FALLBACK_MODELS = "/data/PDK/sky130a/sky130_release_0.1.0/models/sky130.lib.spice"
PORT_MAP = {"A": "a", "B": "b", "C": "c", "Y": "y",
            "VDD": "vdd_n", "VDD!": "vdd_n", "VPWR": "vdd_n", "VPB": "vdd_n",
            "GND": "0", "GND!": "0", "VSS": "0", "VSS!": "0", "VGND": "0", "VNB": "0"}
FUNCS = {
    "maj": lambda a, b, c: int(a + b + c >= 2),
    "onehot": lambda a, b, c: int(a + b + c == 1),
}
SETTLED_TAIL_W = 1e-6   # supply power allowed in the last 10% of a period


# ---------------------------------------------------------------- stimulus
def state_bits(s):
    return (s >> 2) & 1, (s >> 1) & 1, s & 1


def state_name(s):
    return "%d%d%d" % state_bits(s)


def all_transitions_sequence():
    """Eulerian circuit over the complete digraph on 8 states (Hierholzer).

    Returns 57 states starting and ending at 000; each of the 56 ordered pairs of
    different states appears exactly once as a consecutive pair.
    """
    remaining = {s: [d for d in range(8) if d != s] for s in range(8)}
    stack, path = [0], []
    while stack:
        s = stack[-1]
        if remaining[s]:
            stack.append(remaining[s].pop())
        else:
            path.append(stack.pop())
    path.reverse()
    return path


def pwl_wave(seq, bit, period, slew, vdd):
    """Wave list for one input.  Transition k starts at (k + 1) * period."""
    values = [state_bits(s)[bit] for s in seq]
    pts = [(0.0, values[0] * vdd)]
    for k in range(1, len(values)):
        if values[k] != values[k - 1]:
            t = k * period
            pts.append((t, values[k - 1] * vdd))
            pts.append((t + slew, values[k] * vdd))
    return pts


def format_pwl(name, node, pts):
    items = ["%.6g %.6g" % p for p in pts]
    rows = [" ".join(items[i:i + 6]) for i in range(0, len(items), 6)]
    return "%s (%s 0) vsource type=pwl wave=[ \\\n    %s ]" % (name, node, " \\\n    ".join(rows))


# ---------------------------------------------------------------- netlist handling
def find_netlist(cell):
    roots = [os.path.expanduser("~/simulation"), "/data/projects/vlsi_fall2026/kendaro"]
    pat = r"^\s*(inline\s+)?subckt\s+%s\b" % re.escape(cell)
    for root in roots:
        best = None
        for dirpath, _dirs, files in os.walk(root):
            if "input.scs" not in files:
                continue
            path = os.path.join(dirpath, "input.scs")
            try:
                with open(path, errors="replace") as f:
                    text = f.read()
            except OSError:
                continue
            if re.search(pat, text, re.M):
                mtime = os.path.getmtime(path)
                if best is None or mtime > best[0]:
                    best = (mtime, path)
        if best:
            return best[1]
    return None


def logical_lines(text):
    out, buf = [], ""
    for line in text.splitlines():
        stripped = line.rstrip()
        if stripped.endswith("\\"):
            buf += stripped[:-1] + " "
        else:
            out.append(buf + line)
            buf = ""
    if buf:
        out.append(buf)
    return out


def parse_netlist(path, cell):
    """Return (subckt text, model include lines, port list, parasitic R/C count)."""
    with open(path, errors="replace") as f:
        lines = logical_lines(f.read())
    blocks, cur, depth, includes = [], [], 0, []
    for ln in lines:
        s = ln.strip()
        if depth == 0 and re.match(r'include\s+"', s):
            includes.append(s)
        if re.match(r"(inline\s+)?subckt\s+\S+", s):
            depth += 1
        if depth > 0:
            cur.append(ln)
            if re.match(r"ends\b", s):
                depth -= 1
                if depth == 0:
                    blocks.append("\n".join(cur))
                    cur = []
    ports, names = None, []
    for b in blocks:
        m = re.match(r"\s*(?:inline\s+)?subckt\s+(\S+)\s*(.*)", b.splitlines()[0])
        if m:
            names.append(m.group(1))
            if m.group(1) == cell:
                ports = m.group(2).replace("(", " ").replace(")", " ").split()
    if ports is None:
        sys.exit("ERROR: no 'subckt %s' in %s. Subcircuits found: %s" % (cell, path, ", ".join(names) or "none"))
    upper = [p.upper() for p in ports]
    unknown = [p for p in ports if p.upper() not in PORT_MAP]
    if unknown:
        sys.exit("ERROR: unexpected pin name(s) %s on %s. Expected A B C Y VDD GND." % (unknown, cell))
    for need in "ABCY":
        if need not in upper:
            sys.exit("ERROR: %s has no pin %s (pins: %s)." % (cell, need, " ".join(ports)))
    mapped = [PORT_MAP[p] for p in upper]
    if "vdd_n" not in mapped or "0" not in mapped:
        sys.exit("ERROR: %s has no VDD/GND pins (pins: %s). Add them to the schematic." % (cell, " ".join(ports)))
    parasitics = 0
    for b in blocks:
        parasitics += len(re.findall(r"^\s*\S+\s*\([^)]*\)\s*(?:capacitor|resistor)\b", b, re.M))
    return "\n\n".join(blocks), includes, ports, parasitics


def model_includes(includes, corner, models):
    if models:
        return ['include "%s" section=%s' % (models, corner)]
    out = [re.sub(r"section\s*=\s*\S+", "section=" + corner, i) for i in includes if "section" in i]
    if not out:
        if not os.path.exists(FALLBACK_MODELS):
            sys.exit("ERROR: no model include in the netlist and %s not found. Use --models." % FALLBACK_MODELS)
        out = ['include "%s" section=%s' % (FALLBACK_MODELS, corner)]
    return out


# ---------------------------------------------------------------- spectre
def find_spectre():
    exe = shutil.which("spectre")
    if exe:
        return exe
    pats = ["/var/RFIC/cadtools/cadence/SPECTRE*/tools*/bin/spectre",
            "/var/RFIC/cadtools/cadence/*/tools*/bin/spectre",
            "/var/RFIC/cadtools/cadence/*/*/tools*/bin/spectre"]
    for pat in pats:
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[-1]
    sys.exit("ERROR: spectre not found. Run this from the terminal where you started Virtuoso.")


class Sim:
    def __init__(self, spectre, cell, subckts, includes, ports, workdir, load, models):
        self.spectre = spectre
        self.cell = cell
        self.subckts = subckts
        self.includes = includes
        self.ports = ports
        self.workdir = workdir
        self.load = load
        self.models = models
        self.count = 0

    def run(self, corner, temp, vdd, sources, stop, maxstep):
        nodes = " ".join(PORT_MAP[p.upper()] for p in self.ports)
        lines = ["simulator lang=spectre", "global 0"]
        lines += model_includes(self.includes, corner, self.models)
        lines += [self.subckts,
                  "I0 (%s) %s" % (nodes, self.cell),
                  "V0 (vdd_n 0) vsource type=dc dc=%.6g" % vdd]
        lines += sources
        lines += ["CL (y 0) capacitor c=%.6g" % self.load,
                  "simOpts options temp=%g reltol=1e-5 iabstol=1e-14 gmin=1e-14 save=selected" % temp,
                  "save y a b c V0:p",
                  "tran1 tran stop=%.6g errpreset=conservative maxstep=%.6g" % (stop, maxstep)]
        scs = os.path.join(self.workdir, "tb_%s.scs" % corner)
        raw = os.path.join(self.workdir, "raw_%s" % corner)
        log = scs + ".log"
        with open(scs, "w") as f:
            f.write("\n".join(lines) + "\n")
        shutil.rmtree(raw, ignore_errors=True)
        cmd = [self.spectre, "+escchars", "-format", "psfascii", "-raw", raw, "=log", log, scs]
        env = dict(os.environ)
        env.setdefault("CDS_LIC_FILE", LICENSE)
        env.setdefault("LM_LICENSE_FILE", LICENSE)
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        self.count += 1
        files = glob.glob(os.path.join(raw, "*.tran"))
        if p.returncode != 0 or not files:
            tail = ""
            if os.path.exists(log):
                with open(log, errors="replace") as f:
                    tail = "".join(f.readlines()[-30:])
            sys.exit("ERROR: spectre failed (see %s):\n%s" % (log, tail))
        return read_psfascii(files[0])


def read_psfascii(path):
    t, cols, in_val = [], {}, False
    with open(path, errors="replace") as f:
        for line in f:
            s = line.strip()
            if not in_val:
                in_val = (s == "VALUE")
                continue
            if s == "END":
                break
            m = re.match(r'"([^"]+)"\s+(\S+)', s)
            if not m:
                continue
            name, val = m.group(1), float(m.group(2))
            if name == "time":
                t.append(val)
            else:
                cols.setdefault(name, []).append(val)
    w = {"t": t}
    for k, v in cols.items():
        w[k.lower()] = v
    w["i"] = [-x for x in w["v0:p"]]          # current delivered by the supply
    return w


# ---------------------------------------------------------------- measurements
def integral(t, v, t0, t1):
    i0 = max(bisect.bisect_right(t, t0), 1)
    area, k = 0.0, i0
    while k < len(t) and t[k - 1] < t1:
        a, b = max(t[k - 1], t0), min(t[k], t1)
        if b > a:
            slope = (v[k] - v[k - 1]) / (t[k] - t[k - 1])
            va = v[k - 1] + slope * (a - t[k - 1])
            vb = v[k - 1] + slope * (b - t[k - 1])
            area += 0.5 * (va + vb) * (b - a)
        k += 1
    return area


def crossings(t, v, level, rising, t0, t1):
    out = []
    i0 = max(bisect.bisect_right(t, t0), 1)
    k = i0
    while k < len(t) and t[k - 1] < t1:
        a, b = v[k - 1], v[k]
        if (rising and a < level <= b) or (not rising and a > level >= b):
            tc = t[k - 1] + (level - a) * (t[k] - t[k - 1]) / (b - a)
            if t0 <= tc <= t1:
                out.append(tc)
        k += 1
    return out


def value_at(t, v, x):
    k = min(max(bisect.bisect_left(t, x), 1), len(t) - 1)
    return v[k - 1] + (v[k] - v[k - 1]) * (x - t[k - 1]) / (t[k] - t[k - 1])


def analyse_transitions(w, seq, func, vdd, period, slew):
    t, y, i = w["t"], w["y"], w["i"]
    rows = []
    for k in range(1, len(seq)):
        src, dst = seq[k - 1], seq[k]
        t0, t1 = k * period, (k + 1) * period
        tref = t0 + slew / 2.0
        y0, y1 = func(*state_bits(src)), func(*state_bits(dst))
        start, end = value_at(t, y, t0), value_at(t, y, t1 - 1e-13)
        ok = abs(start - y0 * vdd) < 0.1 * vdd and abs(end - y1 * vdd) < 0.1 * vdd
        changed = "".join(n for n, a, b in zip("ABC", state_bits(src), state_bits(dst)) if a != b)
        energy = integral(t, i, t0, t1) * vdd
        tail = integral(t, i, t1 - 0.1 * period, t1) * vdd / (0.1 * period)
        delay, glitch, ncross = None, None, 0
        if y0 != y1:
            cr = crossings(t, y, vdd / 2.0, y1 == 1, t0, t1)
            ncross = len(cr)
            if cr:
                delay = cr[-1] - tref
        else:
            lo, hi = bisect.bisect_left(t, t0), bisect.bisect_right(t, t1)
            glitch = max(abs(x - y0 * vdd) for x in y[lo:hi]) / vdd
        rows.append({"from": state_name(src), "to": state_name(dst), "changed": changed,
                     "n_changed": len(changed), "y0": y0, "y1": y1, "delay": delay,
                     "glitch": glitch, "ncross": ncross, "energy": energy,
                     "power": energy / period, "settled": tail <= SETTLED_TAIL_W, "ok": ok})
    return rows


def measure_leakage(sim, corner, temp, vdd):
    res = {}
    for s in range(8):
        a, b, c = state_bits(s)
        src = ["VA (a 0) vsource type=dc dc=%.6g" % (a * vdd),
               "VB (b 0) vsource type=dc dc=%.6g" % (b * vdd),
               "VC (c 0) vsource type=dc dc=%.6g" % (c * vdd)]
        w = sim.run(corner, temp, vdd, src, 3e-9, 10e-12)
        res[state_name(s)] = integral(w["t"], w["i"], 2e-9, 3e-9) / 1e-9 * vdd
    return res


def characterize(sim, seq, func, corner, temp, vdd, period, slew):
    src = [format_pwl("V" + n.upper(), n, pwl_wave(seq, b, period, slew, vdd))
           for b, n in enumerate("abc")]
    stop = len(seq) * period + 0.1e-9
    w = sim.run(corner, temp, vdd, src, stop, 5e-12)
    rows = analyse_transitions(w, seq, func, vdd, period, slew)
    print("  [%s] transient done, %d transitions" % (corner, len(rows)))
    leak = measure_leakage(sim, corner, temp, vdd)
    print("  [%s] leakage done" % corner)
    return rows, leak


# ---------------------------------------------------------------- reporting
def label(r):
    return "%s->%s" % (r["from"], r["to"])


def extreme(rows, key, fn=max):
    rows = [r for r in rows if r[key] is not None]
    return fn(rows, key=lambda r: r[key]) if rows else None


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else None


def num(x, scale=1.0):
    return "n/a" if x is None else "%.4g" % (x * scale)


def summarize(rows, leak):
    """Per-corner summary values as (row label, text) pairs."""
    out = []
    rise = [r for r in rows if r["delay"] is not None and r["y1"] == 1]
    fall = [r for r in rows if r["delay"] is not None and r["y1"] == 0]
    for name, group in (("rise", rise), ("fall", fall)):
        single = [r for r in group if r["n_changed"] == 1]
        worst = extreme(group, "delay")
        worst1 = extreme(single, "delay")
        out.append(("Delay Y %s, worst, single input (ps)" % name,
                    "%s (%s)" % (num(worst1["delay"], 1e12), label(worst1)) if worst1 else "n/a"))
        out.append(("Delay Y %s, average, single input (ps)" % name, num(mean(r["delay"] for r in single), 1e12)))
        out.append(("Delay Y %s, worst, any inputs (ps)" % name,
                    "%s (%s)" % (num(worst["delay"], 1e12), label(worst)) if worst else "n/a"))
    for name, group in (("Y L->H", [r for r in rows if (r["y0"], r["y1"]) == (0, 1)]),
                        ("Y H->L", [r for r in rows if (r["y0"], r["y1"]) == (1, 0)]),
                        ("Y unchanged", [r for r in rows if r["y0"] == r["y1"]])):
        worst = extreme(group, "power")
        out.append(("Dynamic power, %s, worst (uW)" % name,
                    "%s (%s)" % (num(worst["power"], 1e6), label(worst)) if worst else "n/a"))
        out.append(("Dynamic power, %s, average (uW)" % name, num(mean(r["power"] for r in group), 1e6)))
    worst = extreme(rows, "power")
    out.append(("Dynamic power, WORST transition (uW)", "%s (%s)" % (num(worst["power"], 1e6), label(worst))))
    out.append(("Energy, WORST transition (fJ)", "%s (%s)" % (num(worst["energy"], 1e15), label(worst))))
    g = extreme(rows, "glitch")
    out.append(("Largest glitch, Y unchanged (% VDD)", "%s (%s)" % (num(g["glitch"], 100.0), label(g)) if g else "n/a"))
    for s in sorted(leak):
        out.append(("Leakage, ABC=%s (nW)" % s, num(leak[s], 1e9)))
    out.append(("Leakage, average (nW)", num(mean(leak.values()), 1e9)))
    out.append(("Leakage, worst (nW)", num(max(leak.values()), 1e9)))
    return out, worst


def transition_table(rows):
    head = "%-10s %-8s %-6s %10s %12s %10s %10s %7s %s" % (
        "ABC", "changed", "Y", "delay ps", "glitch %VDD", "P uW", "E fJ", "Ycross", "status")
    lines = [head, "-" * len(head)]
    for r in rows:
        status = "ok" if r["ok"] else "WRONG Y"
        if not r["settled"]:
            status += ", NOT SETTLED"
        lines.append("%-10s %-8s %d->%d   %10s %12s %10s %10s %7d %s" % (
            label(r), r["changed"], r["y0"], r["y1"], num(r["delay"], 1e12), num(r["glitch"], 100.0),
            num(r["power"], 1e6), num(r["energy"], 1e15), r["ncross"], status))
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cell", required=True, help="subcircuit (cell) name, case-sensitive")
    ap.add_argument("--func", required=True, choices=sorted(FUNCS), help="expected logic function")
    ap.add_argument("--netlist", help="ADE input.scs containing the cell (default: newest found)")
    ap.add_argument("--models", help="model library, if the netlist has no usable include")
    ap.add_argument("--area", type=float, help="cell boundary area in um^2 (for the bonus line)")
    ap.add_argument("--corners", default="ss,tt,ff", help="comma list, e.g. tt")
    ap.add_argument("--period", type=float, default=2e-9, help="time per input state in s (default 2n)")
    ap.add_argument("--slew", type=float, default=50e-12, help="input ramp in s (default 50p)")
    ap.add_argument("--load", type=float, default=5e-15, help="Y load in F (default 5f)")
    ap.add_argument("--out", help="output directory (default ~/logic_char_runs/<cell>)")
    a = ap.parse_args()

    netlist = a.netlist or find_netlist(a.cell)
    if not netlist:
        sys.exit("ERROR: no ADE netlist with subckt %s found. Run a testbench once in ADE, or use --netlist." % a.cell)
    subckts, includes, ports, parasitics = parse_netlist(netlist, a.cell)
    kind = ("POST-LAYOUT (extracted, %d parasitic R/C)" % parasitics if parasitics
            else "PRE-LAYOUT (schematic; rerun with the extracted netlist for the final report)")
    out = a.out or os.path.expanduser(os.path.join("~/logic_char_runs", a.cell))
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "netlist.scs"), "w") as f:
        f.write(subckts + "\n")
    spectre = find_spectre()
    print("Cell    : %s (%s)\nNetlist : %s\n          %s\nSpectre : %s\nPorts   : %s\n"
          % (a.cell, a.func, netlist, kind, spectre, " ".join(ports)))

    func = FUNCS[a.func]
    seq = all_transitions_sequence()
    sim = Sim(spectre, a.cell, subckts, includes, ports, out, a.load, a.models)
    wanted = a.corners.split(",")
    results = {}
    for corner, temp, vdd in CORNERS:
        if corner in wanted:
            print("Corner %s (%g C, %.2f V)" % (corner, temp, vdd))
            results[corner] = characterize(sim, seq, func, corner, temp, vdd, a.period, a.slew)
    if not results:
        sys.exit("ERROR: no valid corners in --corners %s" % a.corners)
    names = [c for c, _, _ in CORNERS if c in results]
    conds = {c: "%s %gC %.2fV" % (c, t, v) for c, t, v in CORNERS}

    summaries = {c: summarize(*results[c]) for c in names}
    lines = ["%s, function %s" % (a.cell, a.func), kind, "Netlist: " + netlist,
             "Load %.3g F, input slew %.3g s, %.3g s per input state" % (a.load, a.slew, a.period), ""]
    width = 26
    head = "%-42s" % "Measurement" + "".join("%*s" % (width, conds[c]) for c in names)
    lines += [head, "-" * len(head)]
    for idx in range(len(summaries[names[0]][0])):
        lines.append("%-42s" % summaries[names[0]][0][idx][0]
                     + "".join("%*s" % (width, summaries[c][0][idx][1]) for c in names))
    if a.area:
        lines.append("%-42s" % "Cell boundary area (um^2)" + "".join("%*s" % (width, "%.4g" % a.area) for c in names))
    if "tt" in summaries:
        worst = summaries["tt"][1]
        lines += ["", "Bonus (TT): worst dynamic power %.4g uW on %s" % (worst["power"] * 1e6, label(worst))]
        if a.area:
            lines.append("            x area %.4g um^2 = %.5g um^2*uW" % (a.area, worst["power"] * 1e6 * a.area))
        else:
            lines.append("            rerun with --area <um^2> to get the product")

    problems = []
    for c in names:
        rows = results[c][0]
        bad = [label(r) for r in rows if not r["ok"]]
        slow = [label(r) for r in rows if not r["settled"]]
        multi = [label(r) for r in rows if r["ncross"] > 1]
        if bad:
            problems.append("%s: WRONG Y on %s" % (c, " ".join(bad)))
        if slow:
            problems.append("%s: supply current not settled by end of period on %s (use a longer --period)" % (c, " ".join(slow)))
        if multi:
            problems.append("%s: Y crossed VDD/2 more than once (glitch) on %s" % (c, " ".join(multi)))
    lines += ["", "Checks: " + ("all %d transitions match the truth table and settled." % (len(seq) - 1)
                                if not problems else "SEE BELOW")] + ["  " + p for p in problems]
    lines += ["", "Definitions: delay = input 50% to the last Y crossing of VDD/2 in that period;",
              "dynamic power = supply energy over one period / period (depends on --period, so",
              "quote the period, or the energy, when comparing); glitch = peak Y deviation while",
              "Y should hold; leakage = supply power with inputs held, 2-3 ns after start.",
              "Total spectre runs: %d." % sim.count]
    summary = "\n".join(lines)
    print("\n" + summary)

    details = []
    for c in names:
        details += ["", "All transitions, %s" % conds[c]] + transition_table(results[c][0])
    with open(os.path.join(out, "results.txt"), "w") as f:
        f.write(summary + "\n" + "\n".join(details) + "\n")
    with open(os.path.join(out, "transitions.csv"), "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["corner", "from_ABC", "to_ABC", "changed", "Y_from", "Y_to", "delay_ps",
                     "glitch_pct_vdd", "power_uW", "energy_fJ", "Y_crossings", "matches_truth_table", "settled"])
        for c in names:
            for r in results[c][0]:
                wr.writerow([c, r["from"], r["to"], r["changed"], r["y0"], r["y1"], num(r["delay"], 1e12),
                             num(r["glitch"], 100.0), num(r["power"], 1e6), num(r["energy"], 1e15),
                             r["ncross"], r["ok"], r["settled"]])
    with open(os.path.join(out, "leakage.csv"), "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["ABC"] + ["%s_nW" % c for c in names])
        for s in range(8):
            n = state_name(s)
            wr.writerow([n] + [num(results[c][1][n], 1e9) for c in names])
    print("\nSaved in %s: results.txt, transitions.csv, leakage.csv, netlist.scs" % out)
    if any("WRONG" in p for p in problems):
        sys.exit(1)


if __name__ == "__main__":
    main()
