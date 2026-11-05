## Vectorized probability distributions as Polars plugin functions.
##
## Every function takes the evaluation point first and the parameters after
## it, all as columns (a literal is a length-1 column that broadcasts). Each
## one is a scalar Nim proc; `polarsExpr` makes the loop, the null handling,
## the broadcasting and the C exports.
##
## Build: nim c --app:lib -d:release -d:useMalloc --threads:on stats_plugin.nim

import std/math
import ../polarsplugin
nanuqBindings()

proc expm1(x: float): float {.importc, header: "<math.h>".}
proc ln1p(x: float): float {.importc: "log1p", header: "<math.h>".}

const Sqrt2 = sqrt(2.0)
const LnSqrt2Pi = 0.5 * ln(2.0 * PI)

template check(ok: bool, msg: string) =
  # A template, so the message is only built when the check fails.
  if not ok: raise newException(ValueError, msg)

template positive(x: float, name: string) =
  check(x > 0 and x < Inf, name & " must be finite and strictly positive, got " & $x)
template finite(x: float, name: string) =
  check(classify(x) notin {fcNan, fcInf, fcNegInf}, name & " must be finite, got " & $x)

# ------------------------------------------------------------- special functions

proc ndtri*(p: float): float =
  ## Inverse of the standard normal CDF: Wichura's AS241 (PPND16), ~1e-16 relative.
  if p <= 0: return (if p == 0: -Inf else: NaN)
  if p >= 1: return (if p == 1: Inf else: NaN)
  let q = p - 0.5
  if abs(q) <= 0.425:
    let r = 0.180625 - q * q
    return q * (((((((2509.0809287301226727 * r + 33430.575583588128105) * r +
      67265.770927008700853) * r + 45921.953931549871457) * r + 13731.693765509461125) * r +
      1971.5909503065514427) * r + 133.14166789178437745) * r + 3.387132872796366608) /
      (((((((5226.495278852545925 * r + 28729.085735721942674) * r + 39307.89580009271061) * r +
      21213.794301586595867) * r + 5394.1960214247511077) * r + 687.1870074920579083) * r +
      42.313330701600911252) * r + 1.0)
  var r = if q < 0: p else: 1 - p
  r = sqrt(-ln(r))
  var v: float
  if r <= 5:
    r -= 1.6
    v = (((((((7.7454501427834140764e-4 * r + 0.0227238449892691845833) * r +
      0.24178072517745061177) * r + 1.27045825245236838258) * r + 3.64784832476320460504) * r +
      5.7694972214606914055) * r + 4.6303378461565452959) * r + 1.42343711074968357734) /
      (((((((1.05075007164441684324e-9 * r + 5.475938084995344946e-4) * r +
      0.0151986665636164571966) * r + 0.14810397642748007459) * r + 0.68976733498510000455) * r +
      1.6763848301838038494) * r + 2.05319162663775882187) * r + 1.0)
  else:
    r -= 5
    v = (((((((2.01033439929228813265e-7 * r + 2.71155556874348757815e-5) * r +
      0.0012426609473880784386) * r + 0.026532189526576123093) * r + 0.29656057182850489123) * r +
      1.7848265399172913358) * r + 5.4637849111641143699) * r + 6.6579046435011037772) /
      (((((((2.04426310338993978564e-15 * r + 1.4215117583164458887e-7) * r +
      1.8463183175100546818e-5) * r + 7.868691311456132591e-4) * r + 0.0148753612908506148525) * r +
      0.13692988092273580531) * r + 0.59983220655588793769) * r + 1.0)
  if q < 0: -v else: v

proc gammaP*(a, x: float): float
proc gammaQ*(a, x: float): float =
  ## Regularized upper incomplete gamma Q(a, x) = 1 - P(a, x).
  if x <= 0: return 1.0
  if x < a + 1: return 1.0 - gammaP(a, x)
  # Lentz's continued fraction.
  const tiny = 1e-300
  var b = x + 1 - a
  var c = 1 / tiny
  var d = 1 / b
  var h = d
  for i in 1 .. 500:
    let an = -float(i) * (float(i) - a)
    b += 2
    d = an * d + b
    if abs(d) < tiny: d = tiny
    c = b + an / c
    if abs(c) < tiny: c = tiny
    d = 1 / d
    let del = d * c
    h *= del
    if abs(del - 1) < 1e-16: break
  exp(-x + a * ln(x) - lgamma(a)) * h

proc gammaP*(a, x: float): float =
  ## Regularized lower incomplete gamma P(a, x).
  if x <= 0: return 0.0
  if x >= a + 1: return 1.0 - gammaQ(a, x)
  var ap = a
  var sum = 1 / a
  var del = sum
  for _ in 1 .. 1000:
    ap += 1
    del *= x / ap
    sum += del
    if abs(del) < abs(sum) * 1e-17: break
  sum * exp(-x + a * ln(x) - lgamma(a))

