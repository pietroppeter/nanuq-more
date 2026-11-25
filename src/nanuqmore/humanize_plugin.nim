## Python's `humanize` (4.17), vectorized: a Polars plugin written in Nim.
##
## Every function gives the same text as the Python function of the same
## name, in English (humanize's default locale); the options are keyword
## arguments, read once per call. A value humanize would turn into an error
## gives null here.
##
## Build: nim c --app:lib -d:release -d:useMalloc --threads:on humanize_plugin.nim

import std/[math, strutils]
import ../polarsplugin
from ../polarsplugin/arrow as pa import nil  # Nanuq has an ArrowArray too
import pyformat
nanuqBindings()

# ---------------------------------------------------------------- inputs

type
  Num* = object
    ## A number from any numeric column: humanize treats ints and floats apart
    ## (`intcomma(1000)` is "1,000", `intcomma(1000.0)` is "1,000.0").
    isFloat*: bool
    i*: int64
    f*: float64

  TimeKind* = enum tkNumber, tkDuration, tkDatetime, tkDate
  TimeValue* = object
    ## A number of seconds, a Duration, a Datetime or a Date (in microseconds,
    ## since 1970-01-01 for the last two). Time zones are not looked at.
    kind*: TimeKind
    us*: int64
    n*: Num

type Prepared = distinct bool
  ## set by `prepare`; not a keyword argument (only plain fields are)

template ensurePrepared(opts: typed, call: untyped) =
  ## The plugin prepares options once per call; a direct Nim call with a
  ## fresh options object (`SizeOpts()`) gets them prepared here.
  if not opts.ready.bool:
    var o {.inject.} = opts
    prepare(o)
    return call

proc toFloat*(n: Num): float = (if n.isFloat: n.f else: n.i.float)

proc readValue*(T: typedesc[Num], fmt: string, a: ptr pa.ArrowArray, i: int): Num =
  if fmt in ["g", "f"]: Num(isFloat: true, f: numericAt(fmt, a, i))
  elif fmt == "b": Num(i: int64(numericAt(fmt, a, i)))
  elif fmt == "L":
    let u = cast[uint64](intAt(fmt, a, i))
    if u > uint64(high(int64)): Num(isFloat: true, f: u.float) else: Num(i: u.int64)
  else: Num(i: intAt(fmt, a, i))

proc readValue*(T: typedesc[TimeValue], fmt: string, a: ptr pa.ArrowArray, i: int): TimeValue =
  template int64At(): int64 = cast[ptr UncheckedArray[int64]](a.buffers[1])[a.offset.int + i]
  template scale(u: char, v: int64): int64 =
    case u
    of 's': v * 1_000_000
    of 'm': v * 1_000
    of 'u': v
    of 'n': floorDiv(v, 1_000)
    else: raise newException(PluginError, "unknown time unit in Arrow format '" & fmt & "'")
  if fmt == "tdD": TimeValue(kind: tkDate, us: intAt(fmt, a, i) * 86_400_000_000)
  elif fmt == "tdm": TimeValue(kind: tkDate, us: int64At() * 1_000)
  elif fmt.startsWith("ts"): TimeValue(kind: tkDatetime, us: scale(fmt[2], int64At()))
  elif fmt.startsWith("tD"): TimeValue(kind: tkDuration, us: scale(fmt[2], int64At()))
  else: TimeValue(kind: tkNumber, n: readValue(Num, fmt, a, i))

# ---------------------------------------------------------------- helpers

proc notFinite(x: float): string =
  ## humanize's `_format_not_finite`
  if x.isNaN: "NaN" elif x < 0: "-Inf" else: "+Inf"

proc plural(n: float, singular, many: string): string =
  ## English `ngettext`: the singular for exactly 1.
  if n == 1: singular else: many

