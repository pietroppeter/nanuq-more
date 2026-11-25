## "humanize, vectorized": a nimib page on nanuq-more's humanize plugin, Python's
## `humanize` as a Polars plugin written in Nim.
##
## Render (from the repo root, with the nanuq repo next to this one):
##   NANUQ_MORE_PYTHON=<a python with polars, humanize and nanuq_more> \
##   nim r -d:release --path:../nanuq/src --path:../nanuq/docs --path:src --path:docs docs/humanize.nim

import nimib
import std/[json, math, os, osproc, strutils, strformat, xmltree]
import nanuqtheme
import nanuq
import polarsplugin
import nanuqmore/humanize_plugin
import blocks

nbInit
nb.title = "humanize, vectorized"
nb.doc.filename = "humanize.html"
nb.useNanuqTheme(
  titleHtml = "<em>humanize</em>, vectorized",
  eyebrow = "nanuq-more · 25 November 2026 · exploration",
  epigraph = "Idea 1: vectorize humanize as a polars plugin. " &
             "(A slide at Compute! Paris 2026, by Arthur Andres.)",
  meta = "exploration report · Nanuq 0.6.1, Polars 2.1.0, Nim " & NimVersion &
         " · rendered with nimib",
  summary = "Python's humanize library (naturalsize, intword, naturaldelta and ten more) as a " &
            "Polars plugin written in Nim: the same text as humanize on whole columns, from " &
            "Python Polars and from Nanuq, checked value by value, and how fast it is.",
  tableOfContents = true)

let repo = currentSourcePath.parentDir.parentDir
let python = getEnv("NANUQ_MORE_PYTHON", repo / ".venv/bin/python")

proc runPython(code: string): string =
  let file = getTempDir() / "nanuq_more_humanize.py"
  writeFile(file, "import polars as pl\npl.Config(tbl_rows=12, tbl_cols=10, tbl_width_chars=80, " &
                  "fmt_str_lengths=40)\n" & code)
  let (output, exitCode) = execCmdEx(python & " -I " & quoteShell(file))
  doAssert exitCode == 0, "python cell failed:\n" & code & "\n" & output
  output.strip(leading = false)

proc tabsHtml(nimSide, pySide: string): string =
  "<div class=\"nq-tabs\"><div class=\"nq-tablist\" role=\"tablist\">" &
    "<button class=\"nq-tab\" role=\"tab\" data-lang=\"python\" aria-selected=\"true\">🐍 Python</button>" &
    "<button class=\"nq-tab\" role=\"tab\" data-lang=\"nim\" aria-selected=\"false\">👑 Nim</button></div>" &
    "<div class=\"nq-panel\" data-lang=\"python\">" & pySide & "</div>" &
    "<div class=\"nq-panel\" data-lang=\"nim\" hidden>" & nimSide & "</div></div>"

template twin(pyCode: string, body: untyped) =
  ## `pyCode` (run, with its output) next to the same thing in Nim with Nanuq (`body`, run too).
  let first = nb.blocks.len
  nbCode(body)
  var nimSide = ""
  for i in first ..< nb.blocks.len: nimSide.add nb.render(nb.blocks[i])
  nb.blocks.setLen(first)
  let pyCodeStr = pyCode.strip
  nbRawHtml: tabsHtml(nimSide, "<pre><code class=\"language-python hljs\">" & highlightPython(pyCodeStr) &
                      "</code></pre><pre class=\"nb-output\">" & xmltree.escape(runPython(pyCodeStr)) & "</pre>")

