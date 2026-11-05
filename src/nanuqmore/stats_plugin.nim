## The distributions of polars-stats, as Polars plugin functions written in Nim.
##
## Each block below holds only the math particular to one distribution; the
## `continuous` / `discrete` macros (see `distmacro`) derive the rest and make
## every method a Polars plugin function, a Nanuq expression and a plain Nim
## proc. Parameter names and conventions follow polars-stats (and so scipy):
## `Gamma(shape, rate)`, `Geometric` counts trials (support 1, 2, ...), `ppf`
## of a quantile outside [0, 1] is null.
##
## Build: nim c --app:lib -d:release -d:useMalloc --threads:on stats_plugin.nim

import ../polarsplugin
import specfun, distmacro
export specfun
nanuqBindings()

# ------------------------------------------------------------- samplers

proc stdNormal*(r: var RowRng): float {.inline.} =
  ## The ziggurat (see polarsplugin/rowrng): usually one 64-bit draw.
  r.normal

proc stdGamma*(r: var RowRng, a: float): float =
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

proc poissonDraw(r: var RowRng, lam: float): uint64 =
  if lam < 30:
    # Inversion by sequential search.
    var k = 0'u64
    var p = exp(-lam)
    var s = p
    let u = r.uniform
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
    let u = r.uniform - 0.5
    let v = r.uniform
    let us = 0.5 - abs(u)
    let k = floor((2 * a / us + b) * u + lam + 0.43)
    if us >= 0.07 and v <= vr: return uint64(k)
    if k < 0 or (us < 0.013 and v > us): continue
    if ln(v) + ln(invalpha) - ln(a / (us * us) + b) <= -lam + k * loglam - lgamma(k + 1):
      return uint64(k)

proc binomialDraw(r: var RowRng, n: int64, p: float): uint64 =
  ## Splitting by beta order statistics (Devroye X.4) down to n <= 64, then
  ## one Bernoulli trial per remaining draw.
  var n = n
  var p = p
  var k = 0'i64
  while n > 64:
    let a = 1 + n div 2
    let b = n + 1 - a
    let ga = stdGamma(r, float(a))
    let x = ga / (ga + stdGamma(r, float(b)))
    if x >= p:
      n = a - 1; p = p / x
    else:
      k += a; n = b - 1; p = (p - x) / (1 - x)
  for _ in 1 .. n:
    if r.uniform < p: inc k
  uint64(k)

template sumEntropy(lo0, hi0, mean0, var0: float, logPmfAt: untyped): float =
  ## Shannon entropy by summing over mean +- 40 sd; the normal limit when that
  ## range is huge (its error is then below 1e-9).
  block:
    let sd = sqrt(var0)
    if sd > 1e4: 0.5 * ln(2 * PI * E * var0)
    else:
      var h = 0.0
      let a = max(lo0, floor(mean0 - 40 * sd - 10))
      let b = min(hi0, ceil(mean0 + 40 * sd + 10))
      var k {.inject.} = a
      while k <= b:
        let lp = logPmfAt
        if lp > -Inf: h -= exp(lp) * lp
        k += 1
      h

# ------------------------------------------------------------- continuous

continuous normal(mu: Finite, sigma: Positive):
  proc pdf(x: float): float =
    let z = (x - mu) / sigma
    exp(-0.5 * z * z - LnSqrt2Pi) / sigma
  proc logPdf(x: float): float =
    let z = (x - mu) / sigma
    -0.5 * z * z - LnSqrt2Pi - ln(sigma)
  proc cdf(x: float): float = 0.5 * erfc((mu - x) / (sigma * Sqrt2))
  proc sf(x: float): float = 0.5 * erfc((x - mu) / (sigma * Sqrt2))
  proc logCdf(x: float): float = logNdtr((x - mu) / sigma)
  proc logSf(x: float): float = logNdtr((mu - x) / sigma)
  proc ppf(q: float): float = mu + sigma * ndtri(q)
  proc isf(q: float): float = mu - sigma * ndtri(q)
  proc sample(rng: var RowRng): float = mu + sigma * stdNormal(rng)
  proc mean: float = mu
  proc variance: float = sigma * sigma
  proc std: float = sigma
  proc median: float = mu
  proc entropy: float = 0.5 * ln(2 * PI * E * sigma * sigma)

