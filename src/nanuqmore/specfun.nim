## Special functions behind the distributions: plain Nim, so they compile to
## C for the plugin and to JavaScript for the browser.

import std/math
export math

when defined(js):
  func expm1*(x: float): float {.importjs: "Math.expm1(#)".}
  func ln1p*(x: float): float {.importjs: "Math.log1p(#)".}

  func lgamma*(x: float): float =
    ## Lanczos (g = 7, n = 9), ~1e-15 relative for x > 0.
    const c = [0.99999999999980993, 676.5203681218851, -1259.1392167224028,
               771.32342877765313, -176.61502916214059, 12.507343278686905,
               -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7]
    if x < 0.5: return ln(PI / abs(sin(PI * x))) - lgamma(1 - x)
    let x = x - 1
    var a = c[0]
    let t = x + 7.5
    for i in 1 .. 8: a += c[i] / (x + float(i))
    0.5 * ln(2 * PI) + (x + 0.5) * ln(t) - t + ln(a)

  func erfc*(x: float): float =
    ## Chebyshev fit (Numerical Recipes erfcc), ~1.2e-7 relative: plenty for a plot.
    let z = abs(x)
    let t = 1 / (1 + 0.5 * z)
    let r = t * exp(-z * z - 1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 +
      t * (-0.18628806 + t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 +
      t * (-0.82215223 + t * 0.17087277)))))))))
    if x >= 0: r else: 2 - r
else:
  func expm1*(x: float): float {.importc, header: "<math.h>".}
  func ln1p*(x: float): float {.importc: "log1p", header: "<math.h>".}

const
  Sqrt2* = sqrt(2.0)
  LnSqrt2Pi* = 0.5 * ln(2.0 * PI)
  EulerGamma* = 0.57721566490153286061

func isNaN*(x: float): bool {.inline.} = x != x

func ndtri*(p: float): float =
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

func logNdtr*(z: float): float =
  ## ln Phi(z), without underflow in the lower tail (asymptotic series below -20).
  if z > 0: return ln1p(-0.5 * erfc(z / Sqrt2))
  if z > -20: return ln(0.5 * erfc(-z / Sqrt2))
  # Phi(z) ~ phi(z) / |z| * (1 - 1/z^2 + 3/z^4 - 15/z^6 + 105/z^8)
  let z2 = z * z
  -0.5 * z2 - LnSqrt2Pi - ln(-z) + ln1p(-1 / z2 + 3 / (z2 * z2) - 15 / (z2 * z2 * z2) + 105 / (z2 * z2 * z2 * z2))

func digamma*(x: float): float =
  ## psi(x) for x > 0: recurrence up to 10, then the asymptotic series.
  var x = x
  var r = 0.0
  while x < 10:
    r -= 1 / x
    x += 1
  let f = 1 / (x * x)
  r + ln(x) - 0.5 / x - f * (1.0 / 12 - f * (1.0 / 120 - f * (1.0 / 252 - f * (1.0 / 240 - f / 132))))

func lbeta*(a, b: float): float = lgamma(a) + lgamma(b) - lgamma(a + b)

func gammaP*(a, x: float): float
func gammaQ*(a, x: float): float =
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

func gammaP*(a, x: float): float =
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

func betacf(a, b, x: float): float =
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

func betaI*(a, b, x: float): float =
  ## Regularized incomplete beta I_x(a, b). Each branch of the continued
  ## fraction gives one tail directly; when the complement of a tail would
  ## cancel, the other fraction gives it directly instead.
  if x <= 0: return 0.0
  if x >= 1: return 1.0
  let front = exp(-lbeta(a, b) + a * ln(x) + b * ln1p(-x))
  if x < (a + 1) / (a + b + 2):
    front * betacf(a, b, x) / a
  else:
    let r = front * betacf(b, a, 1 - x) / b
    if r < 0.9: 1 - r else: front * betacf(a, b, x) / a

func betaIc*(a, b, x: float): float =
  ## 1 - I_x(a, b), computed without the cancellation.
  if x <= 0: return 1.0
  if x >= 1: return 0.0
  let front = exp(-lbeta(a, b) + a * ln(x) + b * ln1p(-x))
  if x < (a + 1) / (a + b + 2):
    let r = front * betacf(a, b, x) / a
    if r < 0.9: 1 - r else: front * betacf(b, a, 1 - x) / b
  else:
    front * betacf(b, a, 1 - x) / b

template solveIncreasing*(f, df: untyped, target, lo, hi, guess: float): float =
  ## The x in [lo, hi] with f(x) = target, for an increasing f with derivative
  ## df: Newton steps from the guess, kept inside a bracket that every
  ## evaluation narrows; a step that leaves the bracket bisects it instead (or
  ## grows it, while one side is still unbounded). `f` and `df` are
  ## expressions in the injected `x`.
  block:
    var a = lo
    var b = hi
    var x {.inject.} = guess
    for _ in 0 ..< 300:
      let fx = f - target
      if fx == 0: break
      if fx < 0: a = x else: b = x
      let d = df
      var nx = x - fx / d
      if not (nx > a and nx < b):
        nx =
          if a > -Inf and b < Inf: (if a == 0 and b > 0: 0.25 * b else: 0.5 * (a + b))
          elif a == -Inf: x - 2 * system.max(1.0, abs(x))
          else: x + 2 * system.max(1.0, abs(x))
      if abs(nx - x) <= 2e-16 * abs(x) or
         (b < Inf and a > -Inf and b - a <= 4e-16 * system.max(abs(a), abs(b))):
        x = nx
        break
      x = nx
    x

template searchInteger*(test: untyped, lo, hi, guess: float): float =
  ## The smallest integer k in [lo, hi] for which `test` (an expression in the
  ## injected `k`) holds, for a test that is false then true.
  block:
    var k {.inject.} = system.clamp(floor(guess), lo, hi)
    var a, b: float
    if test:
      b = k
      var step = 1.0
      a = b - step
      while a > lo:
        k = a
        if not test: break
        b = a; step *= 2; a = b - step
      if a <= lo: a = lo - 1    # test(a) is false, or a is below the support
    else:
      a = k
      var step = 1.0
      b = a + step
      while b < hi:
        k = b
        if test: break
        a = b; step *= 2; b = a + step
      b = system.min(b, hi)
    while b - a > 1:
      k = floor(0.5 * (a + b))
      if test: b = k else: a = k
    b
