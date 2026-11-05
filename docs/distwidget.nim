## The distribution explorer of nim_plugins.nim: the plugin module's own procs
## (`normalPdf`, `gammaPpf`, ...), compiled by Nim's JavaScript backend. It is
## included in an `nbJsFromCode` block, which nimib compiles with `nim js`.

import std/[dom, strutils, math, options]
import ../src/nanuqmore/stats_plugin

type
  Param = object
    name: string
    lo, hi, step, value: float
  Dist = object
    name: string
    discrete: bool
    params: seq[Param]
    dens, cdf, ppf: proc (x: float, p: seq[float]): float
    mean, variance, median, entropy: proc (p: seq[float]): float

proc P(name: string, lo, hi, step, value: float): Param =
  Param(name: name, lo: lo, hi: hi, step: step, value: value)

template dist1(label: string, pre: untyped, disc: bool, T0: typedesc, a: Param): Dist =
  Dist(name: label, discrete: disc, params: @[a],
    dens: proc (x: float, p: seq[float]): float =
      (when disc: `pre Pmf`(x, T0(p[0])) else: `pre Pdf`(x, T0(p[0]))),
    cdf: proc (x: float, p: seq[float]): float = `pre Cdf`(x, T0(p[0])),
    ppf: proc (x: float, p: seq[float]): float = `pre Ppf`(x, T0(p[0])).get,
    mean: proc (p: seq[float]): float = `pre Mean`(T0(p[0])),
    variance: proc (p: seq[float]): float = `pre Variance`(T0(p[0])),
    median: proc (p: seq[float]): float = `pre Median`(T0(p[0])),
    entropy: proc (p: seq[float]): float = `pre Entropy`(T0(p[0])))

template dist2(label: string, pre: untyped, disc: bool, T0, T1: typedesc, a, b: Param): Dist =
  Dist(name: label, discrete: disc, params: @[a, b],
    dens: proc (x: float, p: seq[float]): float =
      (when disc: `pre Pmf`(x, T0(p[0]), T1(p[1])) else: `pre Pdf`(x, T0(p[0]), T1(p[1]))),
    cdf: proc (x: float, p: seq[float]): float = `pre Cdf`(x, T0(p[0]), T1(p[1])),
    ppf: proc (x: float, p: seq[float]): float = `pre Ppf`(x, T0(p[0]), T1(p[1])).get,
    mean: proc (p: seq[float]): float = `pre Mean`(T0(p[0]), T1(p[1])),
    variance: proc (p: seq[float]): float = `pre Variance`(T0(p[0]), T1(p[1])),
    median: proc (p: seq[float]): float = `pre Median`(T0(p[0]), T1(p[1])),
    entropy: proc (p: seq[float]): float = `pre Entropy`(T0(p[0]), T1(p[1])))

let dists = @[
  dist2("Normal", normal, false, float, float, P("mu", -3, 3, 0.1, 0), P("sigma", 0.2, 3, 0.1, 1)),
  dist2("LogNormal", lognormal, false, float, float, P("mu", -1, 1, 0.05, 0), P("sigma", 0.1, 1.5, 0.05, 0.5)),
  dist1("Exponential", exponential, false, float, P("rate", 0.2, 5, 0.1, 1)),
  dist2("Gamma", gamma, false, float, float, P("shape", 0.5, 12, 0.1, 2), P("rate", 0.2, 4, 0.1, 1)),
  dist2("Beta", beta, false, float, float, P("a", 0.5, 10, 0.1, 2), P("b", 0.5, 10, 0.1, 5)),
  dist2("Weibull", weibull, false, float, float, P("shape", 0.5, 5, 0.1, 1.5), P("scale", 0.5, 3, 0.1, 1)),
  dist2("Pareto", pareto, false, float, float, P("scale", 0.5, 3, 0.1, 1), P("shape", 0.5, 6, 0.1, 2.5)),
  dist2("Cauchy", cauchy, false, float, float, P("loc", -3, 3, 0.1, 0), P("scale", 0.2, 3, 0.1, 1)),
  dist1("Poisson", poisson, true, float, P("rate", 0.5, 40, 0.5, 4)),
  dist2("Binomial", binomial, true, int64, float, P("n", 1, 60, 1, 20), P("p", 0, 1, 0.01, 0.3)),
  dist1("Geometric", geometric, true, float, P("p", 0.05, 1, 0.01, 0.3)),
  dist2("DiscreteUniform", discreteuniform, true, int64, int64, P("min", -5, 5, 1, 1), P("max", 6, 20, 1, 6)),
]

proc fmt(x: float): string =
  if x != x: "undefined"
  elif x == Inf: "∞"
  elif abs(x) >= 1000 or (abs(x) < 0.01 and x != 0): formatFloat(x, ffScientific, 2)
  else: formatFloat(x, ffDecimal, 3)

proc el(id: string): Element = document.getElementById(cstring(id))

var current = 0