nb.doc.context["stylesheet"] = %(nb.doc.context["stylesheet"].getStr & sourceStyle & """
<style>
.nq-tabs { margin: 1.6rem 0; }
.nq-tablist { display: flex; gap: .4rem; }
.nq-tab { font: 600 .95rem/1 var(--mono); letter-spacing: .04em; padding: .55rem 1rem; cursor: pointer;
  border: 1px solid var(--rule); border-bottom: none; border-radius: 6px 6px 0 0;
  background: transparent; color: var(--mute); }
.nq-tab[aria-selected="true"] { background: var(--floe); color: var(--fjord); box-shadow: inset 0 2px 0 var(--fjord); }
.nq-panel > pre:first-child { margin-top: 0; }
.nq-panel > pre:first-child > code { border-top-left-radius: 0; }
table.bench { border-collapse: collapse; font: .85rem/1.4 var(--mono); margin: 1rem 0; width: 100%; display: table; }
table.bench th, table.bench td { padding: .3rem .5rem; border-bottom: 1px solid var(--rule); text-align: right; min-width: 0; }
table.bench th:first-child, table.bench td:first-child { text-align: left; }
.tablewrap { overflow-x: auto; }
</style>
""")

const tabsScript = """
<script>
(function () {
  function choose(lang) {
    document.querySelectorAll(".nq-tabs").forEach(function (t) {
      t.querySelectorAll(".nq-tab").forEach(function (b) {
        b.setAttribute("aria-selected", b.dataset.lang === lang ? "true" : "false"); });
      t.querySelectorAll(".nq-panel").forEach(function (p) { p.hidden = p.dataset.lang !== lang; });
    });
    try { localStorage.setItem("nanuq-lang", lang); } catch (e) {}
  }
  document.addEventListener("click", function (e) {
    var b = e.target.closest && e.target.closest(".nq-tab");
    if (b) choose(b.dataset.lang);
  });
  try { var saved = localStorage.getItem("nanuq-lang"); if (saved) choose(saved); } catch (e) {}
})();
</script>
"""

proc loc(path: string): int =
  ## Lines of code in a file of the repository (no blanks, no comments).
  for line in readFile(repo / path).splitLines:
    let s = line.strip
    if s.len > 0 and not s.startsWith("#"): inc result

# ---------------------------------------------------------------------------

nbText: """
At Compute! Paris 2026, Arthur Andres had a slide with three lines of Python's
[humanize](https://github.com/python-humanize/humanize) on it, the library
that turns `100000` into `'100.0 kB'` and 3700 seconds into `'an hour'`. His
point: today you call it once per value, from Python; as a Polars plugin it
would run on a whole column at once, natively, and plug into everything that
uses Polars. He meant Rust.

[nanuq-more](https://pietroppeter.github.io/nanuq-more/) already writes Polars
plugins in Nim, with no Rust and no Python inside (ISO weeks, all of
polars-stats). So here is the idea, done in Nim: all of humanize that works on
a value (13 functions), with the same arguments and **the same text, character
for character**, from Python Polars and from Nanuq.

## The slide, as a plugin

The slide's three calls, on columns. The Python tab uses the `nanuq_more`
package; the Nim tab is [Nanuq](https://github.com/pietroppeter/nanuq), loading
the very same plugin functions.
"""

twin("""
import datetime as dt
import nanuq_more.humanize as hz

df = pl.DataFrame({"n": [100_000, 1_200_000, 3_700]})
print(df.with_columns(
    size=hz.naturalsize("n"),
    words=hz.intword("n"),
    time=hz.naturaldelta(pl.duration(seconds="n")),
))
"""):
  let df = newDataFrame(series("n", [100_000, 1_200_000, 3_700]))
  echo df.withColumns(
    naturalsize(col"n").alias("size"),
    intword(col"n").alias("words"),
    naturaldelta(col("n").cast(Float64)).alias("time"))

nbText: """
(`intword(3700)` is `'3.7 thousand'`: humanize "works best for numbers over 1
million". In Nim, `naturaldelta` takes a number of seconds as well as a
Duration, as humanize does.)

## All of it

humanize has 14 functions; 13 take a value and give text, and they are all
here, with humanize's keyword arguments. The fourteenth, `natural_list`, joins
a list (`"a, b and c"`), which is not one value per row. In Python they are
functions of `nanuq_more.humanize` and also a `humanize` expression namespace:
"""

