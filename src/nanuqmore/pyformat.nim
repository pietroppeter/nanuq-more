## Python's number formatting, the bits humanize uses: `%`-style formats
## (`"%.1f" % x`), `round`, `repr(float)` and the `,` thousands separator.
## Formats go through C's snprintf, which rounds the exact binary value
## correctly (as CPython does), so the digits match Python's.

import std/[math, strutils]
import std/private/dragonbox

proc c_snprintf(buf: cstring, n: csize_t, fmt: cstring): cint
  {.importc: "snprintf", header: "<stdio.h>", varargs.}

template cfmt(spec: string, x: typed): string =
  var r = newString(64)
  var n = c_snprintf(cstring(r), 64, cstring(spec), x)
  if n >= 64:
    r = newString(n + 1)
    n = c_snprintf(cstring(r), csize_t(n + 1), cstring(spec), x)
  r.setLen(n)
  r

# Fast paths. Nim's dragonbox gives the shortest digits D that read back as x.
# When x's ulp is finer than the step we round to, x and D round the same way
# (a rounding boundary between them would itself be a shorter or closer
# decimal that reads back as x), unless D sits exactly on the boundary: then
# the exact binary value decides, and snprintf is asked.

const pow10tab = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15]

type DigitBuf = object
  ## decimal digits in a fixed buffer (no allocation)
  len: int
  d: array[40, char]

proc shortest(x: float, ds: var DigitBuf): int =
  ## Puts the shortest digits D of |x| in `ds` (no trailing zeros) and
  ## returns e, |x| = D * 10^e (x finite, not zero).
  let d = constructDouble(abs(x))
  let dec = toDecimal64(physicalSignificand(d), physicalExponent(d))
  var m = dec.significand
  result = dec.exponent.int
  while m mod 10 == 0: m = m div 10; inc result
  var tmp: array[20, char]
  var n = 0
  while m > 0: tmp[n] = char(ord('0') + int(m mod 10)); m = m div 10; inc n
  ds.len = n
  for k in 0 ..< n: ds.d[k] = tmp[n - 1 - k]

proc incDigits(ds: var DigitBuf) =
  ## 1299 -> 1300, 99 -> 100
  var i = ds.len - 1
  while i >= 0 and ds.d[i] == '9': ds.d[i] = '0'; dec i
  if i < 0:
    for k in countdown(ds.len, 1): ds.d[k] = ds.d[k - 1]
    ds.d[0] = '1'; inc ds.len
  else: ds.d[i] = char(ord(ds.d[i]) + 1)

proc fixed*(x: float, digits: int): string =
  ## `f"{x:.{digits}f}"`
  if x == 0 or x.isNaN or abs(x) == Inf or digits >= pow10tab.len or abs(x) * pow10tab[digits] >= 4.0e15:
    return cfmt("%." & $digits & "f", x)
  var ds: DigitBuf
  let e = shortest(x, ds)
  # make ds = round(|x| * 10^digits)
  if -e <= digits:
    for k in 0 ..< digits + e: ds.d[ds.len + k] = '0'
    ds.len += digits + e
  else:
    let k = -e - digits            # digits to drop
    if k > ds.len: ds.len = 0
    else:
      let first = ds.d[ds.len - k]
      if k == 1 and first == '5': return cfmt("%." & $digits & "f", x)
      ds.len -= k
      if first >= '5': incDigits(ds)
  if ds.len <= digits:             # pad to "0.xx"
    let pad = digits + 1 - ds.len
    for k in countdown(ds.len - 1, 0): ds.d[k + pad] = ds.d[k]
    for k in 0 ..< pad: ds.d[k] = '0'
    ds.len += pad
  let neg = x < 0
  result = newString(ds.len + ord(neg) + ord(digits > 0))
  var at = 0
  if neg: result[0] = '-'; at = 1
  for k in 0 ..< ds.len - digits: result[at] = ds.d[k]; inc at
  if digits > 0:
    result[at] = '.'; inc at
    for k in ds.len - digits ..< ds.len: result[at] = ds.d[k]; inc at

proc sci*(x: float, digits: int): string =
  ## `f"{x:.{digits}e}"`
  if x == 0 or x.isNaN or abs(x) == Inf or digits > 14:
    return cfmt("%." & $digits & "e", x)
  var ds: DigitBuf
  let e = shortest(x, ds)
  var exp = ds.len - 1 + e
  if ds.len <= digits + 1:
    for k in ds.len .. digits: ds.d[k] = '0'
    ds.len = digits + 1
  else:
    let first = ds.d[digits + 1]
    if ds.len == digits + 2 and first == '5': return cfmt("%." & $digits & "e", x)
    ds.len = digits + 1
    if first >= '5':
      incDigits(ds)
      if ds.len > digits + 1: ds.len = digits + 1; inc exp
  result = newStringOfCap(digits + 8)
  if x < 0: result.add '-'
  result.add ds.d[0]
  if digits > 0:
    result.add '.'
    for k in 1 .. digits: result.add ds.d[k]
  result.add(if exp < 0: "e-" else: "e+")
  if abs(exp) < 10: result.add '0'
  result.add $abs(exp)

proc pyRound*(x: float): float =
  ## `round(x)`: to the nearest integer, ties to even.
  let r = round(x)
  if abs(x - trunc(x)) == 0.5: 2.0 * round(x / 2.0) else: r

proc pyRound*(x: float, digits: int): float =
  ## `round(x, digits)`: correctly rounded, as CPython's.
  parseFloat(fixed(x, digits))