proc params(): seq[float] =
  for i in 0 ..< dists[current].params.len:
    result.add parseFloat($InputElement(el("dw-p" & $i)).value)

proc draw() =
  let d = dists[current]
  let p = params()
  for i, pr in d.params:
    el("dw-v" & $i).innerHTML = cstring(if pr.step >= 1: $int(p[i]) else: fmt(p[i]))
  const W = 480.0
  const H = 280.0
  const pad = 26.0
  var svg = ""
  try:
    let tail = if d.name == "Cauchy": 0.03 else: 0.001
    var lo = d.ppf(tail, p)
    var hi = d.ppf(1 - tail, p)
    if d.discrete:
      lo = floor(lo); hi = max(ceil(hi), lo + 1)
      hi = min(hi, lo + 80)
    if hi <= lo: hi = lo + 1
    let sx = proc (x: float): float = pad + (x - lo) / (hi - lo) * (W - 2 * pad)
    var top = 0.0
    var pts: seq[(float, float)]
    if d.discrete:
      var k = lo
      while k <= hi:
        let y = d.dens(k, p)
        pts.add (k, y); top = max(top, y); k += 1
    else:
      for i in 0 .. 200:
        let x = lo + (hi - lo) * float(i) / 200
        let y = d.dens(x, p)
        pts.add (x, y)
        # the scale ignores a pole at the edge (gamma or Weibull with shape < 1)
        let c = d.cdf(x, p)
        if y < Inf and c > 0.01 and c < 0.99: top = max(top, y)
    if top <= 0 or top != top: top = 1
    let sy = proc (y: float): float = H - pad - min(y / top, 1.05) * (H - 2 * pad)
    svg.add "<line x1='" & $pad & "' x2='" & $(W - pad) & "' y1='" & $(H - pad) & "' y2='" & $(H - pad) &
            "' class='dw-axis'/>"
    if d.discrete:
      let bw = max(1.0, (W - 2 * pad) / (hi - lo + 1) * 0.7)
      for (k, y) in pts:
        svg.add "<rect class='dw-mass' x='" & $(sx(k) - bw / 2) & "' y='" & $sy(y) & "' width='" & $bw &
                "' height='" & $(H - pad - sy(y)) & "'/>"
    else:
      var path = "M" & $sx(lo) & "," & $(H - pad)
      for (x, y) in pts: path.add " L" & $sx(x) & "," & $sy(if y < Inf: y else: top)
      path.add " L" & $sx(hi) & "," & $(H - pad) & " Z"
      svg.add "<path class='dw-dens' d='" & path & "'/>"
    # the cdf, on its own 0..1 scale
    var cpath = ""
    for i in 0 .. 200:
      let x = lo + (hi - lo) * float(i) / 200
      let c = d.cdf(x, p)
      cpath.add (if i == 0: "M" else: " L") & $sx(x) & "," & $(H - pad - c * (H - 2 * pad))
    svg.add "<path class='dw-cdf' d='" & cpath & "'/>"
    for i in 0 .. 3:
      let x = lo + (hi - lo) * float(i) / 3
      let label = if d.discrete: $int(round(x)) else: fmt(x)
      let anchor = (if i == 0: "start" elif i == 3: "end" else: "middle")
      svg.add "<text class='dw-tick' text-anchor='" & anchor & "' x='" & $(if i == 0: 2.0 elif i == 3: W - 2 else: sx(x)) &
              "' y='" & $(H - 6) & "'>" & label & "</text>"
    el("dw-stats").innerHTML = cstring(
      "mean " & fmt(d.mean(p)) & " · sd " & fmt(sqrt(d.variance(p))) & " · median " & fmt(d.median(p)) &
      " · entropy " & fmt(d.entropy(p)) & " · 90% between " & fmt(d.ppf(0.05, p)) & " and " & fmt(d.ppf(0.95, p)))
  except ValueError as e:
    el("dw-stats").innerHTML = cstring("the plugin says: " & e.msg)
  el("dw-plot").innerHTML = cstring(svg)

proc build() =
  let d = dists[current]
  var html = ""
  for i, pr in d.params:
    html.add "<label class='dw-param'><span>" & pr.name & " <b id='dw-v" & $i & "'></b></span>" &
             "<input type='range' id='dw-p" & $i & "' min='" & $pr.lo & "' max='" & $pr.hi &
             "' step='" & $pr.step & "' value='" & $pr.value & "'></label>"
  el("dw-params").innerHTML = cstring(html)
  for i in 0 ..< d.params.len:
    el("dw-p" & $i).addEventListener("input", proc (e: Event) = draw())
  draw()

var choices = ""
for i, d in dists: choices.add "<option value='" & $i & "'>" & d.name & "</option>"
el("dw-dist").innerHTML = cstring(choices)
el("dw-dist").addEventListener("change", proc (e: Event) =
  current = parseInt($OptionElement(el("dw-dist")).value)
  build())
build()