continuous lognormal(mu: Finite, sigma: Positive):
  proc support: (float, float) = (0.0, Inf)
  proc logPdf(x: float): float =
    if x <= 0: return -Inf
    let z = (ln(x) - mu) / sigma
    -0.5 * z * z - LnSqrt2Pi - ln(sigma * x)
  proc cdf(x: float): float = (if x <= 0: 0.0 else: 0.5 * erfc((mu - ln(x)) / (sigma * Sqrt2)))
  proc sf(x: float): float = (if x <= 0: 1.0 else: 0.5 * erfc((ln(x) - mu) / (sigma * Sqrt2)))
  proc logCdf(x: float): float = (if x <= 0: -Inf else: logNdtr((ln(x) - mu) / sigma))
  proc logSf(x: float): float = (if x <= 0: 0.0 else: logNdtr((mu - ln(x)) / sigma))
  proc ppf(q: float): float = exp(mu + sigma * ndtri(q))
  proc isf(q: float): float = exp(mu - sigma * ndtri(q))
  proc sample(rng: var RowRng): float = exp(mu + sigma * stdNormal(rng))
  proc mean: float = exp(mu + 0.5 * sigma * sigma)
  proc variance: float = expm1(sigma * sigma) * exp(2 * mu + sigma * sigma)
  proc median: float = exp(mu)
  proc entropy: float = mu + 0.5 * ln(2 * PI * E * sigma * sigma)

continuous exponential(rate: Positive):
  proc support: (float, float) = (0.0, Inf)
  proc pdf(x: float): float = (if x < 0: 0.0 else: rate * exp(-rate * x))
  proc logPdf(x: float): float = (if x < 0: -Inf else: ln(rate) - rate * x)
  proc cdf(x: float): float = (if x < 0: 0.0 else: -expm1(-rate * x))
  proc sf(x: float): float = (if x < 0: 1.0 else: exp(-rate * x))
  proc logCdf(x: float): float =
    if x < 0: -Inf elif rate * x > ln(2.0): ln1p(-exp(-rate * x)) else: ln(-expm1(-rate * x))
  proc logSf(x: float): float = (if x < 0: 0.0 else: -rate * x)
  proc ppf(q: float): float = -ln1p(-q) / rate
  proc isf(q: float): float = -ln(q) / rate
  proc sample(rng: var RowRng): float = -ln(rng.uniform) / rate
  proc mean: float = 1 / rate
  proc variance: float = 1 / (rate * rate)
  proc median: float = ln(2.0) / rate
  proc entropy: float = 1 - ln(rate)

continuous uniform(min: Finite, max: Finite):
  proc check = require(min < max, "max must be greater than min, got min=" & $min & ", max=" & $max)
  proc support: (float, float) = (min, max)
  proc pdf(x: float): float = (if x < min or x > max: 0.0 else: 1 / (max - min))
  proc cdf(x: float): float = clamp((x - min) / (max - min), 0.0, 1.0)
  proc sf(x: float): float = clamp((max - x) / (max - min), 0.0, 1.0)
  proc ppf(q: float): float = min + q * (max - min)
  proc isf(q: float): float = max - q * (max - min)
  proc sample(rng: var RowRng): float = min + (max - min) * rng.uniform
  proc mean: float = min + 0.5 * (max - min)
  proc variance: float = (max - min) * (max - min) / 12
  proc median: float = min + 0.5 * (max - min)
  proc entropy: float = ln(max - min)

continuous gamma(shape: Positive, rate: Positive):
  proc support: (float, float) = (0.0, Inf)
  proc logPdf(x: float): float =
    if x < 0: return -Inf
    if x == 0: return (if shape < 1: Inf elif shape == 1: ln(rate) else: -Inf)
    shape * ln(rate) + (shape - 1) * ln(x) - rate * x - lgamma(shape)
  proc cdf(x: float): float = gammaP(shape, rate * x)
  proc sf(x: float): float = gammaQ(shape, rate * x)
  proc sample(rng: var RowRng): float = stdGamma(rng, shape) / rate
  proc mean: float = shape / rate
  proc variance: float = shape / (rate * rate)
  proc entropy: float = shape - ln(rate) + lgamma(shape) + (1 - shape) * digamma(shape)

continuous beta(a: Positive, b: Positive):
  proc support: (float, float) = (0.0, 1.0)
  proc logPdf(x: float): float =
    if x < 0 or x > 1: return -Inf
    (a - 1) * ln(x) + (b - 1) * ln1p(-x) - lbeta(a, b)
  proc cdf(x: float): float = betaI(a, b, x)
  proc sf(x: float): float = betaIc(a, b, x)
  proc sample(rng: var RowRng): float =
    let x = stdGamma(rng, a)
    x / (x + stdGamma(rng, b))
  proc mean: float = a / (a + b)
  proc variance: float = a * b / ((a + b) * (a + b) * (a + b + 1))
  proc entropy: float =
    lbeta(a, b) - (a - 1) * digamma(a) - (b - 1) * digamma(b) + (a + b - 2) * digamma(a + b)

