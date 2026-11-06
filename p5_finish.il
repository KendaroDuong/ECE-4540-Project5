;; p5_finish.il - after p5_cells.il: make both symbols, build LOGIC_tb, and run it once in
;; Spectre so that logic_char.py has a netlist to read.
;;
;; Close the MAJ3 and ONEHOT3 windows first, then in the CIW:
;;     load("~/p5_finish.il")
;;     p5FinishAll()
;;
;; Existing symbols are kept, not overwritten. An existing LOGIC_tb schematic is overwritten.

p5Lib = "kendaro_p5"
p5Models = "/data/PDK/sky130a/sky130_release_0.1.0/models/sky130.lib.spice"

;; 1. Confirm each schematic holds only the expected devices and pins.
procedure(p5CheckCell(cell want)
  let((cv names)
    cv = dbOpenCellViewByType(p5Lib cell "schematic" nil "r")
    unless(cv error("p5: cannot open %s schematic.\n" cell))
    names = sort(cv~>instances~>name nil)
    printf("%s: %d instances (want %d): %L\n" cell length(names) want names)
    dbClose(cv)
    length(names) == want
  )
)

;; 2. Symbols, using Virtuoso's own generator.
procedure(p5Symbol(cell)
  if(ddGetObj(p5Lib cell "symbol") then
    printf("%s: symbol already exists, kept.\n" cell)
    t
  else
    let((ok cv)
      ok = errset(schViewToView(p5Lib cell p5Lib cell "schematic" "symbol"
                                "schSchemToPinList" "schPinListToSymbolGen") t)
      cv = ddGetObj(p5Lib cell "symbol") && dbOpenCellViewByType(p5Lib cell "symbol" nil "r")
      if(cv then
        printf("%s: symbol made, pins %L\n" cell sort(cv~>terminals~>name nil))
        dbClose(cv)
        t
      else
        printf("%s: SYMBOL NOT MADE (%L). Use Create -> Cellview -> From Cellview.\n" cell ok)
        nil
      )
    )
  )
)

;; Terminal centre in cell coordinates.
procedure(p5TbXY(inst tname)
  let((found pin fig box ll ur)
    foreach(term inst~>master~>terminals
      when(term~>name == tname found = term))
    unless(found
      error("p5: %s has no terminal %s. It has %L\n" inst~>name tname inst~>master~>terminals~>name))
    pin = car(found~>pins)
    fig = or(car(pin~>figs) pin~>fig)
    box = dbTransformBBox(fig~>bBox inst~>transform)
    ll = lowerLeft(box)
    ur = upperRight(box)
    list((xCoord(ll) + xCoord(ur)) / 2.0 (yCoord(ll) + yCoord(ur)) / 2.0)
  )
)

;; A short labelled wire on each listed terminal: conns = list(list(terminal net) ...)
procedure(p5TbWire(cv inst conns)
  let((pts cx cy n stub)
    stub = 0.25
    pts = mapcar(lambda((c) list(cadr(c) p5TbXY(inst car(c)))) conns)
    n = float(length(pts))
    cx = 0.0
    cy = 0.0
    foreach(p pts
      cx = cx + xCoord(cadr(p)) / n
      cy = cy + yCoord(cadr(p)) / n)
    foreach(p pts
      let((net xy dx dy tip mid wire)
        net = car(p)
        xy = cadr(p)
        dx = xCoord(xy) - cx
        dy = yCoord(xy) - cy
        cond(
          (abs(dx) > abs(dy)
           tip = list(xCoord(xy) + if(dx > 0 then stub else -stub) yCoord(xy)))
          (dy > 0
           tip = list(xCoord(xy) yCoord(xy) + stub))
          (t
           tip = list(xCoord(xy) yCoord(xy) - stub))
        )
        mid = list((xCoord(xy) + xCoord(tip)) / 2.0 (yCoord(xy) + yCoord(tip)) / 2.0)
        wire = schCreateWire(cv "draw" "direct" list(xy tip) 0.0625 0.0625 0.0)
        schCreateWireLabel(cv car(wire) mid net "lowerCenter" "R0" "stick" 0.0625 nil)
      )
    )
  )
)