proc truncated(n: Num): (bool, int64, float) =
  ## `int(value)`: (fits in int64, the int, the same as a whole float).
  if not n.isFloat: return (true, n.i, n.i.float)
  let t = trunc(n.f) + 0.0
  if abs(t) < 9.0e18: (true, int64(t), t) else: (false, 0'i64, t)

# ---------------------------------------------------------------- filesize

type SizeOpts* = object
  ready: Prepared
  binary*: bool
  gnu*: bool
  format*: string = "%.1f"
  fmt: PyFormat

proc prepare*(o: var SizeOpts) =
  o.fmt = parsePyFormat(o.format)
  o.ready = Prepared(true)

const
  decimalSuffixes = ["kB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB", "RB", "QB"]
  binarySuffixes = ["KiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB", "YiB", "RiB", "QiB"]
  gnuSuffixes = "KMGTPEZYRQ"

proc naturalsize*(value: Num, opts: Kw[SizeOpts]): Option[string] {.polarsExpr.} =
  ## A number of bytes as a file size: "3.0 MB", "2.9 KiB", "2.9K".
  ensurePrepared(opts, naturalsize(value, o))
  let bytes = value.toFloat
  if bytes.isNaN or (opts.fmt.isInteger and abs(bytes) == Inf): return none(string)
  let base = if opts.gnu or opts.binary: 1024.0 else: 1000.0
  let absBytes = abs(bytes)
  let (_, _, whole) = truncated(Num(isFloat: true, f: bytes))
  if absBytes == 1 and not opts.gnu: return some(intStr(whole) & " Byte")
  if absBytes < base:
    return some(if opts.gnu: intStr(whole) & "B" else: intStr(whole) & " Bytes")
  const lnBinary = ln(1024.0)
  const lnDecimal = ln(1000.0)
  var exp = int(min(ln(absBytes) / (if base == 1024: lnBinary else: lnDecimal), 10.0))
  var mantissa = opts.fmt % (bytes / pow(base, exp.float))
  if exp < 10 and abs(opts.fmt.readBack(mantissa)) >= base:
    inc exp
    mantissa = opts.fmt % (bytes / pow(base, exp.float))
  some(if opts.gnu: mantissa & gnuSuffixes[exp - 1]
       elif opts.binary: mantissa & " " & binarySuffixes[exp - 1]
       else: mantissa & " " & decimalSuffixes[exp - 1])

# ---------------------------------------------------------------- numbers

type OrdinalOpts* = object
  gender*: string = "male"   ## only changes the result in translations

proc ordinal*(value: Num, opts: Kw[OrdinalOpts]): string {.polarsExpr.} =
  ## 1st, 2nd, 3rd, 4th, 11th, 101st.
  if value.isFloat and (value.f.isNaN or abs(value.f) == Inf): return notFinite(value.f)
  let (fits, i, w) = truncated(value)
  let m100 = if fits: floorMod(i, 100).float else: (let m = w mod 100.0; if m < 0: m + 100 else: m)
  let digit = if m100 in [11.0, 12.0, 13.0]: 0 else: int(m100) mod 10
  const suffixes = ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"]
  (if fits: $i else: intStr(w)) & suffixes[digit]

type IntcommaOpts* = object
  ndigits*: int = -1         ## -1: None

proc intcomma*(value: Num, opts: Kw[IntcommaOpts]): string {.polarsExpr.} =
  ## Commas every three digits: 1,000,000; floats keep their digits (1,234,567.25).
  if value.isFloat and (value.f.isNaN or abs(value.f) == Inf): return notFinite(value.f)
  if opts.ndigits >= 0: groupThousands(fixed(value.toFloat, opts.ndigits))
  elif value.isFloat: groupThousands(pyRepr(value.f))
  else: groupThousands($value.i)

type IntwordOpts* = object
  ready: Prepared
  format*: string = "%.1f"
  fmt: PyFormat

proc prepare*(o: var IntwordOpts) =
  o.fmt = parsePyFormat(o.format)
  o.ready = Prepared(true)

const powerWords = ["thousand", "million", "billion", "trillion", "quadrillion", "quintillion",
                    "sextillion", "septillion", "octillion", "nonillion", "decillion", "googol"]
const powerExps = [3, 6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 100]

proc intword*(value: Num, opts: Kw[IntwordOpts]): string {.polarsExpr.} =
  ## Large numbers in words: 1.2 million, 8.1 decillion.
  ensurePrepared(opts, intword(value, o))
  if value.isFloat and (value.f.isNaN or abs(value.f) == Inf): return notFinite(value.f)
  let (fits, i, w) = truncated(value)
  let neg = w < 0
  let prefix = if neg: "-" else: ""
  let v = abs(w)
  if v < 1000: return prefix & (if fits: $abs(i) else: intStr(v))
  var k = 0
  while k + 1 < powerExps.len and v >= pow(10.0, powerExps[k + 1].float): inc k
  let power = pow(10.0, powerExps[k].float)
  # int / int in Python is correctly rounded: split off the exact quotient first
  let chopped =
    if fits: (let q = abs(i) div int64(power); q.float + float(abs(i) - q * int64(power)) / power)
    else: v / power
  var rounded = opts.fmt.roundByFormat(chopped)
  if k + 1 < powerExps.len and rounded == pow(10.0, float(powerExps[k + 1] - powerExps[k])):
    inc k
    rounded = 1.0
  prefix & (opts.fmt % rounded) & " " & powerWords[k]

proc apnumber*(value: Num): string {.polarsExpr.} =
  ## Associated Press style: zero to nine in words, other numbers in digits.
  if value.isFloat and (value.f.isNaN or abs(value.f) == Inf): return notFinite(value.f)
  let (fits, i, w) = truncated(value)
  const words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
  if fits and i in 0'i64 .. 9'i64: words[i] elif fits: $i else: intStr(w)

# fractional: Fraction(x).limit_denominator(1000), exactly, on 128-bit integers

type U128 = object
  hi, lo: uint64

proc u128(x: uint64): U128 = U128(lo: x)
proc `<`(a, b: U128): bool = a.hi < b.hi or (a.hi == b.hi and a.lo < b.lo)
proc `<=`(a, b: U128): bool = not (b < a)
proc `-`(a, b: U128): U128 =
  result.lo = a.lo - b.lo
  result.hi = a.hi - b.hi - (if a.lo < b.lo: 1'u64 else: 0'u64)
proc `*`(a: U128, s: uint64): U128 =
  ## `s` below 2^32
  let l0 = (a.lo and 0xffff_ffff'u64) * s
  let l1 = (a.lo shr 32) * s + (l0 shr 32)
  result.lo = (l1 shl 32) or (l0 and 0xffff_ffff'u64)
  result.hi = a.hi * s + (l1 shr 32)
proc toFloat(a: U128): float = a.hi.float * 18446744073709551616.0 + a.lo.float
proc pow2(e: int): U128 =
  if e < 64: U128(lo: 1'u64 shl e) else: U128(hi: 1'u64 shl (e - 64))

proc divCapped(n, d: U128, cap: uint64): uint64 =
  ## min(n div d, cap)
  let est = n.toFloat / d.toFloat
  if est > cap.float + 2: return cap
  var a = uint64(max(est, 0.0))
  while a > 0 and n < d * a: dec a
  while a < cap and d * (a + 1) <= n: inc a
  a

proc limitDenominator(x: float, maxDen = 1000'u64): (uint64, uint64) =
  ## The fraction closest to `x` in [0, 1) with a denominator up to `maxDen`
  ## (Python's `Fraction.limit_denominator`).
  if x == 0: return (0'u64, 1'u64)
  var e: int
  let fr = frexp(x, e)                     # x = fr * 2^e, fr in [0.5, 1)
  var m = uint64(fr * 9007199254740992.0)  # fr * 2^53
  var k = 53 - e                           # x = m / 2^k
  while k > 0 and (m and 1) == 0: m = m shr 1; dec k
  if k <= 9: return (m, 1'u64 shl k)       # the denominator is already small enough
  if k > 100: return (0'u64, 1'u64)        # x < 2^-47
  let den = pow2(k)
  var (p0, q0, p1, q1) = (0'u64, 1'u64, 1'u64, 0'u64)
  var n = u128(m)
  var d = den
  while true:
    let a = divCapped(n, d, maxDen + 1)
    let q2 = q0 + a * q1
    if q2 > maxDen: break
    (p0, q0, p1, q1) = (p1, q1, p0 + a * p1, q2)
    (n, d) = (d, n - d * a)
  let kk = (maxDen - q0) div q1
  if d * (2 * (q0 + kk * q1)) <= den: (p1, q1)
  else: (p0 + kk * p1, q0 + kk * q1)

proc fractional*(value: Num): string {.polarsExpr.} =
  ## A whole number, a fraction or a mixed fraction: 1/3, 1 3/10.
  let number = value.toFloat
  if number.isNaN or abs(number) == Inf: return notFinite(number)
  let whole = trunc(number) + 0.0
  let frac = number - whole
  var (num, den) = limitDenominator(abs(frac))
  let sign = if frac < 0: -1.0 else: 1.0
  if den == 1: return intStr(whole + sign * num.float)
  if whole == 0: return (if frac < 0: "-" else: "") & $num & "/" & $den
  intStr(whole) & " " & $num & "/" & $den

type ScientificOpts* = object
  precision*: int = 2

proc superscript(s: string): string =
  const sup = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
  for c in s: result.add(if c == '-': "⁻" else: sup[ord(c) - ord('0')])

proc sciText(x: float, precision: int): string =
  let s = sci(x, precision)
  let at = s.find('e')
  s[0 ..< at] & " x 10" & superscript($parseInt(s[at + 1 .. ^1]))

proc scientific*(value: Num, opts: Kw[ScientificOpts]): string {.polarsExpr.} =
  ## Scientific notation: 3.00 x 10⁻¹.
  let x = value.toFloat
  if x.isNaN or abs(x) == Inf: return notFinite(x)
  sciText(x, opts.precision)

type MetricOpts* = object
  unit*: string
  precision*: int = 3

proc metric*(value: Num, opts: Kw[MetricOpts]): string {.polarsExpr.} =
  ## An SI prefix: 1.50 kV, 220 μF.
  var x = value.toFloat
  if x.isNaN or abs(x) == Inf: return notFinite(x)
  var exponent = if x != 0: int(floor(log10(abs(x)))) else: 0
  if exponent >= 33 or exponent < -30:
    return sciText(x, opts.precision - 1) & opts.unit
  let oldBucket = floorDiv(exponent, 3) * 3
  x /= pow(10.0, oldBucket.float)
  var digits = max(0, opts.precision - floorMod(exponent, 3) - 1)
  if exponent < 30 and pyRound(abs(x), digits) >= pow(10.0, float(floorMod(exponent, 3) + 1)):
    inc exponent
    let newBucket = floorDiv(exponent, 3) * 3
    x /= pow(10.0, float(newBucket - oldBucket))
    digits = max(0, opts.precision - floorMod(exponent, 3) - 1)
  const big = ["k", "M", "G", "T", "P", "E", "Z", "Y", "R", "Q"]
  const small = ["m", "μ", "n", "p", "f", "a", "z", "y", "r", "q"]
  let prefix = if exponent >= 3: big[exponent div 3 - 1]
               elif exponent < 0: small[(-exponent - 1) div 3]
               else: ""
  let space = if (opts.unit.len == 0 and prefix.len == 0) or opts.unit in ["°", "′", "″"]: "" else: " "
  fixed(x, digits) & space & prefix & opts.unit

# ---------------------------------------------------------------- time

const
  usPerSec = 1_000_000'i64
  usPerDay = 86_400 * usPerSec

type Unit = enum
  uMicroseconds = "microseconds", uMilliseconds = "milliseconds", uSeconds = "seconds",
  uMinutes = "minutes", uHours = "hours", uDays = "days", uMonths = "months", uYears = "years"

proc parseUnit(s: string): Unit =
  for u in Unit:
    if cmpIgnoreCase($u, s) == 0: return u
  raise newException(ValueError, "unknown unit '" & s & "' (expected one of " &
                     "microseconds, milliseconds, seconds, minutes, hours, days, months, years)")

proc secondsToUs(x: float): Option[int64] =
  ## `timedelta(seconds=x)`: to whole microseconds, ties to even.
  if x.isNaN or abs(x) >= 86_400.0 * 1_000_000_000: return none(int64)
  let ip = trunc(x)
  some(int64(ip) * usPerSec + int64(pyRound((x - ip) * 1e6)))

type DeltaOpts* = object
  ready: Prepared
  months*: bool = true
  minimumUnit*: string = "seconds"
  minUnit: Unit

proc prepare*(o: var DeltaOpts) =
  o.minUnit = parseUnit(o.minimumUnit)
  if o.minUnit notin {uSeconds, uMilliseconds, uMicroseconds}:
    raise newException(ValueError, "Minimum unit '" & o.minimumUnit & "' not supported")
  o.ready = Prepared(true)

proc deltaText(us: int64, months: bool, minUnit: Unit): string =
  let d = abs(us)
  let allDays = d div usPerDay
  let seconds = (d mod usPerDay) div usPerSec
  let micro = d mod usPerSec
  let years = allDays div 365
  let days = allDays mod 365
  let numMonths = int(pyRound(days.float / 30.5))
  if years == 0 and days < 1:
    if seconds == 0:
      if minUnit == uMicroseconds and micro < 1000:
        return $micro & plural(micro.float, " microsecond", " microseconds")
      if minUnit == uMilliseconds or (minUnit == uMicroseconds and micro in 1000'i64 ..< usPerSec):
        let ms = micro div 1000
        return $ms & plural(ms.float, " millisecond", " milliseconds")
      return "a moment"
    if seconds == 1: return "a second"
    if seconds < 60: return $seconds & " seconds"
    if seconds < 3600:
      let minutes = int(pyRound(seconds.float / 60))
      if minutes == 1: return "a minute"
      if minutes == 60: return "an hour"
      return $minutes & " minutes"
    let hours = int(pyRound(seconds.float / 3600))
    if hours == 1: return "an hour"
    if hours == 24: return "a day"
    return $hours & " hours"
  elif years == 0:
    if days == 1: return "a day"
    if not months or numMonths == 0: return $days & " days"
    if numMonths == 1: return "a month"
    if numMonths == 12: return "a year"
    return $numMonths & " months"
  elif years == 1:
    if numMonths == 0 and days == 0: return "a year"
    if numMonths == 0 or not months: return "1 year, " & $days & plural(days.float, " day", " days")
    if numMonths == 1: return "1 year, 1 month"
    if numMonths == 12: return "2 years"
    return "1 year, " & $numMonths & " months"
  groupThousands($int64(pyRound(allDays.float / 365))) & " years"

proc naturaldelta*(value: TimeValue, opts: Kw[DeltaOpts]): Option[string] {.polarsExpr.} =
  ## A Duration or a number of seconds in words, rounded: "an hour", "3 days", "1 year, 2 months".
  ensurePrepared(opts, naturaldelta(value, o))
  var us: int64
  case value.kind
  of tkDuration: us = value.us
  of tkNumber:
    if value.n.isFloat and value.n.f.isNaN: return some("nan")
    if value.n.isFloat and abs(value.n.f) == Inf: return some(if value.n.f > 0: "inf" else: "-inf")
    let s = secondsToUs(value.n.toFloat)
    if s.isNone: return none(string)
    us = s.get
  else: raise newException(PluginError, "naturaldelta takes a Duration or a number of seconds")
  some deltaText(us, opts.months, opts.minUnit)

type TimeOpts* = object
  ready: Prepared
  future*: bool
  months*: bool = true
  minimumUnit*: string = "seconds"
  minUnit: Unit

proc prepare*(o: var TimeOpts) =
  var d = DeltaOpts(minimumUnit: o.minimumUnit)
  prepare(d)
  o.minUnit = d.minUnit
  o.ready = Prepared(true)

proc naturaltime*(value, now: TimeValue, opts: Kw[TimeOpts]): Option[string] {.polarsExpr.} =
  ## How long ago, or from now: "an hour ago", "3 days from now", "now".
  ## Datetimes and Dates count from `now` (humanize's `when`); a Duration is positive in the past;
  ## a number of seconds is in the past unless `future`.
  ensurePrepared(opts, naturaltime(value, now, o))
  var us: int64
  var future = opts.future
  case value.kind
  of tkDatetime, tkDate:
    if now.kind notin {tkDatetime, tkDate}:
      raise newException(PluginError, "naturaltime: `now` must be a Datetime or a Date")
    us = now.us - value.us
    future = value.us > now.us
  of tkDuration:
    us = value.us
    future = us < 0
  of tkNumber:
    let x = value.n.toFloat
    if x.isNaN: return some("nan")
    let s = secondsToUs(pyRound(x))
    if s.isNone: return none(string)
    us = s.get
  let text = deltaText(us, opts.months, opts.minUnit)
  if text == "a moment": return some("now")
  some(if future: text & " from now" else: text & " ago")

# dates: civil calendar (Howard Hinnant's algorithms) and a C-locale strftime

proc civil(z: int64): (int, int, int) =
  let z = z + 719468
  let era = floorDiv(z, 146097)
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  (int(yoe + era * 400 + (if m <= 2: 1 else: 0)), int(m), int(d))

proc daysFromCivil(y, m, d: int): int64 =
  let y = if m <= 2: y - 1 else: y
  let era = floorDiv(y, 400)
  let yoe = y - era * 400
  let doy = (153 * (if m > 2: m - 3 else: m + 9) + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  int64(era * 146097 + doe - 719468)

const
  monthNames = ["January", "February", "March", "April", "May", "June", "July",
                "August", "September", "October", "November", "December"]
  dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
  strftimeCodes = {'a', 'A', 'b', 'B', 'd', 'e', 'j', 'm', 'u', 'w', 'y', 'Y', 'H', 'M', 'S', 'p', 'h', 'F', '%'}

proc checkStrftime(f: string) =
  var i = 0
  while i < f.len:
    if f[i] == '%':
      if i + 1 >= f.len or f[i + 1] notin strftimeCodes:
        raise newException(ValueError, "unsupported strftime format '" & f &
                           "' (codes: %a %A %b %B %d %e %j %m %u %w %y %Y %F %H %M %S %p %%)")
      inc i
    inc i

proc strftime(days: int64, f: string): string =
  let (y, m, d) = civil(days)
  let wd = int(floorMod(days + 3, 7))   # Monday = 0
  var i = 0
  while i < f.len:
    if f[i] == '%' and i + 1 < f.len:
      case f[i + 1]
      of 'a': result.add dayNames[wd][0 .. 2]
      of 'A': result.add dayNames[wd]
      of 'b', 'h': result.add monthNames[m - 1][0 .. 2]
      of 'B': result.add monthNames[m - 1]
      of 'd': result.add align($d, 2, '0')
      of 'e': result.add align($d, 2, ' ')
      of 'j': result.add align($(days - daysFromCivil(y, 1, 1) + 1), 3, '0')
      of 'm': result.add align($m, 2, '0')
      of 'u': result.add $(wd + 1)
      of 'w': result.add $((wd + 1) mod 7)
      of 'y': result.add align($floorMod(y, 100), 2, '0')
      of 'Y': result.add $y
      of 'F': result.add $y & "-" & align($m, 2, '0') & "-" & align($d, 2, '0')
      of 'H', 'M', 'S': result.add "00"
      of 'p': result.add "AM"
      else: result.add '%'
      i += 2
    else:
      result.add f[i]; inc i

proc dayOf(v: TimeValue, fn: string): int64 =
  if v.kind notin {tkDate, tkDatetime}:
    raise newException(PluginError, fn & " takes a Date or a Datetime")
  floorDiv(v.us, usPerDay)

type DayOpts* = object
  format*: string = "%b %d"

proc prepare*(o: var DayOpts) = checkStrftime(o.format)

proc naturalday*(value, today: TimeValue, opts: Kw[DayOpts]): string {.polarsExpr.} =
  ## "today", "tomorrow", "yesterday", else the date in `format` ("Nov 25").
  let day = dayOf(value, "naturalday")
  case day - dayOf(today, "naturalday")
  of 0: "today"
  of 1: "tomorrow"
  of -1: "yesterday"
  else: strftime(day, opts.format)

proc naturaldate*(value, today: TimeValue): string {.polarsExpr.} =
  ## As `naturalday`, with the year for dates five months away or more ("Nov 25 2027").
  let day = dayOf(value, "naturaldate")
  let delta = day - dayOf(today, "naturaldate")
  if abs(delta).float >= 5 * 365 / 12: naturalday(value, today, DayOpts(format: "%b %d %Y"))
  else: naturalday(value, today, DayOpts())

type PreciseOpts* = object
  ready: Prepared
  minimumUnit*: string = "seconds"
  suppress*: seq[string]
  format*: string = "%0.2f"
  minUnit: Unit
  suppressed: set[Unit]
  fmt: PyFormat

proc prepare*(o: var PreciseOpts) =
  o.fmt = parsePyFormat(o.format)
  for s in o.suppress: o.suppressed.incl parseUnit(s)
  o.minUnit = parseUnit(o.minimumUnit)
  if o.minUnit in o.suppressed:
    var found = false
    for u in Unit:
      if u > o.minUnit and u notin o.suppressed:
        o.minUnit = u; found = true; break
    if not found:
      raise newException(ValueError, "Minimum unit is suppressed and no suitable replacement was found")
  for u in Unit:
    if u == o.minUnit: break
    o.suppressed.incl u
  o.ready = Prepared(true)

proc pyDivmod(x, y: float): (float, float) =
  ## Python's float divmod (positive values here).
  let m = x mod y
  let d = (x - m) / y
  var q = floor(d)
  if d - q > 0.5: q += 1
  (q, m)

proc precisedelta*(value: TimeValue, opts: Kw[PreciseOpts]): Option[string] {.polarsExpr.} =
  ## A Duration or a number of seconds, exactly, down to `minimumUnit`:
  ## "2 days, 1 hour and 33.12 seconds".
  ensurePrepared(opts, precisedelta(value, o))
  var us: int64
  case value.kind
  of tkDuration: us = value.us
  of tkNumber:
    if value.n.isFloat and value.n.f.isNaN: return some("nan")
    let s = secondsToUs(value.n.toFloat)
    if s.isNone: return none(string)
    us = s.get
  else: raise newException(PluginError, "precisedelta takes a Duration or a number of seconds")
  us = abs(us)
  let o = opts
  template qr(value, divisor: float, unit: Unit): (float, float) =
    if unit == o.minUnit: (o.fmt.roundByFormat(value / divisor), 0.0)
    elif unit in o.suppressed: (0.0, value)
    else: (let (q, r) = pyDivmod(value, divisor); (q, trunc(r)))
  var days = float(us div usPerDay)
  var secs = float((us mod usPerDay) div usPerSec)
  var usecs = float(us mod usPerSec)
  var years, months, hours, minutes, msecs: float
  (years, days) = qr(days, 365, uYears)
  (months, days) = qr(days, 30.5, uMonths)
  secs = days * 24 * 3600 + secs
  (days, secs) = qr(secs, 24 * 3600, uDays)
  (hours, secs) = qr(secs, 3600, uHours)
  (minutes, secs) = qr(secs, 60, uMinutes)
  usecs = secs * 1e6 + usecs
  (secs, usecs) = qr(usecs, 1e6, uSeconds)
  (msecs, usecs) = qr(usecs, 1000, uMilliseconds)
  if msecs >= 1000 and uSeconds notin o.suppressed: msecs -= 1000; secs += 1
  if secs >= 60 and uMinutes notin o.suppressed: secs -= 60; minutes += 1
  if minutes >= 60 and uHours notin o.suppressed: minutes -= 60; hours += 1
  if hours >= 24 and uDays notin o.suppressed: hours -= 24; days += 1
  if days >= 31 and uMonths notin o.suppressed: days -= 31; months += 1
  if months >= 12 and uYears notin o.suppressed: months -= 12; years += 1
  let values = [(uYears, years, "year"), (uMonths, months, "month"), (uDays, days, "day"),
                (uHours, hours, "hour"), (uMinutes, minutes, "minute"), (uSeconds, secs, "second"),
                (uMilliseconds, msecs, "millisecond"), (uMicroseconds, usecs, "microsecond")]
  # the parts, joined by ", " and the last one by " and " (one string, no list)
  var text = newStringOfCap(64)
  var parts = 0
  var lastSep = 0
  template part(body: untyped) =
    if parts > 0:
      lastSep = text.len
      text.add ", "
    body
    inc parts
  for (unit, v, name) in values:
    if v > 0 or (parts == 0 and unit == o.minUnit):
      let n = if 1 < v and v < 2: 2.0 else: trunc(v)
      if unit == o.minUnit and v - trunc(v) > 0:
        part: text.add o.fmt % v
      elif unit == uYears:
        part: text.add groupThousands(intStr(trunc(v)))
      else:
        part: text.add intStr(trunc(v))
      text.add ' '
      text.add name
      if n != 1: text.add 's'
      if unit == uYears and not (unit == o.minUnit and v - trunc(v) > 0):
        continue   # as humanize 4.17: skips the stop below, so with minimumUnit "years"
                   # what is left over still shows, in microseconds (upstream bug)
    if unit == o.minUnit: break
  if parts > 1:
    text = text.substr(0, lastSep - 1) & " and " & text.substr(lastSep + 2)
  some(text)

# ---------------------------------------------------------------- Nanuq: humanize's arguments

when declared(polarsPluginLib):
  ## In Nanuq, besides the twins that take an options object
  ## (`naturalsize(col"bytes", SizeOpts(binary: true))`), each function takes
  ## humanize's arguments by name: `naturalsize(col"bytes", binary = true)`.
  import std/times

  proc localNow(): Expr =
    ## now as naive local time (humanize's `datetime.now()`)
    let n = now()
    lit((n.toTime - initDuration(seconds = n.utcOffset)).utc)

  proc localToday(): Expr =
    let n = now()
    lit(date(n.year, n.month, n.monthday))

  proc naturalsize*(value: Expr, binary = false, gnu = false, format = "%.1f"): Expr =
    naturalsize(value, SizeOpts(binary: binary, gnu: gnu, format: format))
  proc ordinal*(value: Expr, gender = "male"): Expr = ordinal(value, OrdinalOpts(gender: gender))
  proc intcomma*(value: Expr, ndigits = -1): Expr = intcomma(value, IntcommaOpts(ndigits: ndigits))
  proc intword*(value: Expr, format = "%.1f"): Expr = intword(value, IntwordOpts(format: format))
  proc scientific*(value: Expr, precision = 2): Expr = scientific(value, ScientificOpts(precision: precision))
  proc metric*(value: Expr, unit = "", precision = 3): Expr =
    metric(value, MetricOpts(unit: unit, precision: precision))
  proc naturaldelta*(value: Expr, months = true, minimumUnit = "seconds"): Expr =
    naturaldelta(value, DeltaOpts(months: months, minimumUnit: minimumUnit))
  proc naturaltime*(value: Expr, now = localNow(), future = false, months = true,
                    minimumUnit = "seconds"): Expr =
    naturaltime(value, now, TimeOpts(future: future, months: months, minimumUnit: minimumUnit))
  proc naturalday*(value: Expr, today = localToday(), format = "%b %d"): Expr =
    naturalday(value, today, DayOpts(format: format))
  proc naturaldate*(value: Expr): Expr = naturaldate(value, localToday())
  proc precisedelta*(value: Expr, minimumUnit = "seconds", suppress: seq[string] = @[],
                     format = "%0.2f"): Expr =
    precisedelta(value, PreciseOpts(minimumUnit: minimumUnit, suppress: suppress, format: format))
