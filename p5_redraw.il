;; p5_redraw.il - redraw MAJ3 and ONEHOT3 so they read as circuits: stacked devices, VDD and
;; GND rails, and drawn wires for every drain and source net. Gates and bulks stay as short
;; labelled wires, because routing them would cross everything. The circuit does not change.
;;
;; Needs ~/p5_cells.il and ~/p5_finish.il. Close the schematic windows, then in the CIW:
;;     load("~/p5_redraw.il")
;;     p5RedrawAll()

load("~/p5_cells.il")
load("~/p5_finish.il")

;; Device placement: (instance column row). Row 0 is the top.
;; Never put terminals above and below the same point inside a bus: Virtuoso merges those two
;; wires into one that crosses the bus without connecting to it.
p5RdMaj = '(
  ("PM3" 0 1) ("PM4" 2 1) ("PM0" 1 2) ("PM2" 3 1) ("PM1" 3 2)
  ("NM0" 1 3) ("NM3" 0 4) ("NM4" 2 4) ("NM1" 3 3) ("NM2" 3 4)
  ("PM5" 5 2) ("NM5" 5 3))

p5RdOne = '(
  ("PM3" 0 1) ("PM4" 2 1) ("PM0" 1 2) ("PM2" 3 1) ("PM1" 3 2)
  ("NM0" 1 3) ("NM3" 0 4) ("NM4" 2 4) ("NM1" 3 3) ("NM2" 3 4)
  ("PM6" 8 0) ("PM7" 8 1) ("PM8" 8 2) ("PM9" 9 2)
  ("NM6" 5 3) ("NM7" 6 3) ("NM8" 7 3) ("NM9" 8 4)
  ("PM5" 11 2) ("NM5" 11 3))

procedure(p5RdWire(cv p q)
  car(schCreateWire(cv "draw" "direct" list(p q) 0.0625 0.0625 0.0))
)

procedure(p5RdLabel(cv wire xy name just)
  schCreateWireLabel(cv wire xy name just "R0" "stick" 0.0625 nil)
)

;; Remove old wires, labels and pins, keeping the devices and their sizes.
procedure(p5RdClean(cv table)
  let((names)
    names = mapcar('car table)
    foreach(n names
      unless(dbFindAnyInstByName(cv n)
        error("p5: instance %s is missing.\n" n)))
    ;; deleting a wire also deletes its label, so remove wires first, then what is left
    foreach(s setof(x cv~>shapes x~>objType != "label") dbDeleteObject(s))
    foreach(s cv~>shapes dbDeleteObject(s))
    foreach(i cv~>instances
      unless(member(i~>name names) dbDeleteObject(i)))
    foreach(tm cv~>terminals errset(dbDeleteObject(tm)))
  )
)

;; Short labelled wires on one device's gate and bulk.
procedure(p5RdStubs(cv inst row span)
  let((g b gTip bTip w)
    g = p5TermXY(inst "g")
    gTip = list(xCoord(g) - p5Snap(span) yCoord(g))
    w = p5RdWire(cv g gTip)
    p5RdLabel(cv w gTip p5NetFor(row "g") "lowerRight")
    b = p5TermXY(inst "b")
    bTip = list(xCoord(b) + p5Snap(span) yCoord(b))
    w = p5RdWire(cv b bTip)
    p5RdLabel(cv w bTip p5NetFor(row "b") "lowerLeft")
  )
)

;; One drain or source net: a vertical from each terminal to a horizontal bus.
procedure(p5RdNet(cv name pts railTop railBot)
  let((ys xs ymin ymax busY xmin xmax w)
    xs = mapcar('car pts)
    ys = mapcar('cadr pts)
    xmin = apply('min xs)
    xmax = apply('max xs)
    ymin = apply('min ys)
    ymax = apply('max ys)
    if(xmax - xmin <= 0.001 && name != "VDD" && name != "GND" then
      ;; Terminals in one column get a single wire. Two wires meeting end to end would be
      ;; merged by Virtuoso, which invalidates the first one.
      w = p5RdWire(cv list(xmin ymin) list(xmin ymax))
      p5RdLabel(cv w list(xmin (ymin + ymax) / 2.0) name "centerLeft")
    else
      busY = cond(
        (name == "VDD" railTop)
        (name == "GND" railBot)
        (t p5Snap((ymax + ymin) / 2.0)))
      foreach(p pts
        unless(cadr(p) == busY
          p5RdWire(cv p list(car(p) busY))))
      w = p5RdWire(cv list(xmin busY) list(xmax busY))
      p5RdLabel(cv w list((xmin + xmax) / 2.0 busY) name "lowerCenter")
    )
  )
)

;; Pins, joined to their nets by name.
procedure(p5RdPins(cv span)
  let((ipin opin iopin x y)
    ipin = dbOpenCellViewByType("basic" "ipin" "symbol" nil "r")
    opin = dbOpenCellViewByType("basic" "opin" "symbol" nil "r")
    iopin = dbOpenCellViewByType("basic" "iopin" "symbol" nil "r")
    x = p5Snap(-5.0 * span)
    y = p5Snap(12.0 * span)
    foreach(p list(list("VDD" iopin "inputOutput") list("A" ipin "input") list("B" ipin "input")
                   list("C" ipin "input") list("Y" opin "output") list("GND" iopin "inputOutput"))
      schCreatePin(cv cadr(p) car(p) caddr(p) nil list(x y) "R0")
      y = y - p5Snap(1.5 * span)
    )
  )
)

procedure(p5Redraw(cell table place)
  let((cv span names pts top bot terms)
    cv = dbOpenCellViewByType(p5Lib cell "schematic" "schematic" "a")
    unless(cv error("p5: could not open %s schematic. Close its window and clear any lock.\n" cell))
    p5RdClean(cv table)
    span = p5Span(dbFindAnyInstByName(cv "NM0"))

    foreach(pl place
      dbFindAnyInstByName(cv car(pl))~>xy =
        list(p5Snap(cadr(pl) * 6.0 * span) p5Snap((4 - caddr(pl)) * 4.0 * span)))

    ;; rails sit clear of the outermost drain and source terminals
    terms = nil
    foreach(row table
      foreach(role '("d" "s")
        terms = cons(p5TermXY(dbFindAnyInstByName(cv car(row)) role) terms)))
    top = p5Snap(apply('max mapcar('cadr terms)) + 1.5 * span)
    bot = p5Snap(apply('min mapcar('cadr terms)) - 1.5 * span)

    foreach(row table
      p5RdStubs(cv dbFindAnyInstByName(cv car(row)) row span))

    ;; group drain and source terminals by net
    names = nil
    pts = makeTable("p5nets" nil)
    foreach(row table
      foreach(role '("d" "s")
        let((n)
          n = p5NetFor(row role)
          unless(member(n names) names = cons(n names))
          pts[n] = cons(p5TermXY(dbFindAnyInstByName(cv car(row)) role) pts[n]))))
    foreach(n names
      p5RdNet(cv n pts[n] top bot))

    p5RdPins(cv span)
    p5Finish(cv cell table)
  )
)

procedure(p5RedrawAll()
  let((bad)
    bad = p5Redraw("MAJ3" p5MajTable p5RdMaj) + p5Redraw("ONEHOT3" p5OneTable p5RdOne)
    if(bad == 0 then
      printf("p5: REDRAW PASS, all connections match the tables.\n")
      p5RunOnce()
      printf("p5: redraw done. Rerun logic_char.py on both cells.\n")
    else
      printf("p5: REDRAW FAIL, see the mismatches above. Not rerunning Spectre.\n"))
    bad
  )
)
