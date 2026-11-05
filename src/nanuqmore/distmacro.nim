## `continuous` and `discrete`: one block per distribution, holding only the
## math that is particular to it. The macros write everything else: the
## methods derived from the ones given (`sf` from `cdf`, `ppf` by inverting
## the cdf, `samples` from `sample`, ...), the parameter checks, the NaN and
## domain rules, and through `polarsExpr` the Polars plugin functions and the
## Nanuq twins.
##
## ```nim
## continuous exponential(rate: Positive):
##   proc support: (float, float) = (0.0, Inf)
##   proc pdf(x: float): float = (if x < 0: 0.0 else: rate * exp(-rate * x))
##   proc cdf(x: float): float = (if x < 0: 0.0 else: -expm1(-rate * x))
##   proc mean: float = 1 / rate
##   ...
## ```
##
## gives `exponentialPdf`, `exponentialLogPdf`, `exponentialCdf`, ... (15
## functions), each a plain Nim proc and a Polars plugin function.

import std/[macros, strutils, sets, sequtils]
import ../polarsplugin
import specfun
export specfun

type
  Finite* = float        ## any finite float parameter
  Positive* = float      ## a finite float > 0
  Probability* = float   ## a float in [0, 1]
  Count* = int64         ## an integer >= 0
  Integer* = int64       ## any integer

template require*(ok: bool, msg: string) =
  ## A parameter rule; a template, so the message is built only when it fails.
  if not ok: raise newException(ValueError, msg)

proc checkFinite*(x: float, name: string) {.inline.} =
  require(x - x == 0, name & " must be finite, got " & $x)
proc checkPositive*(x: float, name: string) {.inline.} =
  require(x > 0 and x < Inf, name & " must be finite and strictly positive, got " & $x)
proc checkProbability*(x: float, name: string) {.inline.} =
  require(x >= 0 and x <= 1, name & " must be in [0, 1], got " & $x)
proc checkCount*(x: int64, name: string) {.inline.} =
  require(x >= 0, name & " must be a non-negative integer, got " & $x)
proc checkInteger*(x: int64, name: string) {.inline.} = discard

type MethodSig = tuple[name, args, ret: string]


proc methodSigs(discrete: bool, sampleT: string): seq[MethodSig] =
  let d = if discrete: "Pmf" else: "Pdf"
  @[(d, "x: float", "float"), ("Log" & d, "x: float", "float"),
    ("Cdf", "x: float", "float"), ("LogCdf", "x: float", "float"),
    ("Sf", "x: float", "float"), ("LogSf", "x: float", "float"),
    ("Ppf", "q: float", "float"), ("Isf", "q: float", "float"),
    ("Sample", "rng: var RowRng", sampleT),
    ("Mean", "", "float"), ("Variance", "", "float"), ("Std", "", "float"),
    ("Median", "", "float"), ("Entropy", "", "float"),
    ("Support", "", "(float, float)"), ("Check", "", "void")]

proc capital(s: string): string = s[0].toUpperAscii & s[1 .. ^1]

