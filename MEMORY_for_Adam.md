# Project 5 memory for Adam: layout handoff

Written Nov 5, 2026 (evening) from Kendaro's Claude Code session. The project is **due Friday, Nov 6**.
These are working notes, not report text. Write the report prose yourself (honor code).

## 1. What is left for you

Kendaro has confirmed you are doing layout and may help. You own these, for **both cells**:

1. Layout
2. DRC and LVS
3. Extraction, plus the extracted netlist
4. Abstract view and LEF
5. Report Section 2 and Section 5

Kendaro owns the schematics, symbols, testbench, post-extraction Spectre runs and Sections 1, 3 and 4. Kendaro needs your extracted views before the final numbers can exist, so **get MAJ3 through extraction first**. ONEHOT3 reuses the same 10-transistor stage.

## 2. Design

The spec asks for Majority and One Hot gates that fit the `sky130_scl_9T` library, with schematic, layout, abstract and symbol views.

| Cell | Function | Structure | Transistors |
|---|---|---|---|
| `MAJ3` | Y = AB + C(A+B) | Mirror stage giving MN, then inverter | 12 |
| `ONEHOT3` | Y = (A+B+C)·MN (exactly one input high) | Same mirror stage, then OAI31 giving YB, then inverter | 20 |

- Internal node MN = NOT(AB + C(A+B)). YB = NOT((A+B+C)·MN).
- **Spec check for ONEHOT3:** Y = 1 for 001, 010, 100; Y = 0 for every other input.
- **Pins, case-sensitive:** `A B C Y VDD GND`. It is `GND`, not `VSS`.
- **Library:** `kendaro_p5`, with tech library `sky130_fd_pr_main`, devices `nfet_01v8` and `pfet_01v8`.
- **Sizes:** L = 0.15 µm everywhere. W = 0.42 µm everywhere **except PM5, the output inverter pMOS, at W = 0.84 µm**. All single finger.
- **Bulks:** pMOS to VDD, nMOS to GND.

### MAJ3 devices (gate, drain, source)

| Device | G | D | S | Device | G | D | S |
|---|---|---|---|---|---|---|---|
| NM0 | C | MN | N1 | PM0 | C | MN | P1 |
| NM1 | B | MN | N2 | PM1 | B | MN | P2 |
| NM2 | A | N2 | GND | PM2 | A | P2 | VDD |
| NM3 | A | N1 | GND | PM3 | A | P1 | VDD |
| NM4 | B | N1 | GND | PM4 | B | P1 | VDD |
| NM5 | MN | Y | GND | PM5 (0.84) | MN | Y | VDD |

### ONEHOT3 devices

NM0–NM4 and PM0–PM4 are identical to MAJ3. The rest:

| Device | G | D | S | Device | G | D | S |
|---|---|---|---|---|---|---|---|
| NM6 | A | YB | N3 | PM6 | A | P3 | VDD |
| NM7 | B | YB | N3 | PM7 | B | P4 | P3 |
| NM8 | C | YB | N3 | PM8 | C | YB | P4 |
| NM9 | MN | N3 | GND | PM9 | MN | YB | VDD |
| NM5 | YB | Y | GND | PM5 (0.84) | YB | Y | VDD |

Tables 1.3 and 1.4 in the draft hold the same data.

## 3. Suggested layout order

This is a starting point and **has not been drawn**. On Nov 5 Claude checked it by hand, device by device, against the tables above. It is not DRC-checked. If you change the order, delete or update Table 2.1 in the draft.

Each poly column serves the pMOS above and the nMOS below it. Diffusion names sit between the columns.

**MAJ3, 6 poly columns, no diffusion breaks**

```
poly:          C    B    A    A    B    MN
pMOS diff:  P1   MN   P2  VDD   P1  VDD   Y
nMOS diff:  N1   MN   N2  GND   N1  GND   Y
```

**ONEHOT3, 10 poly columns, one nMOS break (|) after column 5**

```
poly:          C    B    A    A    B    A    B    C    MN   YB
pMOS diff:  P1   MN   P2  VDD   P1  VDD   P3   P4   YB  VDD   Y
nMOS diff:  N1   MN   N2  GND   N1  GND | YB   N3   YB   N3  GND   Y
```

Metal you must add, because a net appears in more than one place:

| Tie together | MAJ3 | ONEHOT3 |
|---|---|---|
| Input gates | A (cols 3, 4); B (cols 2, 5) | A (cols 3, 4, 6); B (cols 2, 5, 7); C (cols 1, 8) |
| N1 and P1 | Each appears twice in its row | Same |
| MN | pMOS and nMOS diffusion, to the gate of col 6 | pMOS and nMOS diffusion, to the gate of col 9 |
| YB | n/a | Both nMOS YB regions, the pMOS YB region, and the gate of col 10 |
| N3 | n/a | Both N3 regions |
| Y | pMOS and nMOS output diffusion | Same |

PM5 is twice as wide as the others, so the last pMOS diffusion needs a width change. Check that against DRC.

**Bonus:** lowest area and dynamic power at the worst TT transition wins 5%, and it must be on the cover table. Cell width is set by the poly columns, so keep to the smallest whole number of sites that passes DRC. Avoid extra diffusion breaks.

## 4. Get access

You cannot write into Kendaro's library, so do layout in your own copy.

**Kendaro runs this first** (the library path is assumed; check it with `ls -ld`):

```bash
chmod go+x /data/projects/vlsi_fall2026/kendaro
```
```bash
chmod -R go+rX /data/projects/vlsi_fall2026/kendaro/kendaro_p5
```

**You then:**

1. Connect (eduroam or VT VPN):
   ```bash
   ssh -Y -o ServerAliveInterval=60 adamzmawloud@lnx-prd-03.ece.vt.edu
   ```
2. Start Cadence from your project folder:
   ```bash
   source /var/RFIC/cadtools/cadence/setups/setup-cadence-vlsi_f26
   ```
3. Allow edits to `cds.lib`, then add Kendaro's library to it:
   ```bash
   chmod u+w cds.lib
   ```
   ```
   DEFINE kendaro_p5 /data/projects/vlsi_fall2026/kendaro/kendaro_p5
   ```
4. In Library Manager, File → Refresh. Create your own library attached to `sky130_fd_pr_main`, then copy `MAJ3` and `ONEHOT3` into it. **Keep the cell names**, because `logic_char.py` looks for them.
5. When you finish, make your library readable the same way and tell Kendaro its path and the extracted view name.

## 5. Layout steps

This is adapted from the Project 4 guide. **The Pegasus, Quantus and Abstract Generator menu names were written without seeing the class setup, so they may differ.** You used these tools on Project 4, so trust that over this list. Add any corrections here for the next reader.

1. **Get the cell dimensions.** Nobody has checked these yet, so use what this prints and don't assume a height:
   ```bash
   grep -A4 -E "^SITE" /data/PDK/sky130a/stdcells/sky130_scl_9T/lef/sky130_scl_9T.lef
   ```
2. **Study a library cell.** Open a small cell in `sky130_scl_9T`, or read its LEF macro if the layout isn't available. Measure with `K`: height, rail width and layer, n-well extent, taps. Match those.
3. **Pin grid.** The class notes give 0.23 + k·0.46 µm (0.23, 0.69, 1.15...). Check this against the LEF's site and tracks.
4. **Start the layout.** Open the schematic, then Launch → Layout XL → Create New. Set snap to 0.005 µm. Use Connectivity → Generate → All From Source for instances and pins.
5. **Frame.** Lower-left corner at (0, 0). Draw `prBoundary`, then the VDD rail on top, the GND rail on the bottom, and n-well over the pMOS row, matching the reference cell. Width must be a whole number of sites.
6. **Place** in the order from section 3, pMOS on top, sharing diffusion where the same net abuts. If pcells won't merge, leave the minimum gap and join with li1; that is wider but still correct.
7. **Taps** under the rails, as the reference cell does them. LVS needs the bulks tied.
8. **Route** with poly, li1 and met1 until no flight lines remain. Put pins on the grid.
9. 📸 **SUBMISSION SCREENSHOTS:** DRC clean, Figures 2.5 and 2.6 (Pegasus).
10. 📸 **SUBMISSION SCREENSHOTS:** LVS match against the schematic, Figures 2.7 and 2.8.
11. **Shrink** to the fewest sites that still pass DRC and LVS. Rerun both, since final screenshots must show the final design.
12. 📸 **SUBMISSION SCREENSHOTS:** Layout, Figures 2.1 and 2.2. Layout with ruler measurements, Figures 2.3 and 2.4.
13. 📸 **SUBMISSION SCREENSHOTS:** Extraction with Quantus to a view such as `av_extracted`, Figures 2.9 and 2.10. Export the extracted netlist for Section 5.
14. 📸 **SUBMISSION SCREENSHOTS:** Abstract Generator: Core bin, VDD as power, GND as ground, the 9T SITE name, then Extract, Abstract, Verify. Figures 2.11 and 2.12.
15. **Export LEF** and compare it to a macro in `sky130_scl_9T.lef`: `CLASS CORE`, `SIZE`, `SYMMETRY`, `SITE`, `PIN`, `OBS`.