twin("""
import nanuq_more.humanize  # registers pl.col(...).humanize

x = pl.DataFrame({"x": [0.3, 1.3, 1234567.25, -2.9999999, 220e-6]})
print(x.with_columns(
    pl.col("x").humanize.intcomma().alias("intcomma"),
    pl.col("x").humanize.fractional().alias("fractional"),
))
print(x.with_columns(
    pl.col("x").humanize.scientific().alias("scientific"),
    pl.col("x").humanize.metric(unit="F").alias("metric"),
))
"""):
  let x = newDataFrame(series("x", [0.3, 1.3, 1234567.25, -2.9999999, 220e-6]))
  echo x.withColumns(
    intcomma(col"x").alias("intcomma"),
    fractional(col"x").alias("fractional"))
  echo x.withColumns(
    scientific(col"x").alias("scientific"),
    metric(col"x", unit = "F").alias("metric"))

nbText: """
| function | example |
|---|---|
| `naturalsize`<br>binary, gnu, format | 3000000 → 3.0 MB |
| `intword`<br>format | 1200000 → 1.2 million |
| `intcomma`<br>ndigits | 1234567.25 → 1,234,567.25 |
| `ordinal`<br>gender | 103 → 103rd |
| `apnumber` | 7 → seven |
| `fractional` | 1.3 → 1 3/10 |
| `scientific`<br>precision | 0.3 → 3.00 x 10⁻¹ |
| `metric`<br>unit, precision | 1500 → 1.50 kV |
| `naturaldelta`<br>months, minimum_unit | 3700 s → an hour |
| `naturaltime`<br>future, months, minimum_unit, when | 3700 s → an hour ago |
| `precisedelta`<br>minimum_unit, suppress, format | 2 d 3633.123 s → 2 days, 1 hour and 33.12 seconds |
| `naturalday`<br>format, today | tomorrow's date → tomorrow |
| `naturaldate`<br>today | a date in 2027 → Jun 01 2027 |

(Under each function, its arguments.)

"""

nbText: """
## Time, between two columns

humanize's time functions count from *now*. Here `when` (for `naturaltime`)
and `today` (for `naturalday`, `naturaldate`) default to now and today as
well, as humanize, but can also be another column: how long after the order
was the parcel delivered, in words.
"""

twin("""
from datetime import datetime
import nanuq_more.humanize as hz

orders = pl.DataFrame({
    "ordered": [datetime(2026, 11, 20, 9, 0), datetime(2026, 11, 3, 18, 30), datetime(2025, 10, 1)],
    "delivered": [datetime(2026, 11, 20, 9, 40), datetime(2026, 11, 7, 12, 0), datetime(2026, 11, 25)],
})
print(orders.with_columns(
    took=hz.naturaldelta(pl.col("delivered") - pl.col("ordered")),
    exactly=hz.precisedelta(pl.col("delivered") - pl.col("ordered"), minimum_unit="hours", format="%0.1f"),
    ordered=hz.naturaltime("ordered", when=pl.col("delivered")),
).select("took", "exactly", "ordered"))
"""):
  let orders = newDataFrame(
      series("ordered", ["2026-11-20 09:00", "2026-11-03 18:30", "2025-10-01 00:00"]),
      series("delivered", ["2026-11-20 09:40", "2026-11-07 12:00", "2026-11-25 00:00"]))
    .withColumns(col("ordered").str.toDatetime("%Y-%m-%d %H:%M"),
                 col("delivered").str.toDatetime("%Y-%m-%d %H:%M"))
  let took = col("delivered") - col("ordered")
  echo orders.select(
    naturaldelta(took).alias("took"),
    precisedelta(took, minimumUnit = "hours", format = "%0.1f").alias("exactly"),
    naturaltime(col"ordered", now = col"delivered").alias("ordered"))