proc distributionImpl(head, body: NimNode, discrete: bool): NimNode =
  head.expectKind {nnkCall, nnkObjConstr}
  let dist = $head[0]
  # Parameters: (name, kind), kind one of Finite, Positive, Probability, Count, Integer.
  var params: seq[(string, string)]
  for p in head[1 .. ^1]:
    p.expectKind nnkExprColonExpr
    params.add ($p[0], $p[1])
  let paramDecl = params.mapIt(it[0] & ": " & (if it[1] in ["Count", "Integer"]: "int64" else: "float")).join(", ")
  let paramArgs = params.mapIt(it[0]).join(", ")
  # The methods the block defines, and the sample type.
  var given = initHashSet[string]()
  var userProcs: seq[NimNode]
  var sampleT = (if discrete: "int64" else: "float")
  for st in body:
    if st.kind in {nnkCommentStmt}: continue
    st.expectKind nnkProcDef
    var m = capital($st.name)
    if m == "Logpdf": m = "LogPdf"
    given.incl m
    if m == "Sample": sampleT = st.params[0].repr
    userProcs.add st
  let sigs = methodSigs(discrete, sampleT)
  let d = if discrete: "Pmf" else: "Pdf"
  proc raw(m: string): string = dist & m & "Raw"
  proc join2(a, b: string): string = (if a.len == 0: b elif b.len == 0: a else: a & ", " & b)
  proc header(s: MethodSig): string =
    "proc " & raw(s.name) & "(" & join2(s.args, paramDecl) & "): " & s.ret & " {.inline.}"
  # Local templates: inside every method body, the other methods by their short names.
  var tmpl = ""
  for s in sigs:
    if s.name == "Check": continue
    let short = s.name[0].toLowerAscii & s.name[1 .. ^1]
    let argNames = s.args.split(", ").filterIt(it.len > 0).mapIt(it.split(":")[0].strip)
    let targs = s.args.replace("var RowRng", "var RowRng")
    tmpl.add "  template " & short & "(" & targs & "): " & s.ret & " {.used.} = " &
             raw(s.name) & "(" & join2(argNames.join(", "), paramArgs) & ")\n"
  # The defaults, for the methods the block does not give.
  var defaults: seq[(string, string)]
  template dflt(m, code: string) =
    if m notin given: defaults.add (m, code)
  dflt "Support", (if discrete: "(0.0, Inf)" else: "(-Inf, Inf)")
  dflt "Check", "discard"
  if d notin given: defaults.add (d, "exp(log" & d & "(x))")
  dflt "Log" & d, "ln(" & d.toLowerAscii & "(x))"
  if "Cdf" notin given: defaults.add ("Cdf", "1 - sf(x)")
  if "Sf" notin given: defaults.add ("Sf", "1 - cdf(x)")
  # Near 1, the log of the complement keeps the digits ln(1 - tiny) would lose.
  dflt "LogCdf", "let c = cdf(x)\n    if c > 0.5: ln1p(-sf(x)) else: ln(c)"
  dflt "LogSf", "let s = sf(x)\n    if s > 0.5: ln1p(-cdf(x)) else: ln(s)"
  if discrete:
    dflt "Ppf", "let (lo, hi) = support()\n    if q == 0: return lo\n    if q == 1: return hi\n    searchInteger(cdf(k) >= q * (1 - 4e-16), lo, hi, guess0(q))"
    dflt "Isf", "let (lo, hi) = support()\n    if q == 1: return lo\n    if q == 0: return hi\n    searchInteger(sf(k) <= q * (1 + 4e-16), lo, hi, guess0(1 - q))"
  else:
    dflt "Ppf", "let (lo, hi) = support()\n    if q == 0: return lo\n    if q == 1: return hi\n    solveIncreasing(cdf(x), pdf(x), q, lo, hi, guess0(q))"
    dflt "Isf", (if "Ppf" in given: "if q > 0.5: return ppf(1 - q)\n    " else: "") &
      "let (lo, hi) = support()\n    if q == 0: return hi\n    if q == 1: return lo\n    solveIncreasing(-sf(x), pdf(x), -q, lo, hi, guess0(1 - q))"
  dflt "Sample", sampleT & "(ppf(rng.uniform))"
  dflt "Median", "ppf(0.5)"
  dflt "Std", "sqrt(variance())"
  # A starting point for the numerical inverses: the mean when finite, else inside the support.
  let median0 = """
  template guess0(q: float): float {.used.} =
    block:
      let (lo0, hi0) = support()
      let m0 = mean()
      let v0 = variance()
      let g =
        if m0 - m0 == 0 and v0 - v0 == 0: m0 + sqrt(v0) * ndtri(q)
        elif m0 - m0 == 0: m0
        elif lo0 > -Inf: lo0 + 1
        elif hi0 < Inf: hi0 - 1
        else: 0.0
      system.clamp(g, lo0, hi0)
"""
  for m in ["Mean", "Variance", "Entropy"]:
    if m notin given: error(dist & ": define proc " & m.toLowerAscii)
  # Forward declarations, so methods can call each other in any order.
  var code = ""
  for s in sigs: code.add header(s) & "\n"
  for (m, body) in defaults:
    let s = sigs.filterIt(it.name == m)[0]
    code.add header(s) & " =\n" & tmpl & median0 & "  " & body.replace("\n    ", "\n  ") & "\n"
  when defined(distDebug): echo code
  result = parseStmt(code)
  # The given methods: their bodies, with the parameters and the templates in scope.
  for p in userProcs:
    var m = capital($p.name)
    if m == "Logpdf": m = "LogPdf"
    let s = sigs.filterIt(it.name == m)
    if s.len == 0: error("unknown method " & $p.name, p)
    let shell = parseStmt(header(s[0]) & " =\n" & tmpl & median0 & "  discard")[0]
    shell.body = newStmtList(shell.body[0 ..< ^1] & @[p.body])
    if p.params[0].kind != nnkEmpty and m != "Support" and m != "Sample":
      shell.params[0] = p.params[0]
    result.add shell
  # The public functions: parameter checks, the NaN and domain rules, then the method.
  var checks = ""
  for (n, k) in params: checks.add "  check" & k & "(" & n & ", \"" & n & "\")\n"
  checks.add "  " & raw("Check") & "(" & paramArgs & ")\n"
  var pub = ""
  for s in sigs:
    if s.name in ["Support", "Check"]: continue
    let call = raw(s.name) & "(" & join2(s.args.split(", ").filterIt(it.len > 0).mapIt(it.split(":")[0].strip).join(", "), paramArgs) & ")"
    let ret = (if s.name in ["Ppf", "Isf"]: "Option[float]" else: s.ret)
    pub.add "proc " & dist & s.name & "*(" & join2(s.args, paramDecl) & "): " & ret & " {.polarsExpr.} =\n" & checks
    if s.name in ["Ppf", "Isf"]:
      pub.add "  if isNaN(q): return some(NaN)\n  if not (q >= 0 and q <= 1): return none(float)\n  some(" & call & ")\n"
    elif s.args.startsWith("x"):
      pub.add "  if isNaN(x): return NaN\n  " & call & "\n"
    else:
      pub.add "  " & call & "\n"
  # samples(size): `size` consecutive draws of the row's stream.
  pub.add "proc " & dist & "Samples*(" & join2("rng: var RowRng, size: Size", paramDecl) & "): seq[" & sampleT &
          "] {.polarsExpr.} =\n" & checks & "  result = newSeq[" & sampleT & "](size.int)\n" &
          "  for k in 0 ..< size.int: result[k] = " & raw("Sample") & "(" & join2("rng", paramArgs) & ")\n"
  result.add parseStmt(pub)

macro continuous*(head, body: untyped): untyped =
  ## A continuous distribution: give pdf (or logPdf), cdf (or sf), mean,
  ## variance and entropy; anything else that is closed form makes it faster
  ## or more accurate than the derived default.
  distributionImpl(head, body, discrete = false)

macro discrete*(head, body: untyped): untyped =
  ## A discrete distribution on the integers of `support` (0 .. Inf by default).
  distributionImpl(head, body, discrete = true)