proc pyRepr*(x: float): string =
  ## `repr(x)`: the shortest digits that read back as `x`; scientific
  ## notation below 1e-4 and from 1e16 on.
  if x.isNaN: return "nan"
  if x == Inf: return "inf"
  if x == -Inf: return "-inf"
  if x == 0: return (if signbit(x): "-0.0" else: "0.0")
  var ds: DigitBuf
  let e = shortest(x, ds)
  let exp = ds.len - 1 + e
  result = newStringOfCap(ds.len + 24)
  if x < 0: result.add '-'
  template digits(a, b: int) =
    for k in a ..< b: result.add ds.d[k]
  if exp < -4 or exp >= 16:
    result.add ds.d[0]
    if ds.len > 1: result.add '.'; digits(1, ds.len)
    result.add(if exp < 0: "e-" else: "e+")
    if abs(exp) < 10: result.add '0'
    result.add $abs(exp)
  elif e >= 0:
    digits(0, ds.len)
    for k in 0 ..< e: result.add '0'
    result.add ".0"
  elif exp >= 0:
    digits(0, exp + 1); result.add '.'; digits(exp + 1, ds.len)
  else:
    result.add "0."
    for k in 0 ..< -exp - 1: result.add '0'
    digits(0, ds.len)

proc groupThousands*(s: string): string =
  ## "1234567.25" -> "1,234,567.25" (the integer part only; leaves "1e+16" alone).
  var start = 0
  while start < s.len and s[start] in {'-', '+', ' '}: inc start
  var stop = start
  while stop < s.len and s[stop] in {'0' .. '9'}: inc stop
  let n = stop - start
  if n <= 3: return s
  result = newString(s.len + (n - 1) div 3)
  var at = 0
  for k in 0 ..< start: result[at] = s[k]; inc at
  for k in 0 ..< n:
    if k > 0 and (n - k) mod 3 == 0: result[at] = ','; inc at
    result[at] = s[start + k]; inc at
  for k in stop ..< s.len: result[at] = s[k]; inc at

proc intStr*(x: float): string =
  ## `str(int(x))` for a whole float of any size (never "-0").
  if abs(x) < 9.0e15: $int64(x) else: fixed(x, 0)

# ---------------------------------------------------------------- %-formats

type PyFormat* = object
  ## A Python %-format with one conversion, like "%.1f" or "%0.2f days".
  pre*, post*: string
  plain: int       # >= 0: the precision of a plain "%.Nf" or "%.Ne" (no width or flags)
  spec: string     # C conversion spec without its letter: "%0.2"
  conv: char       # d i f F e E g G

proc parsePyFormat*(s: string): PyFormat =
  var i = 0
  var found = false
  proc literal(r: var string, s: string, i: var int) =
    if s[i] == '%' and i + 1 < s.len and s[i + 1] == '%': r.add '%'; i += 2
    else: r.add s[i]; inc i
  while i < s.len:
    if s[i] == '%' and not (i + 1 < s.len and s[i + 1] == '%'):
      if found: raise newException(ValueError, "format must have one conversion, got '" & s & "'")
      found = true
      var j = i + 1
      while j < s.len and s[j] in {'-', '+', ' ', '#', '0'}: inc j
      while j < s.len and s[j] in Digits: inc j
      if j < s.len and s[j] == '.':
        inc j
        while j < s.len and s[j] in Digits: inc j
      if j >= s.len or s[j] notin {'d', 'i', 'f', 'F', 'e', 'E', 'g', 'G'}:
        raise newException(ValueError, "unsupported format '" & s &
                           "' (one of %d, %i, %f, %e, %g with flags, width and precision)")
      result.spec = s[i ..< j]
      result.conv = s[j]
      result.plain = -1
      let sp = result.spec.replace("%0.", "%.")
      if sp.len >= 3 and sp.startsWith("%.") and sp[2 .. ^1].allCharsInSet(Digits) and s[j] in {'f', 'e'}:
        result.plain = parseInt(sp[2 .. ^1])
      elif sp == "%" and s[j] in {'f', 'e'}:
        result.plain = 6
      i = j + 1
    elif found: literal(result.post, s, i)
    else: literal(result.pre, s, i)
  if not found: raise newException(ValueError, "format has no conversion: '" & s & "'")

proc isInteger*(f: PyFormat): bool = f.conv in {'d', 'i'}

proc `%`*(f: PyFormat, x: float): string =
  ## `fmt % x` for a float `x` (finite).
  result = f.pre
  if f.conv in {'d', 'i'}:
    let t = trunc(x)
    if abs(t) < 9.0e18: result.add cfmt(f.spec & "lld", clonglong(t))
    else: result.add cfmt(f.spec.split('.')[0] & ".0f", t)
  elif f.plain >= 0 and f.conv == 'f': result.add fixed(x, f.plain)
  elif f.plain >= 0 and f.conv == 'e': result.add sci(x, f.plain)
  else:
    result.add cfmt(f.spec & $f.conv, x)
  result.add f.post

proc readBack*(f: PyFormat, s: string): float =
  ## The number in `s`, a result of `f % x`.
  if f.pre.len == 0 and f.post.len == 0 and s.len > 0 and s[0] != ' ': parseFloat(s)
  else: parseFloat(s[f.pre.len ..< s.len - f.post.len].strip)

proc roundByFormat*(f: PyFormat, x: float): float =
  ## humanize's `_rounding_by_fmt`: the number `fmt % x` reads back as.
  f.readBack(f % x)
