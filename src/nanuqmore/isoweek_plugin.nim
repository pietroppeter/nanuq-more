## ISO 8601 weeks (`2026-W45`) as a Polars extension type, `nanuq.isoweek`.
##
## Storage is Int32 `year * 100 + week` (202645): sorting, equality and
## grouping work on the storage as is, and a table shows readable numbers.
## Every proc here is plain Nim; `polarsExpr` also exports it to Polars.
##
## Build: nim c --app:lib -d:release -d:useMalloc --threads:on isoweek_plugin.nim

import std/[strutils, math]
import ../polarsplugin
nanuqBindings()

type IsoWeek* = distinct int32   ## year * 100 + week

proc arrowExtension*(T: typedesc[IsoWeek]): string = "nanuq.isoweek"
proc `==`*(a, b: IsoWeek): bool {.borrow.}
proc `<`*(a, b: IsoWeek): bool {.borrow.}
proc year*(w: IsoWeek): int = w.int div 100
proc week*(w: IsoWeek): int = w.int mod 100
proc `$`*(w: IsoWeek): string = $w.year & "-W" & align($w.week, 2, '0')

# ------------------------------------------------- calendar arithmetic, on days since 1970-01-01

proc daysFromCivil(y, m, d: int): int =
  ## Howard Hinnant's days_from_civil.
  let y = if m <= 2: y - 1 else: y
  let era = (if y >= 0: y else: y - 399) div 400
  let yoe = y - era * 400
  let doy = (153 * (if m > 2: m - 3 else: m + 9) + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

proc yearOfDays(z: int): int =
  let z = z + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let m = if mp < 10: mp + 3 else: mp - 9
  yoe + era * 400 + (if m <= 2: 1 else: 0)

proc weekday0(days: int): int = floorMod(days + 3, 7)   ## Monday = 0

proc mondayOfWeek1(y: int): int =
  let jan4 = daysFromCivil(y, 1, 4)
  jan4 - weekday0(jan4)

proc weeksInYear*(y: int): int =
  ## 52 or 53: a year has 53 ISO weeks when Dec 28 falls in week 53.
  let dec28 = daysFromCivil(y, 12, 28)
  (dec28 - mondayOfWeek1(y)) div 7 + 1

proc isoweekOfDays(days: int): IsoWeek =
  let thursday = days - weekday0(days) + 3
  let y = yearOfDays(thursday)
  IsoWeek(int32(y * 100 + (thursday - mondayOfWeek1(y)) div 7 + 1))

proc mondayOf(w: IsoWeek): int = mondayOfWeek1(w.year) + 7 * (w.week - 1)

# ------------------------------------------------- the plugin functions

proc isoweek*(d: Date32): IsoWeek {.polarsExpr.} =
  ## The ISO week a date falls in.
  isoweekOfDays(d.int)

proc isoweekParse*(s: StrView): Option[IsoWeek] {.polarsExpr.} =
  ## `2026-W45`, `2026W45` or `2026-W45-3` (the weekday is ignored); null if invalid.
  let s = $s
  var y, w: int
  let dash = s.len >= 8 and s[4] == '-'
  let wi = if dash: 5 else: 4
  if s.len < wi + 3 or s[wi] notin {'W', 'w'}: return none(IsoWeek)
  try:
    y = parseInt(s[0 ..< 4]); w = parseInt(s[wi + 1 .. wi + 2])
  except ValueError: return none(IsoWeek)
  if w < 1 or w > weeksInYear(y): return none(IsoWeek)
  some IsoWeek(int32(y * 100 + w))

proc isoweekFromInt*(x: int32): Option[IsoWeek] {.polarsExpr.} =
  ## Storage (yyyyww) to an IsoWeek; null if the week does not exist.
  let w = IsoWeek(x)
  if w.week < 1 or w.week > weeksInYear(w.year): none(IsoWeek) else: some w

proc isoweekFormat*(w: IsoWeek): string {.polarsExpr.} = $w

proc isoweekStart*(w: IsoWeek): Date32 {.polarsExpr.} =
  ## The Monday the week starts on.
  Date32(int32(mondayOf(w)))

proc isoweekDay*(w: IsoWeek, weekday: int64): Option[Date32] {.polarsExpr.} =
  ## The date of `weekday` (1 = Monday ... 7 = Sunday) in the week.
  if weekday < 1 or weekday > 7: none(Date32) else: some Date32(int32(mondayOf(w) + weekday.int - 1))

proc isoweekAdd*(w: IsoWeek, n: int64): IsoWeek {.polarsExpr.} =
  ## `n` weeks later (earlier when negative), across year ends.
  isoweekOfDays(mondayOf(w) + 7 * n.int)

proc isoweekDiff*(a, b: IsoWeek): int64 {.polarsExpr.} =
  ## Whole weeks from `b` to `a`.
  int64((mondayOf(a) - mondayOf(b)) div 7)

proc isoweekYear*(w: IsoWeek): int32 {.polarsExpr.} = int32(w.year)
proc isoweekNumber*(w: IsoWeek): int8 {.polarsExpr.} = int8(w.week)
