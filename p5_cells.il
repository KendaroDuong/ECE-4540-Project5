;; p5_cells.il - wire MAJ3 and build ONEHOT3 in kendaro_p5, then check every connection.
;;
;; Needs MAJ3/schematic saved with the 12 placed devices NM0-NM5 and PM0-PM5. Their sizes
;; are kept. New ONEHOT3 devices are copies of NM0, PM0 and PM5, so they keep the same
;; PDK settings. Save and close the MAJ3 window first, then in the CIW:
;;     load("~/p5_cells.il")
;;     p5BuildAll()
;;
;; Warning: existing wires, labels and pins in MAJ3 are removed and redrawn, and any
;; existing ONEHOT3 schematic is overwritten.

p5Lib = "kendaro_p5"

;; (instance type gate drain source)
p5MajTable = '(
  ("NM0" "n" "C"  "MN" "N1")  ("NM1" "n" "B"  "MN" "N2")  ("NM2" "n" "A"  "N2" "GND")
  ("NM3" "n" "A"  "N1" "GND") ("NM4" "n" "B"  "N1" "GND") ("NM5" "n" "MN" "Y"  "GND")
  ("PM0" "p" "C"  "MN" "P1")  ("PM1" "p" "B"  "MN" "P2")  ("PM2" "p" "A"  "P2" "VDD")
  ("PM3" "p" "A"  "P1" "VDD") ("PM4" "p" "B"  "P1" "VDD") ("PM5" "p" "MN" "Y"  "VDD"))

p5OneTable = '(
  ("NM0" "n" "C"  "MN" "N1")  ("NM1" "n" "B"  "MN" "N2")  ("NM2" "n" "A"  "N2" "GND")
  ("NM3" "n" "A"  "N1" "GND") ("NM4" "n" "B"  "N1" "GND")
  ("NM6" "n" "A"  "YB" "N3")  ("NM7" "n" "B"  "YB" "N3")  ("NM8" "n" "C"  "YB" "N3")
  ("NM9" "n" "MN" "N3" "GND") ("NM5" "n" "YB" "Y"  "GND")
  ("PM0" "p" "C"  "MN" "P1")  ("PM1" "p" "B"  "MN" "P2")  ("PM2" "p" "A"  "P2" "VDD")
  ("PM3" "p" "A"  "P1" "VDD") ("PM4" "p" "B"  "P1" "VDD")
  ("PM6" "p" "A"  "P3" "VDD") ("PM7" "p" "B"  "P4" "P3")  ("PM8" "p" "C"  "YB" "P4")
  ("PM9" "p" "MN" "YB" "VDD") ("PM5" "p" "YB" "Y"  "VDD"))

procedure(p5Snap(v)
  round(v / 0.0625) * 0.0625
)

;; Master terminal for role "d", "g", "s" or "b".
procedure(p5Term(inst role)
  let((found)
    foreach(term inst~>master~>terminals
      when(lowerCase(substring(term~>name 1 1)) == role
        found = term))
    unless(found
      error("p5: %s has no %s terminal. Terminals: %L\n" inst~>name role inst~>master~>terminals~>name))
    found
  )
)

;; Terminal centre in cell coordinates.
procedure(p5TermXY(inst role)
  let((pin fig box ll ur)
    pin = car(p5Term(inst role)~>pins)
    fig = or(car(pin~>figs) pin~>fig)
    box = dbTransformBBox(fig~>bBox inst~>transform)
    ll = lowerLeft(box)
    ur = upperRight(box)
    list((xCoord(ll) + xCoord(ur)) / 2.0 (yCoord(ll) + yCoord(ur)) / 2.0)
  )
)

;; Net name wanted on each terminal of one table row.
procedure(p5NetFor(row role)
  cond(
    (role == "g" nth(2 row))
    (role == "d" nth(3 row))
    (role == "s" nth(4 row))
    (role == "b" if(nth(1 row) == "n" then "GND" else "VDD"))
  )
)

;; Terminal spacing of the device symbol, used to scale the drawing.
procedure(p5Span(inst)
  let((d s)
    d = p5TermXY(inst "d")
    s = p5TermXY(inst "s")
    abs(yCoord(d) - yCoord(s))
  )
)

;; Line devices up in two rows.
procedure(p5Place(cv table span)
  let((nx px inst x y)
    nx = 0
    px = 0
    foreach(row table
      inst = dbFindAnyInstByName(cv car(row))
      if(nth(1 row) == "n" then
        x = nx * 5.0 * span
        y = 0.0
        nx = nx + 1
      else
        x = px * 5.0 * span
        y = 4.0 * span
        px = px + 1
      )
      inst~>xy = list(p5Snap(x) p5Snap(y))
    )
  )
)