nbText: &"""
## The same text as humanize

The point of using humanize is its exact wording, so the plugin is checked
against the Python library value by value (`tests/check_humanize.py`, in CI):
every function, with each of its options, on round and random numbers of every
size from 10⁻³⁵ to 10⁴⁰, ties like 0.15 and 999 950, NaN and infinities,
durations from a microsecond to centuries, every day for two years around
today. Where humanize raises an error the plugin must give null. The last run:
**{readFile(repo / "benchmarks/results/humanize_check.txt").strip.splitLines[^1]}**.

What makes this harder than it looks is that humanize leans on Python's number
formatting: `"%.1f" % x`, `round(x, 2)`, `repr(x)`, `f"{{x:,}}"`. Python rounds
the *exact* binary value of a float (0.15 is really 0.1499999999999999944…, so
`"%.1f" % 0.15` is `'0.1'`), and Python's `repr` gives the shortest digits that
read back as the same float. `pyformat.nim` matches both:

- C's `snprintf` rounds the exact value too, so it gives Python's digits. But
  it is slow (about 200 ns for `"%.1f"`), as it does big-number arithmetic.
- Nim's standard library has dragonbox, which gives the shortest round-trip
  digits in a few tens of nanoseconds (that is `repr`). Rounding those digits
  gives the same answer as rounding the exact value, as long as the float's
  spacing is finer than the rounding step, and unless the digits land exactly
  on the halfway point (then the exact value decides, and `snprintf` is asked).
  Checked against `snprintf` on six million random cases before trusting it.

`fractional` needs `Fraction(x).limit_denominator(1000)`, which Python does
with exact big integers; the plugin does the same continued fraction with
128-bit integers, enough for every double (below 2⁻⁴⁷ the answer is 0 anyway).

The check also found two oddities in humanize 4.17, which the plugin
reproduces (same text is the contract):

- `precisedelta(…, minimum_unit="years")` forgets to stop at years: 30 seconds
  is `'0 years and 30000000 microseconds'`. A `continue` in its loop skips the
  `break`.
- `naturalsize(float("inf"))` is `'inf QB'` (and NaN raises).

## Two small additions to polarsplugin

Two things the earlier plugins did not need:

**Options, read once.** humanize's functions take keyword arguments
(`binary=True`, `format="%.3f"`). Python Polars sends them pickled with each
call. A parameter of type `Kw[T]` (with `T` an object) is now built once per
call from them: each field takes the keyword argument of its name, and
`prepare` checks it and precomputes (the parsed `%`-format, the set of
suppressed units). The proc itself gets a plain object, so it stays an ordinary
Nim proc, and the Nanuq twin takes the object (Nanuq also gets humanize's
named arguments, `naturalsize(col"n", binary = true)`):
"""

nbSource("""
type SizeOpts* = object
  binary*: bool
  gnu*: bool
  format*: string = "%.1f"
  fmt: PyFormat

proc prepare*(o: var SizeOpts) = o.fmt = parsePyFormat(o.format)

proc naturalsize*(value: Num, opts: Kw[SizeOpts]): Option[string] {.polarsExpr.} =
  ...""")

nbText: """
**Input types of your own.** humanize treats `1000` and `1000.0` differently
(`intcomma` gives `1,000` and `1,000.0`), and its time functions take a number
of seconds, a duration or a datetime. A plugin module can now give a Nim type
its own reader, `readValue(T, arrowFormat, array, i)`, so one parameter takes
several Polars dtypes: `Num` is any integer or float column, keeping which;
`TimeValue` is a number of seconds, a Duration, a Datetime or a Date, in any
time unit.

## How fast

The pitch was speed: a plugin instead of a Python call per value. One million
rows, against humanize through `map_elements` (`benchmarks/bench_humanize.py`,
humanize timed on a tenth of the rows and scaled; both give the same strings):
"""