;; 3. Testbench holding both cells, each with its own 5 fF load.
procedure(p5Testbench()
  let((cv chk src)
    cv = dbOpenCellViewByType(p5Lib "LOGIC_tb" "schematic" "schematic" "w")
    unless(cv error("p5: cannot create LOGIC_tb. Close its window and clear any lock.\n"))

    ;; sources: (name xy net params)
    foreach(s list(
        list("VDD0" list(0.0 2.0) "VDD" list(list("vdc" "string" "1.8")) "vdc")
        list("VA" list(2.0 2.0) "A" list(list("v1" "string" "0") list("v2" "string" "1.8") list("per" "string" "8n")
                                         list("pw" "string" "3.95n") list("tr" "string" "50p") list("tf" "string" "50p")) "vpulse")
        list("VB" list(4.0 2.0) "B" list(list("v1" "string" "0") list("v2" "string" "1.8") list("per" "string" "4n")
                                         list("pw" "string" "1.95n") list("tr" "string" "50p") list("tf" "string" "50p")) "vpulse")
        list("VC" list(6.0 2.0) "C" list(list("v1" "string" "0") list("v2" "string" "1.8") list("per" "string" "2n")
                                         list("pw" "string" "0.95n") list("tr" "string" "50p") list("tf" "string" "50p")) "vpulse"))
      src = dbCreateParamInstByMasterName(cv "analogLib" nth(4 s) "symbol" car(s) cadr(s) "R0" 1 nth(3 s))
      unless(src error("p5: could not place %s.\n" car(s)))
      p5TbWire(cv src list(list("PLUS" caddr(s)) list("MINUS" "gnd!")))
    )

    ;; cells and their loads
    foreach(c list(list("XMAJ" "MAJ3" list(0.0 0.0) "Y_MAJ" "CMAJ" list(2.0 0.0))
                   list("XONE" "ONEHOT3" list(4.0 0.0) "Y_ONE" "CONE" list(6.0 0.0)))
      let((inst load)
        inst = dbCreateInstByMasterName(cv p5Lib cadr(c) "symbol" car(c) caddr(c) "R0")
        unless(inst error("p5: could not place %s. Does its symbol exist?\n" cadr(c)))
        p5TbWire(cv inst list(list("A" "A") list("B" "B") list("C" "C") list("Y" nth(3 c))
                              list("VDD" "VDD") list("GND" "gnd!")))
        load = dbCreateParamInstByMasterName(cv "analogLib" "cap" "symbol" nth(4 c) nth(5 c) "R0" 1
                                             list(list("c" "string" "5f")))
        p5TbWire(cv load list(list("PLUS" nth(3 c)) list("MINUS" "gnd!")))
      )
    )

    ;; ground symbol
    src = dbCreateInstByMasterName(cv "analogLib" "gnd" "symbol" "GND0" list(8.0 2.0) "R0")
    p5TbWire(cv src list(list("gnd!" "gnd!")))

    chk = schCheck(cv)
    dbSave(cv)
    printf("LOGIC_tb: schCheck (errors warnings) = %L\n" chk)
    dbClose(cv)
    chk
  )
)

;; 4. One TT run, which writes the netlist under ~/simulation.
procedure(p5RunOnce()
  let((ok)
    ok = errset(
      progn(
        simulator('spectre)
        design(p5Lib "LOGIC_tb" "schematic")
        modelFile(list(p5Models "tt"))
        analysis('tran ?stop "16n")
        temp(25)
        createNetlist(?recreateAll t)
        run()
      ) t)
    if(ok then
      printf("Spectre run finished. Netlist should be at ~/simulation/LOGIC_tb/spectre/schematic/netlist/input.scs\n")
    else
      printf("p5: AUTOMATIC RUN FAILED. Open LOGIC_tb in ADE and run it once by hand.\n"))
    ok
  )
)

procedure(p5FinishAll()
  let((good)
    good = p5CheckCell("MAJ3" 18) && p5CheckCell("ONEHOT3" 26)
    unless(good error("p5: unexpected instance count, see above. Stopping.\n"))
    unless(p5Symbol("MAJ3") && p5Symbol("ONEHOT3")
      error("p5: make the symbols by menu, then run p5FinishAll() again.\n"))
    p5Testbench()
    p5RunOnce()
    printf("p5: done. Next, run logic_char.py on both cells.\n")
    t
  )
)