;; A short labelled wire on all four terminals of one device.
procedure(p5WireInst(cv inst row span)
  let((pts cx cy stub)
    stub = max(p5Snap(span * 0.5) 0.125)
    pts = mapcar(lambda((r) list(r p5TermXY(inst r))) '("d" "g" "s" "b"))
    cx = 0.0
    cy = 0.0
    foreach(p pts
      cx = cx + xCoord(cadr(p)) / 4.0
      cy = cy + yCoord(cadr(p)) / 4.0)
    foreach(p pts
      let((role xy dx dy tip mid wire)
        role = car(p)
        xy = cadr(p)
        dx = xCoord(xy) - cx
        dy = yCoord(xy) - cy
        if(abs(dx) > abs(dy) then
          tip = list(xCoord(xy) + if(dx > 0 then stub else -stub) yCoord(xy))
        else
          tip = list(xCoord(xy) yCoord(xy) + if(dy > 0 then stub else -stub))
        )
        mid = list((xCoord(xy) + xCoord(tip)) / 2.0 (yCoord(xy) + yCoord(tip)) / 2.0)
        wire = schCreateWire(cv "draw" "direct" list(xy tip) 0.0625 0.0625 0.0)
        schCreateWireLabel(cv car(wire) mid p5NetFor(row role) "lowerCenter" "R0" "stick" 0.0625 nil)
      )
    )
  )
)

;; Input, output and supply pins in a column left of the devices.
procedure(p5Pins(cv span)
  let((ipin opin iopin y x)
    ipin = dbOpenCellViewByType("basic" "ipin" "symbol" nil "r")
    opin = dbOpenCellViewByType("basic" "opin" "symbol" nil "r")
    iopin = dbOpenCellViewByType("basic" "iopin" "symbol" nil "r")
    x = p5Snap(-4.0 * span)
    y = p5Snap(4.0 * span)
    foreach(p list(list("VDD" iopin "inputOutput") list("A" ipin "input") list("B" ipin "input")
                   list("C" ipin "input") list("Y" opin "output") list("GND" iopin "inputOutput"))
      schCreatePin(cv cadr(p) car(p) caddr(p) nil list(x y) "R0")
      y = y - p5Snap(span)
    )
  )
)

;; Compare each device terminal's extracted net with the table. Returns the mismatch count.
procedure(p5Verify(cv table)
  let((bad)
    bad = 0
    foreach(row table
      let((inst)
        inst = dbFindAnyInstByName(cv car(row))
        foreach(role '("d" "g" "s" "b")
          let((tname want got)
            tname = p5Term(inst role)~>name
            want = p5NetFor(row role)
            got = nil
            foreach(it inst~>instTerms
              when(it~>name == tname
                got = it~>net~>name))
            unless(got == want
              printf("  MISMATCH %s.%s: want %s, got %L\n" car(row) tname want got)
              bad = bad + 1)
          )
        )
      )
    )
    bad
  )
)

procedure(p5Finish(cv name table)
  let((chk bad)
    chk = schCheck(cv)
    dbSave(cv)
    bad = p5Verify(cv table)
    printf("%s: %d devices, schCheck (errors warnings) = %L, connection mismatches = %d\n"
           name length(table) chk bad)
    dbClose(cv)
    bad
  )
)

procedure(p5BuildMaj()
  let((cv span names)
    cv = dbOpenCellViewByType(p5Lib "MAJ3" "schematic" "schematic" "a")
    unless(cv error("p5: could not open %s/MAJ3/schematic for editing. Close its window and clear any lock.\n" p5Lib))
    names = mapcar('car p5MajTable)
    foreach(n names
      unless(dbFindAnyInstByName(cv n)
        error("p5: MAJ3 has no instance %s. Rename the devices to NM0-NM5 and PM0-PM5.\n" n)))
    foreach(s cv~>shapes dbDeleteObject(s))
    foreach(i cv~>instances
      unless(member(i~>name names) dbDeleteObject(i)))
    foreach(tm cv~>terminals errset(dbDeleteObject(tm)))
    span = p5Span(dbFindAnyInstByName(cv "NM0"))
    p5Place(cv p5MajTable span)
    foreach(row p5MajTable
      p5WireInst(cv dbFindAnyInstByName(cv car(row)) row span))
    p5Pins(cv span)
    p5Finish(cv "MAJ3" p5MajTable)
  )
)

procedure(p5BuildOne()
  let((src cv span)
    src = dbOpenCellViewByType(p5Lib "MAJ3" "schematic" "schematic" "r")
    unless(src error("p5: could not read %s/MAJ3/schematic.\n" p5Lib))
    cv = dbOpenCellViewByType(p5Lib "ONEHOT3" "schematic" "schematic" "w")
    unless(cv error("p5: could not create %s/ONEHOT3/schematic. Close its window and clear any lock.\n" p5Lib))
    foreach(row p5OneTable
      let((tmplName tmpl copy)
        tmplName = cond(
          (car(row) == "PM5" "PM5")
          (nth(1 row) == "n" "NM0")
          (t "PM0"))
        tmpl = dbFindAnyInstByName(src tmplName)
        copy = dbCopyFig(tmpl cv list(0:0 "R0" 1))
        copy~>name = car(row)
      )
    )
    dbClose(src)
    span = p5Span(dbFindAnyInstByName(cv "NM0"))
    p5Place(cv p5OneTable span)
    foreach(row p5OneTable
      p5WireInst(cv dbFindAnyInstByName(cv car(row)) row span))
    p5Pins(cv span)
    p5Finish(cv "ONEHOT3" p5OneTable)
  )
)

procedure(p5BuildAll()
  let((a b)
    a = p5BuildMaj()
    b = p5BuildOne()
    if(a + b == 0 then
      printf("p5: PASS, all connections match the tables.\n")
    else
      printf("p5: FAIL, see the mismatches above.\n"))
    a + b
  )
)