block:
  let bench = parseJson(readFile(repo / "benchmarks" / "results" / "humanize_1M.json"))
  var rows = ""
  for r in bench["results"]:
    let nim = r["nim"].getFloat
    let py = r["python"].getFloat
    rows.add &"<tr><td>{xmltree.escape(r[\"case\"].getStr)}</td><td>{int(round(nim * 1000))}</td>" &
             &"<td>{int(round(py * 1000))}</td><td>{int(round(py / nim))}x</td></tr>"
  nbRawHtml: "<div class=\"tablewrap\"><table class=\"bench\"><thead><tr><th>1M rows, ms</th><th>Nim</th>" &
    "<th>humanize</th><th>gain</th></tr></thead><tbody>" & rows & "</tbody></table></div>"

nbText: """
From 3 to 25 times faster, so the idea works. It is not the hundredfold you
might hope for, for two reasons. humanize is small and quick: a call costs
about a microsecond, mostly the call itself. And the plugin's time goes
into making text: Python-exact float formatting (100 to 200 ns, even on the
fast path), and a fresh string per row, which the Nim side allocates and then
copies into Polars' string view buffer. The text-free work (choosing the unit,
rounding, the plural) is a few nanoseconds; `naturaldelta`, all integer
arithmetic and short fixed words, is the 25x.

So the homework, for this plugin and for any plugin that returns strings:
write each row's text straight into the output buffer instead of a `string`
per row, and print floats from dragonbox's digits without the detour through a
string.

## Differences from humanize

- **Inputs.** Numbers, Durations, Datetimes and Dates, as columns; no strings
  (humanize's `naturalsize("3000")`) and no Python objects. A value humanize
  would raise an error on gives null; humanize's `str(value)` fallbacks for
  values it cannot read (`intcomma(None)` is `'None'`) are nulls too.
- **`when` and `today`** can be columns, not only one point in time, and
  `naturaltime` of a Date counts from its midnight (humanize gives the date
  back as text). Time zones are not looked at: a zoned Datetime is taken in
  UTC, where humanize converts to local time.
- **English only.** humanize can `activate` a translation; the plugin has
  humanize's default English text (so `ordinal`'s `gender` changes nothing,
  as in English humanize).
- **Formats.** `format` takes the `%`-formats humanize documents (`%d`, `%i`,
  `%f`, `%e`, `%g` with flags, width and precision, and text around); not `%s`
  or `%r`. `naturalday`'s `format` takes the common strftime codes, in the C
  locale (`%a %A %b %B %d %e %j %m %u %w %y %Y %F`, and `%H %M %S %p` give
  midnight).
- **Big numbers** stop at Int64 and Float64: Python's integers are unbounded.
  `intword` of an integer beyond 2⁵³ and of floats beyond 10²² could in
  principle round differently from humanize's exact integer division; the
  check found no case.
- **Not here:** `clamp` (takes a Python format string or callable) and
  `natural_list`.

Against Polars, there is nothing to differ from: Polars has no humanize. Its
nearest relatives are `dt.to_string` and the table display's thousands
separator.
"""

nbText: &"""
## The code

`humanize_plugin.nim` is {loc("src/nanuqmore/humanize_plugin.nim")} lines,
`pyformat.nim` {loc("src/nanuqmore/pyformat.nim")}, and the Python module
`humanize.py` {loc("src/nanuq_more/humanize.py")}. The Python wheel is the same
one as before, with the new functions in its library.
"""

nbRawHtml: tabsScript
nbSourceFiles:
  nbFoldCode "src/nanuqmore/humanize_plugin.nim"
  nbFoldCode "src/nanuqmore/pyformat.nim"
  nbFoldCode "src/nanuq_more/humanize.py"
  nbFoldCode "tests/check_humanize.py"
  nbFoldCode "benchmarks/bench_humanize.py"

nbSave