### Common failures

| Symptom | Likely cause |
|---|---|
| LVS bulk or well mismatch | Missing taps |
| LVS pin not found | Pin name or label layer wrong (`GND`, capitals) |
| LVS device size mismatch | A W or finger count changed; check PM5 at 0.84 |
| LVS net shorted | Shapes touching where nets cross, or repeated-name regions left untied |
| Cell locked | Someone has it open, or a stale lock: `find <lib> -iname "*.cdslck"`, and remove it only if no live session holds it |

### Server gotchas

- The connection drops often. Save often. Use `nohup ... &` for long terminal jobs.
- The CIW takes SKILL only. Shell commands go in the Linux terminal.
- After the Cadence setup, plain `python3` fails with "Invalid operating system environment". Use `/usr/bin/python3`.
- If Library Manager looks stale, use File → Refresh. If you can't create a library, run `chmod u+w cds.lib`.
- Ignore the "unsupported OS" warnings.

## 6. What to hand back

Commit and push to this repo:

- Screenshots in `screenshots/`, named by figure
- LEF files, extracted netlists and `dimensions.txt` in `from_adam/`, as listed in `from_adam/README.md`

Kendaro then runs the post-extraction characterization through a config view pointing at your extracted view:

```bash
nohup /usr/bin/python3 ~/logic_char.py --cell MAJ3 --func maj --area <um2> > ~/maj.txt 2>&1 &
```
```bash
nohup /usr/bin/python3 ~/logic_char.py --cell ONEHOT3 --func onehot --area <um2> > ~/one.txt 2>&1 &
```

**The draft is a binary file that git can't merge.** Agree who is editing it before you open it, pull first, and push straight after. If you and Kendaro both change it, one person's edits are lost.

## 7. Pre-layout results (for reference)

TT, 25 °C, 1.80 V, 5 fF load, 50 ps input edges. All 56 input transitions passed at ss (1.62 V, 125 °C), tt, and ff (1.98 V, 0 °C). **These are pre-layout and will change after extraction.**

| | MAJ3 | ONEHOT3 |
|---|---|---|
| Y rise delay, worst / avg | 102 / 98.83 ps | 242.7 / 187.3 ps |
| Y fall delay, worst / avg | 204.6 / 190.5 ps | 258.5 / 200 ps |
| Dynamic power, worst | 11.25 µW (100→101) | 20.13 µW (111→001) |
| Dynamic power, Y high-to-low, worst | 8.078 µW | 7.522 µW |
| Static power, avg / worst | 0.5354 / 1.038 nW | 0.6805 / 1.083 nW |
| Largest glitch | 0.49% | 14.36% on 000→101 (26.71% at ff) |

The ONEHOT3 glitch and the internal node `XONE.P4` peaking at 2.314 V are seen in simulation. The cause has not been confirmed. Compare them after extraction.

## 8. Open items

**Kendaro, not done when this was written:**

- Confirm the schematic redraw didn't change results. The Spectre log matched (598 steps, 255.8 µA, 2.314 V), but the `diff` of `logic_char.py` results hasn't been reported.
- Run the `SITE` grep from section 5 (you can do this too)

**Either of you:**

- Ask Rohit what "a few entries" for synthesis and place-and-route means. We assume LEF; a Liberty entry may also be expected.
- The bonus wording doesn't say how area and power combine or how two cells are scored. The cover table lists area, worst power, and their product.

**Before submitting:**

- Fill Tables 2.2 and 4.7 and the cover table with post-extraction values
- Write all prose in your own words and remove the yellow notes
- Delete page 1 of the draft (the handoff page)
- Finish Section 6, the AI disclosure, with session logs. **If you use Claude for layout, your session counts too, so keep a log.** This file came from Claude, so it counts as well.
- Export to PDF and submit on Canvas