continuous cauchy(loc: Finite, scale: Positive):
  proc pdf(x: float): float =
    let z = (x - loc) / scale
    1 / (PI * scale * (1 + z * z))
  proc logPdf(x: float): float =
    let z = (x - loc) / scale
    -ln(PI * scale) - ln1p(z * z)
  proc cdf(x: float): float =
    let z = (x - loc) / scale
    if z < 0: arctan(-1 / z) / PI else: 0.5 + arctan(z) / PI
  proc sf(x: float): float =
    let z = (loc - x) / scale
    if z < 0: arctan(-1 / z) / PI else: 0.5 + arctan(z) / PI
  proc ppf(q: float): float = (if q == 1: Inf else: loc - scale / tan(PI * q))
  proc isf(q: float): float = (if q == 1: -Inf else: loc + scale / tan(PI * q))
  proc sample(rng: var RowRng): float = loc - scale / tan(PI * rng.uniform)
  proc mean: float = NaN          # undefined
  proc variance: float = NaN
  proc median: float = loc
  proc entropy: float = ln(4 * PI * scale)

continuous pareto(scale: Positive, shape: Positive):
  proc support: (float, float) = (scale, Inf)
  proc logPdf(x: float): float =
    if x < scale: -Inf else: ln(shape) + shape * ln(scale) - (shape + 1) * ln(x)
  proc cdf(x: float): float = (if x <= scale: 0.0 else: -expm1(shape * ln(scale / x)))
  proc sf(x: float): float = (if x <= scale: 1.0 else: exp(shape * ln(scale / x)))
  proc logSf(x: float): float = (if x <= scale: 0.0 else: shape * ln(scale / x))
  proc ppf(q: float): float = scale * exp(-ln1p(-q) / shape)
  proc isf(q: float): float = scale * exp(-ln(q) / shape)
  proc sample(rng: var RowRng): float = scale * exp(-ln(rng.uniform) / shape)
  proc mean: float = (if shape > 1: shape * scale / (shape - 1) else: Inf)
  proc variance: float =
    if shape > 2: scale * scale * shape / ((shape - 1) * (shape - 1) * (shape - 2)) else: Inf
  proc entropy: float = ln(scale / shape) + 1 / shape + 1

continuous weibull(shape: Positive, scale: Positive):
  proc support: (float, float) = (0.0, Inf)
  proc logPdf(x: float): float =
    if x < 0: return -Inf
    if x == 0: return (if shape < 1: Inf elif shape == 1: -ln(scale) else: -Inf)
    let z = x / scale
    ln(shape / scale) + (shape - 1) * ln(z) - pow(z, shape)
  proc cdf(x: float): float = (if x <= 0: 0.0 else: -expm1(-pow(x / scale, shape)))
  proc sf(x: float): float = (if x <= 0: 1.0 else: exp(-pow(x / scale, shape)))
  proc logSf(x: float): float = (if x <= 0: 0.0 else: -pow(x / scale, shape))
  proc ppf(q: float): float = scale * pow(-ln1p(-q), 1 / shape)
  proc isf(q: float): float = scale * pow(-ln(q), 1 / shape)
  proc sample(rng: var RowRng): float = scale * pow(-ln(rng.uniform), 1 / shape)
  proc mean: float = scale * exp(lgamma(1 + 1 / shape))
  proc variance: float =
    scale * scale * (exp(lgamma(1 + 2 / shape)) - exp(2 * lgamma(1 + 1 / shape)))
  proc entropy: float = EulerGamma * (1 - 1 / shape) + ln(scale / shape) + 1

# ------------------------------------------------------------- discrete

discrete bernoulli(p: Probability):
  proc support: (float, float) = (0.0, 1.0)
  proc pmf(x: float): float = (if x == 0: 1 - p elif x == 1: p else: 0.0)
  proc logPmf(x: float): float = (if x == 0: ln1p(-p) elif x == 1: ln(p) else: -Inf)
  proc cdf(x: float): float = (if x < 0: 0.0 elif x < 1: 1 - p else: 1.0)
  proc sf(x: float): float = (if x < 0: 1.0 elif x < 1: p else: 0.0)
  proc logCdf(x: float): float = (if x < 0: -Inf elif x < 1: ln1p(-p) else: 0.0)
  proc logSf(x: float): float = (if x < 0: 0.0 elif x < 1: ln(p) else: -Inf)
  proc ppf(q: float): float =
    if q == 1: (if p > 0: 1.0 else: 0.0) elif q > 1 - p: 1.0 else: 0.0
  proc isf(q: float): float = (if p > q: 1.0 else: 0.0)
  proc sample(rng: var RowRng): bool = rng.uniform < p
  proc mean: float = p
  proc variance: float = p * (1 - p)
  proc entropy: float =
    (if p > 0: -p * ln(p) else: 0.0) + (if p < 1: -(1 - p) * ln1p(-p) else: 0.0)