proc betacf(a, b, x: float): float =
  const tiny = 1e-300
  let qab = a + b
  let qap = a + 1
  let qam = a - 1
  var c = 1.0
  var d = 1 - qab * x / qap
  if abs(d) < tiny: d = tiny
  d = 1 / d
  var h = d
  for m in 1 .. 1000:
    let m2 = 2.0 * float(m)
    var aa = float(m) * (b - float(m)) * x / ((qam + m2) * (a + m2))
    d = 1 + aa * d
    if abs(d) < tiny: d = tiny
    c = 1 + aa / c
    if abs(c) < tiny: c = tiny
    d = 1 / d
    h *= d * c
    aa = -(a + float(m)) * (qab + float(m)) * x / ((a + m2) * (qap + m2))
    d = 1 + aa * d
    if abs(d) < tiny: d = tiny
    c = 1 + aa / c
    if abs(c) < tiny: c = tiny
    d = 1 / d
    let del = d * c
    h *= del
    if abs(del - 1) < 1e-16: break
  h

proc betaI*(a, b, x: float): float =
  ## Regularized incomplete beta I_x(a, b).
  if x <= 0: return 0.0
  if x >= 1: return 1.0
  let lbt = lgamma(a + b) - lgamma(a) - lgamma(b) + a * ln(x) + b * ln(1 - x)
  if x < (a + 1) / (a + b + 2): exp(lbt) * betacf(a, b, x) / a
  else: 1 - exp(lbt) * betacf(b, a, 1 - x) / b

proc stdNormal(r: var RowRng): float =
  ## Inversion: one draw of the row's stream through the inverse CDF
  ## (faster than Box-Muller's log, sqrt and cos).
  ndtri(r.uniform)

proc stdGamma(r: var RowRng, a: float): float =
  ## Marsaglia and Tsang; boosted for a < 1.
  if a < 1:
    return stdGamma(r, a + 1) * pow(r.uniform, 1 / a)
  let d = a - 1 / 3
  let c = 1 / sqrt(9 * d)
  while true:
    var x, v: float
    while true:
      x = stdNormal(r)
      v = 1 + c * x
      if v > 0: break
    v = v * v * v
    let u = r.uniform
    if ln(u) < 0.5 * x * x + d - d * v + d * ln(v): return d * v

# ------------------------------------------------------------- normal

proc normalPdf*(x, mu, sigma: float): float {.polarsExpr.} =
  finite mu, "mu"; positive sigma, "sigma"
  let z = (x - mu) / sigma
  exp(-0.5 * z * z - LnSqrt2Pi) / sigma

proc normalLogPdf*(x, mu, sigma: float): float {.polarsExpr.} =
  finite mu, "mu"; positive sigma, "sigma"
  let z = (x - mu) / sigma
  -0.5 * z * z - LnSqrt2Pi - ln(sigma)

proc normalCdf*(x, mu, sigma: float): float {.polarsExpr.} =
  finite mu, "mu"; positive sigma, "sigma"
  0.5 * erfc((mu - x) / (sigma * Sqrt2))

proc normalSf*(x, mu, sigma: float): float {.polarsExpr.} =
  finite mu, "mu"; positive sigma, "sigma"
  0.5 * erfc((x - mu) / (sigma * Sqrt2))

proc normalPpf*(q, mu, sigma: float): Option[float] {.polarsExpr.} =
  finite mu, "mu"; positive sigma, "sigma"
  if q < 0 or q > 1: none(float) else: some(mu + sigma * ndtri(q))

proc normalSample*(rng: var RowRng, mu, sigma: float): float {.polarsExpr.} =
  finite mu, "mu"; positive sigma, "sigma"
  mu + sigma * stdNormal(rng)

# ------------------------------------------------------------- log-normal

proc lognormalPdf*(x, mu, sigma: float): float {.polarsExpr.} =
  finite mu, "mu"; positive sigma, "sigma"
  if x <= 0: return 0.0
  let z = (ln(x) - mu) / sigma
  exp(-0.5 * z * z - LnSqrt2Pi) / (sigma * x)

proc lognormalCdf*(x, mu, sigma: float): float {.polarsExpr.} =
  finite mu, "mu"; positive sigma, "sigma"
  if x <= 0: 0.0 else: 0.5 * erfc((mu - ln(x)) / (sigma * Sqrt2))

proc lognormalPpf*(q, mu, sigma: float): Option[float] {.polarsExpr.} =
  finite mu, "mu"; positive sigma, "sigma"
  if q < 0 or q > 1: none(float) else: some(exp(mu + sigma * ndtri(q)))

proc lognormalSample*(rng: var RowRng, mu, sigma: float): float {.polarsExpr.} =
  finite mu, "mu"; positive sigma, "sigma"
  exp(mu + sigma * stdNormal(rng))

# ------------------------------------------------------------- exponential (rate)