discrete binomial(n: Count, p: Probability):
  proc support: (float, float) = (0.0, float(n))
  proc logPmf(x: float): float =
    if x < 0 or x > float(n) or x != floor(x): return -Inf
    if p == 0: return (if x == 0: 0.0 else: -Inf)
    if p == 1: return (if x == float(n): 0.0 else: -Inf)
    let nf = float(n)
    lgamma(nf + 1) - lgamma(x + 1) - lgamma(nf - x + 1) + x * ln(p) + (nf - x) * ln1p(-p)
  proc cdf(x: float): float =
    let k = floor(x)
    if k < 0: 0.0 elif k >= float(n): 1.0 else: betaIc(k + 1, float(n) - k, p)
  proc sf(x: float): float =
    let k = floor(x)
    if k < 0: 1.0 elif k >= float(n): 0.0 else: betaI(k + 1, float(n) - k, p)
  proc sample(rng: var RowRng): uint64 = binomialDraw(rng, n, p)
  proc mean: float = float(n) * p
  proc variance: float = float(n) * p * (1 - p)
  proc entropy: float = sumEntropy(0.0, float(n), mean(), variance(), logPmf(k))

discrete poisson(rate: Positive):
  proc logPmf(x: float): float =
    if x < 0 or x != floor(x): -Inf else: x * ln(rate) - rate - lgamma(x + 1)
  proc cdf(x: float): float = (if x < 0: 0.0 else: gammaQ(floor(x) + 1, rate))
  proc sf(x: float): float = (if x < 0: 1.0 else: gammaP(floor(x) + 1, rate))
  proc sample(rng: var RowRng): uint64 = poissonDraw(rng, rate)
  proc mean: float = rate
  proc variance: float = rate
  proc entropy: float = sumEntropy(0.0, Inf, rate, rate, logPmf(k))

discrete geometric(p: Probability):
  ## Trials up to and including the first success: support 1, 2, ...
  proc check = require(p > 0, "p must be in (0, 1], got " & $p)
  proc support: (float, float) = (1.0, Inf)
  proc logPmf(x: float): float =
    if x < 1 or x != floor(x): -Inf
    elif p == 1: (if x == 1: 0.0 else: -Inf)
    else: (x - 1) * ln1p(-p) + ln(p)
  proc cdf(x: float): float = (if x < 1: 0.0 elif p == 1: 1.0 else: -expm1(floor(x) * ln1p(-p)))
  proc sf(x: float): float = (if x < 1: 1.0 elif p == 1: 0.0 else: exp(floor(x) * ln1p(-p)))
  proc logSf(x: float): float = (if x < 1: 0.0 elif p == 1: -Inf else: floor(x) * ln1p(-p))
  proc sample(rng: var RowRng): uint64 =
    if p == 1: 1'u64 else: uint64(max(1.0, ceil(ln(rng.uniform) / ln1p(-p))))
  proc mean: float = 1 / p
  proc variance: float = (1 - p) / (p * p)
  proc entropy: float = (if p == 1: 0.0 else: (-(1 - p) * ln1p(-p) - p * ln(p)) / p)

discrete discreteuniform(min: Integer, max: Integer):
  ## Every integer in [min, max] equally likely.
  proc check = require(min <= max, "max must be at least min, got min=" & $min & ", max=" & $max)
  proc support: (float, float) = (float(min), float(max))
  proc pmf(x: float): float =
    if x < float(min) or x > float(max) or x != floor(x): 0.0 else: 1 / float(max - min + 1)
  proc cdf(x: float): float = clamp((floor(x) - float(min) + 1) / float(max - min + 1), 0.0, 1.0)
  proc sf(x: float): float = clamp((float(max) - floor(x)) / float(max - min + 1), 0.0, 1.0)
  proc sample(rng: var RowRng): int64 =
    min + int64(floor(rng.uniform * float(max - min + 1)))
  proc mean: float = 0.5 * (float(min) + float(max))
  proc variance: float =
    let w = float(max - min + 1)
    (w * w - 1) / 12
  proc entropy: float = ln(float(max - min + 1))