proc exponentialPdf*(x, rate: float): float {.polarsExpr.} =
  positive rate, "rate"
  if x < 0: 0.0 else: rate * exp(-rate * x)

proc exponentialCdf*(x, rate: float): float {.polarsExpr.} =
  positive rate, "rate"
  if x < 0: 0.0 else: -expm1(-rate * x)

proc exponentialSf*(x, rate: float): float {.polarsExpr.} =
  positive rate, "rate"
  if x < 0: 1.0 else: exp(-rate * x)

proc exponentialPpf*(q, rate: float): Option[float] {.polarsExpr.} =
  positive rate, "rate"
  if q < 0 or q > 1: none(float) else: some(-ln1p(-q) / rate)

proc exponentialSample*(rng: var RowRng, rate: float): float {.polarsExpr.} =
  positive rate, "rate"
  -ln(rng.uniform) / rate

# ------------------------------------------------------------- uniform [low, high]

proc uniformPdf*(x, low, high: float): float {.polarsExpr.} =
  finite low, "low"; finite high, "high"
  check(low < high, "high must be greater than low")
  if x < low or x > high: 0.0 else: 1 / (high - low)

proc uniformCdf*(x, low, high: float): float {.polarsExpr.} =
  finite low, "low"; finite high, "high"
  check(low < high, "high must be greater than low")
  clamp((x - low) / (high - low), 0.0, 1.0)

proc uniformSample*(rng: var RowRng, low, high: float): float {.polarsExpr.} =
  finite low, "low"; finite high, "high"
  check(low < high, "high must be greater than low")
  low + (high - low) * rng.uniform

# ------------------------------------------------------------- gamma (shape, rate)

proc gammaPdf*(x, shape, rate: float): float {.polarsExpr.} =
  positive shape, "shape"; positive rate, "rate"
  if x < 0: return 0.0
  if x == 0: return (if shape < 1: Inf elif shape == 1: rate else: 0.0)
  exp(shape * ln(rate) + (shape - 1) * ln(x) - rate * x - lgamma(shape))

proc gammaCdf*(x, shape, rate: float): float {.polarsExpr.} =
  positive shape, "shape"; positive rate, "rate"
  gammaP(shape, rate * x)

proc gammaSf*(x, shape, rate: float): float {.polarsExpr.} =
  positive shape, "shape"; positive rate, "rate"
  gammaQ(shape, rate * x)

proc gammaSample*(rng: var RowRng, shape, rate: float): float {.polarsExpr.} =
  positive shape, "shape"; positive rate, "rate"
  stdGamma(rng, shape) / rate

# ------------------------------------------------------------- beta

proc betaPdf*(x, a, b: float): float {.polarsExpr.} =
  positive a, "alpha"; positive b, "beta"
  if x < 0 or x > 1: return 0.0
  exp((a - 1) * ln(x) + (b - 1) * ln1p(-x) + lgamma(a + b) - lgamma(a) - lgamma(b))

proc betaCdf*(x, a, b: float): float {.polarsExpr.} =
  positive a, "alpha"; positive b, "beta"
  betaI(a, b, x)

proc betaSample*(rng: var RowRng, a, b: float): float {.polarsExpr.} =
  positive a, "alpha"; positive b, "beta"
  let x = stdGamma(rng, a)
  x / (x + stdGamma(rng, b))

# ------------------------------------------------------------- poisson

proc poissonPmf*(k, lam: float): float {.polarsExpr.} =
  positive lam, "lambda"
  if k < 0 or k != floor(k): return 0.0
  exp(k * ln(lam) - lam - lgamma(k + 1))

proc poissonCdf*(k, lam: float): float {.polarsExpr.} =
  positive lam, "lambda"
  if k < 0: 0.0 else: gammaQ(floor(k) + 1, lam)

proc poissonSample*(rng: var RowRng, lam: float): int64 {.polarsExpr.} =
  positive lam, "lambda"
  if lam < 30:
    # Inversion by sequential search.
    var k = 0'i64
    var p = exp(-lam)
    var s = p
    let u = rng.uniform
    while u > s and k < 1000:
      inc k
      p *= lam / float(k)
      s += p
    return k
  # Hormann's PTRS (transformed rejection with squeeze).
  let slam = sqrt(lam)
  let loglam = ln(lam)
  let b = 0.931 + 2.53 * slam
  let a = -0.059 + 0.02483 * b
  let invalpha = 1.1239 + 1.1328 / (b - 3.4)
  let vr = 0.9277 - 3.6224 / (b - 2)
  while true:
    let u = rng.uniform - 0.5
    let v = rng.uniform
    let us = 0.5 - abs(u)
    let k = floor((2 * a / us + b) * u + lam + 0.43)
    if us >= 0.07 and v <= vr: return int64(k)
    if k < 0 or (us < 0.013 and v > us): continue
    if ln(v) + ln(invalpha) - ln(a / (us * us) + b) <= -lam + k * loglam - lgamma(k + 1):
      return int64(k)
