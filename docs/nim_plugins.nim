## "Polars plugins, without the Rust": a nimib explainer for nanuq-more.
##
## Render (from the repo root, with the nanuq repo next to this one):
##   NANUQ_MORE_PYTHON=<a python with polars, polars-stats and nanuq_more> \
##   nim r -d:release --path:../nanuq/src --path:../nanuq/docs --path:src docs/nim_plugins.nim
## (a Nanuq checkout at v0.6.1 or later, which has registerPluginFunction)

import nimib
import std/[json, math, os, osproc, strutils, strformat, xmltree, times, monotimes]
import nanuqtheme
import nanuq
import polarsplugin
import nanuqmore/[isoweek_plugin, stats_plugin]

nbInit
nb.title = "Polars plugins, without the Rust"
nb.doc.filename = "nim_plugins.html"
nb.useNanuqTheme(
  titleHtml = "Polars plugins, <em>without</em> the Rust",
  eyebrow = "nanuq-more · 5 November 2026, updated 9 November · exploration",
  epigraph = "Francesco, a friend, likes to extend Polars (in Rust and Python). " &
             "Let's try to convince him to give Nim a try.",
  meta = "exploration report · Nanuq 0.6.1, Polars 2.1.0, Nim " & NimVersion &
         " · rendered with nimib",
  summary = "How Polars expression plugins work, and Francesco's two extensions (ISO weeks " &
            "and all of polars-stats) written in Nim, loaded by Nanuq and by Python Polars, " &
            "and running in this page.",
  tableOfContents = true)

# ---------------------------------------------------------------------------
# Nim and Python side by side. The Python cells run when the page renders, with
# NANUQ_MORE_PYTHON (a Python with polars, polars-stats and nanuq_more installed).

let python = getEnv("NANUQ_MORE_PYTHON", "python3")
let pyPreamble = "import polars as pl\npl.Config(tbl_rows=12, tbl_cols=10, tbl_width_chars=100)\n"

proc runPython(code: string): string =
  let file = getTempDir() / "nanuq_more_cell.py"
  writeFile(file, pyPreamble & code)
  let (output, exitCode) = execCmdEx(python & " -I " & quoteShell(file))
  doAssert exitCode == 0, "python cell failed:\n" & code & "\n" & output
  output.strip(leading = false)

proc pythonCode(code: string): string =
  "<pre><code class=\"language-python\">" & xmltree.escape(code) & "</code></pre>"

proc tabsHtml(nimSide, pySide: string): string =
  "<div class=\"nq-tabs\"><div class=\"nq-tablist\" role=\"tablist\">" &
    "<button class=\"nq-tab\" role=\"tab\" data-lang=\"nim\" aria-selected=\"true\">👑 Nim</button>" &
    "<button class=\"nq-tab\" role=\"tab\" data-lang=\"python\" aria-selected=\"false\">🐍 Python</button></div>" &
    "<div class=\"nq-panel\" data-lang=\"nim\">" & nimSide & "</div>" &
    "<div class=\"nq-panel\" data-lang=\"python\" hidden>" & pySide & "</div></div>"

template twin(pyCode: string, body: untyped) =
  ## The Nim code in `body` (run, with its output) next to `pyCode` (run too).
  let first = nb.blocks.len
  nbCode(body)
  var nimSide = ""
  for i in first ..< nb.blocks.len: nimSide.add nb.render(nb.blocks[i])
  nb.blocks.setLen(first)
  let pyCodeStr = pyCode.strip
  nbRawHtml: tabsHtml(nimSide, pythonCode(pyCodeStr) & "<pre class=\"nb-output\">" &
                      xmltree.escape(runPython(pyCodeStr)) & "</pre>")

nb.doc.context["stylesheet"] = %(nb.doc.context["stylesheet"].getStr & """
<style>
.nq-tabs { margin: 1.6rem 0; }
.nq-tablist { display: flex; gap: .4rem; }
.nq-tab { font: 600 .95rem/1 var(--mono); letter-spacing: .04em; padding: .55rem 1rem; cursor: pointer;
  border: 1px solid var(--rule); border-bottom: none; border-radius: 6px 6px 0 0;
  background: transparent; color: var(--mute); }
.nq-tab[aria-selected="true"] { background: var(--floe); color: var(--fjord); box-shadow: inset 0 2px 0 var(--fjord); }
.nq-panel > pre:first-child { margin-top: 0; }
.nq-panel > pre:first-child > code { border-top-left-radius: 0; }
pre:has(> code.language-python)::before { content: "python"; }
table.bench { border-collapse: collapse; font: .85rem/1.4 var(--mono); margin: 1rem 0; width: 100%; display: table; }
table.bench th, table.bench td { padding: .3rem .5rem; border-bottom: 1px solid var(--rule); text-align: right; min-width: 0; }
table.bench th:first-child, table.bench td:first-child { text-align: left; }
.tablewrap { overflow-x: auto; }
.dw { border: 1px solid var(--rule); border-radius: 8px; padding: .8rem 1rem; margin: 1.4rem 0; }
.dw-param { display: flex; flex-wrap: wrap; align-items: center; gap: .3rem .8rem; font: .9rem/1.4 var(--mono); margin: .35rem 0; }
.dw-param span { min-width: 7.5rem; color: var(--mute); }
.dw-param b { color: var(--ink); font-weight: 600; }
.dw-param input[type=range] { flex: 1; min-width: 9rem; accent-color: var(--fjord); }
.dw-param select, .dw-param input[type=date] { font: inherit; padding: .2rem .4rem; }
#dw-plot { width: 100%; height: auto; display: block; margin-top: .6rem; }
.dw-dens { fill: var(--floe); stroke: var(--fjord); stroke-width: 2; }
.dw-mass { fill: var(--fjord); opacity: .75; }
.dw-cdf { fill: none; stroke: var(--ink); stroke-dasharray: 5 4; stroke-width: 1.5; }
.dw-axis { stroke: var(--rule); }
.dw-tick { font: 14px var(--mono); fill: var(--mute); }
.dw-stats { font: .85rem/1.5 var(--mono); color: var(--mute); margin-top: .4rem; }
</style>
""")

let tabsScript = """
<script>
window.addEventListener("load", function () {
  if (!window.hljs) return;
  var s = document.createElement("script");
  s.src = "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/python.min.js";
  s.onload = function () {
    document.querySelectorAll("code.language-python").forEach(function (el) {
      try { hljs.highlightElement(el); } catch (e) {} });
  };
  document.head.appendChild(s);
});
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

let repo = currentSourcePath.parentDir.parentDir

proc lines(path: string, first, last: int): string =
  readFile(repo / path).splitLines[first - 1 .. last - 1].join("\n")

proc excerpt(path, start: string): string =
  ## The lines of `path` from the first one starting with `start` to the next blank line.
  var keep = false
  var got: seq[string]
  for line in readFile(repo / path).splitLines:
    if line.startsWith(start): keep = true
    if keep:
      if line.strip.len == 0: break
      got.add line
  got.join("\n")

# ---------------------------------------------------------------------------

nbText: """
> **Updates.** Francesco answered, in Rust:
> [round two](#appendix-round-two) (6 November, polars-stats#119) and
> [round three](#appendix-round-three-polars-stats-0-2) (9 November,
> polars-stats 0.2).
"""

nbText: """
Francesco Bruzzesi, a friend, likes to extend Polars, in Rust and in Python.
[polars-stats](https://github.com/FBruzzesi/polars-stats), in Rust, adds
**vectorized probability distributions**: `Normal(mu="mu", sigma="sigma").sf("x")`
scores every row against its own distribution, inside a lazy query, without
leaving Polars (he is presenting it at Compute Paris).
[iso-week-date](https://github.com/FBruzzesi/iso-week-date), in Python, handles
**ISO weeks** (`2026-W45`, the week numbering that calendars, retail and payroll
live by).

Let's try to convince him to give Nim a try. Gently: Rust and Python serve him
well, and the last sections are honest about why he might stay. The plan is to
write both extensions in Nim, as Polars plugins that work from Nanuq (Polars for
Nim) *and* from Python Polars, compare them with his, and see what Nim brings
and what it costs. The code lives in [nanuq-more](https://github.com/pietroppeter/nanuq-more).
"""

nbText: """
## How a Polars plugin works

Polars calls them **expression plugins**. On the Python side, a plugin is one call:

```python
from polars.plugins import register_plugin_function

register_plugin_function(
    plugin_path="path/to/the/library.so",
    function_name="normal_cdf",
    args=[pl.col("x"), pl.col("mu"), pl.col("sigma")],
    is_elementwise=True,
)
```

That gives an ordinary `pl.Expr`: it composes, it is lazy, it runs on Polars'
threads, and `is_elementwise` tells the optimizer it may split the column into
batches. On the Rust side, the [pyo3-polars](https://github.com/pola-rs/pyo3-polars)
crate gives a `#[polars_expr]` attribute: polars-stats is a few hundred
functions like this one.

```rust
#[polars_expr(output_type=Float64)]
fn normal_cdf(inputs: &[Series]) -> PolarsResult<Series> {
    value_keyed(inputs, cdf_value)
}
```

The guide and [Marco Gorelli's tutorial](https://marcogorelli.github.io/polars-plugins-tutorial/)
stop there, but the interesting part is underneath. Reading `polars-ffi` and
the loader in `polars-plan` (`plugin.rs`), the boundary between Polars and the
plugin is **plain C**. The library has to export:

| symbol | what Polars does with it |
|---|---|
| `_polars_plugin_get_version` | asks the ABI version (0.1 today) |
| `_polars_plugin_field_<name>` | asks the output name and dtype, from the input fields (Arrow schemas) |
| `_polars_plugin_<name>` | calls it with the input columns, gets the output column |
| `_polars_plugin_get_last_error_message` | reads why a call failed |

A column crosses as a small struct, `SeriesExport`: a pointer to an Arrow
schema, an array of pointers to Arrow arrays (one per chunk), and a release
callback. Those are the [Arrow C data interface](https://arrow.apache.org/docs/format/CDataInterface.html)
structs, the lingua franca of dataframe libraries. Keyword arguments arrive as a
pickled Python dict.

Nothing there is Rust. The `#[polars_expr]` macro is a convenience on top: it
turns the Arrow arrays back into Polars `Series` (which is why a Rust plugin
compiles its *own copy of Polars* into the library), calls your function, and
exports the result. Any language that can export C functions can be a Polars
plugin. Nim can.
"""

nbText: """
## A plugin in Nim

`polarsplugin` is about 900 lines of Nim: the Arrow structs, the version and
error functions, a reader for the input columns (zero-copy when the type
already matches), a writer for the output, a pickle reader for keyword
arguments, and one macro. The macro is the part you see. You write a scalar
proc, one row at a time:
"""
nbCode:
  proc normalCdfDemo(x, mu, sigma: float): float {.polarsExpr.} =
    0.5 * erfc((mu - x) / (sigma * sqrt(2.0)))

nbText: """
and `{.polarsExpr.}` reads its signature and writes the plugin: the two exported
C functions (kernel and field), the loop over the rows, null handling (a null in
any input gives a null), broadcasting (a literal is a length-1 column), the
output dtype from the return type, and an error message if the proc raises.
`Option[T]` as the return type makes `none` a null. The proc itself stays an
ordinary Nim proc that you can call and test:
"""
nbCode:
  echo normalCdfDemo(1.96, 0.0, 1.0)

nbText: """
In Rust, the same job is split between `pyo3-polars`'s macro (the C side) and
the plugin's own drivers: polars-stats has a 470-line `mod.rs` of generic
helpers that align inputs, gate dtypes, propagate nulls and loop over rows,
and each distribution calls into them. In Nim, a macro sees the parameter list and
generates that loop for each function, specialized to its types.
"""

nbText: """
## ISO weeks as a Polars type

Polars 2.1 has (still unstable) **extension types**: a new dtype that is stored
as an existing one and carries a name. A plugin creates one by returning an
Arrow field tagged `ARROW:extension:name`. In Nim that is one overload on a
distinct type:
"""
nbRawHtml: "<pre><code class=\"nohighlight nim hljs\">" &
  highlightNim(lines("src/nanuqmore/isoweek_plugin.nim", 13, 15)) & "</code></pre>"

nbText: """
Storage is `Int32` holding `year * 100 + week` (202645 is 2026-W45). That
choice makes sorting, equality, joins and group-bys work on the storage as is,
and keeps a table readable. The plugin functions are the calendar arithmetic:
the ISO week of a date (the week that contains its Thursday), parsing and
formatting `2026-W45`, adding weeks across year ends (some years have 53
weeks), the Monday a week starts on. Each one is a few lines, for example:
"""
nbRawHtml: "<pre><code class=\"nohighlight nim hljs\">" &
  highlightNim(lines("src/nanuqmore/isoweek_plugin.nim", 75, 77) & "\n\n" &
               lines("src/nanuqmore/isoweek_plugin.nim", 113, 115)) & "</code></pre>"

nbText: """
Here they are at work, around the turn of 2020, a year with a week 53.
Nanuq first, then the same query in Python Polars, loading the same library
(the Python tab is run as the page renders):
"""

twin("""
import datetime as dt
import nanuq_more.isoweek  # registers the type and the .isoweek namespace

days = pl.DataFrame({"day": pl.date_range(dt.date(2020, 12, 26), dt.date(2021, 1, 5), eager=True)})
weeks = days.with_columns(week=pl.col("day").isoweek.from_date())
print(weeks.with_columns(
    label=pl.col("week").isoweek.format(),
    monday=pl.col("week").isoweek.start(),
    in_52=pl.col("week").isoweek.add(52).isoweek.format(),
).group_by("week", "label", "monday", "in_52").agg(days=pl.len()).sort("week"))
"""):
  let days = newDataFrame(series("day", ["2020-12-26", "2021-01-05"]))
    .select(dateRange(col("day").str.toDate().min, col("day").str.toDate().max).alias("day"))
  let weeks = days.withColumns(isoweek(col"day").alias("week"))
  echo weeks.withColumns(
    isoweekFormat(col"week").alias("label"),
    isoweekStart(col"week").alias("monday"),
    isoweekFormat(isoweekAdd(col"week", lit 52)).alias("in_52"),
  ).groupBy("week", "label", "monday", "in_52").agg(len().alias("days")).sort("week")

nbText: """
The dtype column says `ext[...]`: the values are a new Polars type, not an
integer that happens to look like a week. Python shows its registered class
name, `isoweek`; Nanuq shows the extension's full name. A plugin on a plugin's
output also works (`in_52` is `add` then `format`). The functions were checked
against Python's `date.isocalendar()` on every day from 1600 to 2400 (292,560
dates, no differences).

One limit of the unstable extension types today: Polars knows nothing about
the type beyond its storage, so `max` on an `IsoWeek` column refuses to run.
That is where a type plugin would need to grow.

Nim compiles to JavaScript too, and `polarsplugin` makes `{.polarsExpr.}` a
no-op there, so the plugin module runs in this page. Pick a date: the week below
comes from the same `isoweek` and `isoweekStart` procs that Polars calls.
"""
nbRawHtml: """<div class="dw"><label class="dw-param"><span>date</span>
<input type="date" id="iw-date" value="2026-11-05"></label><div id="iw-out" class="dw-stats"></div></div>"""
nbJsFromCode:
  import std/[dom, strutils]
  import ../src/polarsplugin, ../src/nanuqmore/isoweek_plugin
  proc utcDay(ms: float): cstring {.importjs: "new Date(#).toUTCString().slice(0, 16)".}
  proc showWeek() =
    let parts = ($InputElement(document.getElementById("iw-date")).value).split('-')
    if parts.len != 3:
      document.getElementById("iw-out").innerHTML = "pick a date"
      return
    let days = daysFromCivil(parseInt(parts[0]), parseInt(parts[1]), parseInt(parts[2]))
    let w = isoweek(Date32(int32(days)))
    let monday = utcDay(float(int(isoweekStart(w))) * 86400000.0)
    document.getElementById("iw-out").innerHTML = cstring("<b>" & $w & "</b> · week " & $w.week &
      " of " & $weeksInYear(w.year) & " in " & $w.year & " · starts on " & $monday)
  document.getElementById("iw-date").addEventListener("input", proc (e: Event) = showWeek())
  showWeek()


nbText: """
### Against iso-week-date

Francesco's [iso-week-date](https://github.com/FBruzzesi/iso-week-date) package
(pure Python) has Polars helpers too. They are vectorized already: they build
Polars string expressions (`strftime("%G-W%V")`, `strptime`, slices and a
regex), so the work runs in Polars' Rust kernels. Its week arithmetic (`+ 3`
weeks, the distance between weeks) lives in a scalar `IsoWeek` class, so on a
column it goes through `map_elements`, a Python call per row. Same 10 million
dates, best of five (`benchmarks/bench_isoweek.py`); both sides give the same
strings and dates (iwd is iso-week-date):
"""
block:
  let bench = parseJson(readFile(repo / "benchmarks" / "results" / "isoweek_10M.json"))
  var rows = ""
  for r in bench["results"]:
    let nim = r["nim"].getFloat
    let iwd = if r["iwd"].kind == JNull: "–" else: $int(round(r["iwd"].getFloat * 1000))
    let ratio = if r["iwd"].kind == JNull: "" else: formatFloat(r["iwd"].getFloat / nim, ffDecimal, 1) & "x"
    let label = r["case"].getStr.replace("(Nim: the isoweek type, no string)", "type").replace(", map_elements, 100000 rows", " (100k rows)")
    rows.add &"<tr><td>{label}</td><td>{int(round(nim * 1000))}</td><td>{iwd}</td><td>{ratio}</td></tr>"
  nbRawHtml: "<div class=\"tablewrap\"><table class=\"bench\"><thead><tr><th>ms</th><th>Nim</th>" &
    "<th>iwd</th><th>gain</th></tr></thead><tbody>" & rows & "</tbody></table></div>"

nbText: """
So the margin is not in conversions to and from text, where Polars' own
kernels are already good (the Nim plugin is level on formatting, twice as fast
on parsing, and slower on validation, which iso-week-date does with one regex
pass). It is in **having a week type**. Once a column *is* weeks, adding weeks
or counting them is integer arithmetic in one pass, 4 to 7 times faster than
round-tripping through dates and strings, and two orders of magnitude faster
than the scalar class per row. Grouping, sorting and joining on weeks also skip
the strings.

Getting here took two fixes to the first version, both about allocation:
parsing copied each value into a Nim string (now it reads the Arrow bytes in
place), and formatting built a string per row and returned the old
offsets-based layout. Now it writes Arrow *string views*: a string of up to 12
bytes, like `2026-W45`, lives inside its 16-byte view, with no data buffer at
all. Formatting got 2.5x faster, parsing 2.7x.
"""

nbText: """
## Probability distributions

The second extension is all of polars-stats: the same 14 distributions (normal,
log-normal, exponential, uniform, gamma, beta, Cauchy, Pareto, Weibull;
Bernoulli, binomial, Poisson, geometric, discrete uniform), the same parameters,
and the same 15 methods for each: the pdf (or pmf) and its log, `cdf`, `sf` and
their logs, `ppf`, `isf`, `mean`, `variance`, `std`, `median`, `entropy`,
`sample` and `samples`. That is 210 plugin functions. Each distribution is one
block that says only what is particular to it. The gamma distribution:
"""
nbRawHtml: "<pre><code class=\"nohighlight nim hljs\">" &
  highlightNim(excerpt("src/nanuqmore/stats_plugin.nim", "continuous gamma")) & "</code></pre>"

nbText: """
The `continuous` and `discrete` macros (about 180 lines) write the rest. A
method the block does not give is derived: `pdf` from `logPdf`, `sf` as
`1 - cdf`, the logs (through `ln1p` of the complement near 1, where
`ln(1 - tiny)` would round to 0), `median` as `ppf(0.5)`, `ppf` and `isf` by
solving `cdf(x) = q` (a safeguarded secant on a bracket grown from the mean, or
a search over the integers for a discrete distribution), `sample` by inversion,
and `samples(size)` as `size` consecutive draws of the row's random stream, so
that `samples(1)` equals `sample`, as in polars-stats. Every method also gets
the parameter checks (`Positive`, `Probability`, `Count`, plus the block's own
`check` if it has one), NaN in and NaN out, a null for a quantile outside [0, 1],
and then `{.polarsExpr.}`. The gamma block gives no `ppf`, so its quantiles are
solved; a closed form, where there is one, is faster and more exact, so the
other blocks give theirs.

polars-stats spends about 6,300 lines of Rust on the same API, on top of the
statrs crate. The Nim version is about 780 lines, special functions included.
That is not all metaprogramming: polars-stats is more careful in places
(dedicated tail formulas, constant parameters checked once, many more tests),
and it has documentation. But the shape of the code is the point: one
distribution, one short block.
"""

nbText: """
The polars-stats README opens with anomaly scoring, where each reading has its
own baseline. Here it is in both languages, with a sample drawn as well:
"""

twin("""
from nanuq_more.stats import Normal, Poisson

readings = pl.DataFrame({
    "value": [9.8, 101.0, 12.1, 250.0],
    "mu": [10.0, 100.0, 10.0, 100.0],
    "sigma": [0.5, 2.0, 0.5, 2.0],
})
print(readings.with_columns(
    upper_tail=Normal(mu="mu", sigma="sigma").sf("value"),
    arrivals=Poisson(4.0).sample(seed=1),
).filter(pl.col("upper_tail") < 0.01))
"""):
  let readings = newDataFrame(series("value", [9.8, 101.0, 12.1, 250.0]),
                              series("mu", [10.0, 100.0, 10.0, 100.0]),
                              series("sigma", [0.5, 2.0, 0.5, 2.0]))
  echo readings.withColumns(
    normalSf(col"value", col"mu", col"sigma").alias("upper_tail"),
    poissonSample(lit 4.0, seed = 1).alias("arrivals"),
  ).filter(col("upper_tail") < 0.01)

nbText: """
Same numbers, same draws. Sampling is **keyed** like polars-stats: each draw is
a pure function of the seed and a row key (the row index by default), so a
seeded column repeats across runs, chunkings and threads.

How good are the numbers? Every method of every distribution is checked
against scipy.stats on 20,000 random parameter sets: the largest relative
difference is below 1e-10 (most methods below 1e-13), discrete quantiles agree
exactly, and only the binomial log-tails below 1e-280 lose digits (2e-5).
Seeded samples have the right moments and pass Kolmogorov-Smirnov tests. The
checks are in `tests/check_stats.py`, the table in
`benchmarks/results/accuracy_all.txt`.
"""

nbText: """
## The same code, in the browser

Here is the distribution module again, this time compiled by `nim js` while the
page rendered. It is not a JavaScript port: the curve (the pdf or pmf), the line
(the cdf) and the numbers under them come from `gammaPdf`, `gammaPpf`,
`gammaEntropy` and the rest, the procs Polars calls. Only `erfc` and `lgamma`
differ, because JavaScript has no C maths library: a short Lanczos `lgamma`
(1e-15) and a 1e-7 `erfc`, plenty for a plot.
"""
nbRawHtml: """<div class="dw">
<label class="dw-param"><span>distribution</span><select id="dw-dist"></select></label>
<div id="dw-params"></div>
<svg id="dw-plot" viewBox="0 0 480 280" role="img" aria-label="density and cdf"></svg>
<div id="dw-stats" class="dw-stats"></div></div>"""
nbJsFromCode:
  include distwidget

nbText: """
Writing explainers like this one is part of what Nim is good at: the page, its
tables and its widgets are Nim, and they run the real code.
"""

nbText: """
## One file, four uses

Look at the Nim tab above again: `normalSf(col"value", col"mu", col"sigma")`
is Nanuq code, taking and returning `Expr`. Nobody wrote that function. The
plugin module starts with one line, `nanuqBindings()`, and from then on the
same source file is used four ways:

1. **as a library**: `nim c --app:lib stats_plugin.nim` gives the shared library
   that Python Polars loads;
2. **as Nanuq bindings**: imported by a Nanuq program, it compiles *itself* into
   that library at compile time (with `gorgeEx`, cached on the source text), and
   `{.polarsExpr.}` adds an `Expr` twin of every function that calls
   `registerPluginFunction` on it;
3. **as plain Nim**: `normalSf(12.1, 10.0, 0.5)` is still a proc on floats, for
   tests and for scalar code;
4. **as JavaScript**: `nim js` compiles it for the browser, as in the explorer
   above.
"""
nbCode:
  echo "scalar: ", normalSf(12.1, 10.0, 0.5)
  echo "Nanuq:  ", typeof(normalSf(col"x", lit 10.0, lit 0.5))

nbText: """
On the Nanuq side this needed one new function, `registerPluginFunction`, with
the same name and options as Python's. Underneath it is about 40 lines in Nanuq's
Rust bridge, plus two Polars features (`ffi_plugin` and `dtype-extension`). It also
means Nanuq can load *Rust* plugins. polars-stats itself works, with one catch:
pyo3 links its library against Python, so a Nim program can only load it if
libpython is preloaded (`LD_PRELOAD`). Nim plugins have no such dependency.
"""

nbText: """
## Shipping it to Python with uv

Pietro's [`nimlang`](https://pypi.org/project/nimlang/) package ships the Nim
compiler (and `zig cc` as the C compiler) as a Python wheel, with a hatchling hook
that builds Nim files into a wheel. A Polars plugin needs nothing more than that:

```toml
[build-system]
requires = ["hatchling", "nimlang"]
build-backend = "hatchling.build"

[tool.hatch.build.hooks.nimlang]
extensions = ["src/nanuq_more/plugins.nim"]
```

`uv build` gives a `py3-none-manylinux` wheel, for every CPython 3, with no Rust
toolchain and no C compiler installed. Users get it with `uv add` and never see
Nim. Next to it, the Python package is a thin layer (`isoweek.py` registers the
extension type and an expression namespace; `stats.py` has the distribution
classes), the same shape as polars-stats' Python side.

The size difference is striking, because a Nim plugin does not embed Polars:

| | wheel (Linux x86_64) | library |
|---|---|---|
| polars-stats (Rust, main branch, 14 distributions) | 6.8 MB | 25.1 MB |
| nanuq-more 0.0.1 (Nim, the same 14 distributions + ISO weeks) | 0.23 MB | 0.73 MB |

The gap is not about the maths: most of the 25 MB is the copy of Polars that
`pyo3-polars` needs to rebuild `Series` on its side of the boundary. Builds
differ the same way: the Nim library compiles from scratch in seconds; a Rust
plugin starts with compiling Polars, about ten minutes on this 4-core machine.
"""

nbText: """
## Is it fast?

Same machine (4 cores), Python Polars 2.1.0, 10 million rows with column-valued
parameters, best of five, polars-stats built from its main branch, the Nim
plugin built by nimlang with `zig cc` (`benchmarks/bench_stats.py`, run by
hand; the page reads the recorded results):
"""
block:
  let bench = parseJson(readFile(repo / "benchmarks" / "results" / "stats_10M.json"))
  var rows = ""
  for r in bench["results"]:
    let ms = proc (k: string): string =
      if r{k}.isNil or r[k].kind == JNull: "–" else: $int(round(r[k].getFloat * 1000))
    rows.add &"<tr><td>{r[\"case\"].getStr}</td><td>{ms(\"nim\")}</td><td>{ms(\"rust\")}</td>" &
              &"<td>{ms(\"scipy\")}</td><td>{ms(\"native\")}</td></tr>"
  nbRawHtml: "<div class=\"tablewrap\"><table class=\"bench\"><thead><tr><th>ms</th><th>Nim plugin</th>" &
    "<th>polars-stats</th><th>scipy</th><th>Polars exprs</th></tr></thead><tbody>" & rows &
    "</tbody></table></div>"

nbText: """
On par, as hoped, and no more than that. Of the 14 cases the Nim plugin is
faster by more than 10% in seven (the normal quantile function, by Wichura's
AS241 against statrs' inverse erfc; the gamma cdf; the Poisson pmf and its
searched quantiles), within 10% in three, and slower in four:

- the **exponential cdf** and the **scalar-parameter normal cdf**, by 1.2 to
  1.4x: polars-stats checks a constant parameter once, the Nim kernel checks
  it on every row (the macro could hoist that);
- the **gamma quantile function**, 1.7x: the block gives no `ppf`, so it is
  solved by the generic Newton search, where statrs has a tuned one. A
  closed-form starting point in the block would close most of the gap;
- **`samples(8)` of a gamma**, 4x: rand_distr builds a sampler per row and
  reuses its constants for the 8 draws, the Nim block recomputes them for each
  draw. One normal draw per row is level (153 against 158 ms) since the Nim
  sampler moved to a ziggurat.

Two lessons from getting there: a `check(cond, msg)` *proc* built its error
message on every row (ten times slower than Rust until it became a
*template*), and the first random streams hashed the seed and the row key again
for every draw.
"""

nbText: """
## A plugin written on the page

Because building a Nim plugin takes seconds, it can happen while you work.
This page, as it renders, writes a new distribution (Gumbel, for yearly
maxima like floods), compiles it, and uses it, from Nanuq and from Python:
"""
var gumbelLib: string
nbCode:
  let source = getTempDir() / "gumbel.nim"
  writeFile(source, """
import std/math
import polarsplugin

proc gumbelCdf*(x, mu, beta: float): float {.polarsExpr.} =
  exp(-exp(-(x - mu) / beta))
""")
  let start = getMonoTime()
  gumbelLib = compilePlugin(source)
  echo "compiled in ", (getMonoTime() - start).inMilliseconds, " ms"

  let floods = newDataFrame(series("peak", [310.0, 455.0, 620.0]))
  echo floods.withColumns(
    registerPluginFunction(gumbelLib, "gumbelCdf", [col"peak", lit 300.0, lit 80.0],
                           isElementwise = true).alias("p_not_exceeded"))

let pyGumbel = &"""
from polars.plugins import register_plugin_function

floods = pl.DataFrame({{"peak": [310.0, 455.0, 620.0]}})
print(floods.with_columns(p_not_exceeded=register_plugin_function(
    plugin_path="{gumbelLib}", function_name="gumbelCdf",
    args=["peak", pl.lit(300.0), pl.lit(80.0)], is_elementwise=True, use_abs_path=True)))
"""
nbRawHtml: pythonCode(pyGumbel.replace(gumbelLib, "gumbel.so").strip) &
  "<pre class=\"nb-output\">" & xmltree.escape(runPython(pyGumbel)) & "</pre>"

nbText: """
That loop (edit, compile in a couple of seconds, query) is what writing a
plugin can feel like. With nimlang the same works from a Jupyter cell.
"""

nbText: """
## What Nim brings

- **No Polars inside.** A Nim plugin speaks Arrow directly, so it is small
  (a 230 KB wheel), builds in seconds, and does not have to match the Polars
  version it runs in, only the plugin ABI. A Rust plugin compiles a Polars of
  its own, and must be rebuilt for each new Polars.
- **One library for every host.** The same `.so` serves Python Polars and
  Nanuq, and nothing ties it to Python. A pyo3 plugin needs libpython.
- **Metaprogramming.** A scalar proc becomes a vectorized kernel, a C export,
  an output schema and a typed Nanuq function, by one macro; a block of maths
  becomes a distribution with 15 methods, by another. Generic Rust can do much
  of it; a Nim macro works from the code as written.
- **Accessibility.** The code reads like the maths. Someone who knows Python
  can write `proc gumbelCdf(x, mu, beta: float): float` without meeting
  lifetimes, `PolarsResult` or `ChunkedArray`.
- **Interoperability.** One source, many targets and many hosts: a C library
  for Polars, bindings built at compile time for Nanuq, JavaScript for the
  explorers above, a plugin written and loaded while this page rendered. That
  flexibility is what made this exploration quick to iterate on.
- **Interactivity.** With the JavaScript backend, an explainer can run the real
  code in the reader's browser, as this one does.
"""

nbText: """
## Before switching: pitfalls and risks

A fair list, because some of these would stop me too:

- **A small ecosystem.** There is no statrs or rand_distr for Nim, so the
  incomplete gamma and beta functions, the normal quantile, digamma and every
  sampler here are hand-written, and only as trustworthy as
  `tests/check_stats.py`. A new distribution may mean new special functions.
- **No borrow checker at the boundary.** polarsplugin handles Arrow memory by
  hand (malloc, release callbacks, who frees what). Writing it produced a
  double free and a dangling pointer, found by tests and not by the compiler.
  pyo3-polars keeps this away from Rust plugin authors.
- **Macros cut both ways.** Two macros generate 210 functions; a mistake inside
  a block can surface as an error in generated code. And Nim's style
  insensitivity (`fN` and `fn` are the same name) once silently shadowed a
  parameter in the macro.
- **Off the beaten path.** pyo3-polars is maintained with Polars; polarsplugin
  reimplements an ABI that Polars calls version 0 and may change, on top of
  extension types that are unstable. nimlang is young, and the Windows and
  macOS wheels are untested.
- **Fewer hands.** Many more people can review, maintain or contribute to a
  Rust or Python library than to a Nim one. For a library that wants
  contributors, that may matter more than anything above.
- **Too early, not proven.** Nanuq itself started about a week ago, and this
  plugin library a few hours ago. polars-stats has more careful tail formulas,
  constant parameters validated once, many more tests, real documentation and
  users. Nothing here has met production data yet.

So, Francesco: Rust and Python are the safe choice, and polars-stats shows they
work very well. But if a few hundred lines of Nim give the same API, on-par speed, a
wheel thirty times smaller, a plugin Nanuq can load and an explainer that runs
the code, maybe it is worth a try. For plugins that need Polars' own machinery
(casts, aggregations, nested types), Rust stays the natural choice.
"""

nbText: """
## What's next

- **Francesco's verdict.** It arrived as two pull requests and a release:
  see the appendix.
- **Nanuq.** `registerPluginFunction` shipped in
  [Nanuq 0.6.1](https://github.com/pietroppeter/nanuq/blob/main/CHANGELOG.md);
  it also opens Nanuq to Rust plugins.
- **polarsplugin.** Aggregations (not elementwise), list and struct outputs,
  constant parameters checked once, a faster normal sampler, Windows and macOS
  wheels (nimlang can cross-build them from Linux).
- **nanuq-more.** The [repository](https://github.com/pietroppeter/nanuq-more)
  has the plugin library, both extensions, the Python package, the checks and
  the benchmarks; this page is its GitHub Pages site.
"""

nbText: """
## Appendix: round two

A day after reading this page, Francesco answered the way a Rust developer
answers: with a pull request.
[polars-stats#119](https://github.com/FBruzzesi/polars-stats/pull/119),
"make the column-parameter domain check inlinable and vectorised", checks
column-valued parameters in one vectorised pass, with the null slots masked,
before the per-row math. That is the very spot where this page boasted about
Nim templates. Fair enough.

Same benchmark, same machine, with polars-stats from just before (20f64ab)
and just after (3fe324e), in one session
(`benchmarks/results/stats_10M_round2.json`):
"""
block:
  let bench = parseJson(readFile(repo / "benchmarks" / "results" / "stats_10M_round2.json"))
  var rows = ""
  for r in bench["results"]:
    let ms = proc (k: string): string = $int(round(r[k].getFloat * 1000))
    rows.add &"<tr><td>{r[\"case\"].getStr}</td><td>{ms(\"nim\")}</td><td>{ms(\"rust_before\")}</td>" &
              &"<td>{ms(\"rust_after\")}</td></tr>"
  nbRawHtml: "<div class=\"tablewrap\"><table class=\"bench\"><thead><tr><th>ms</th><th>Nim plugin</th>" &
    "<th>polars-stats before</th><th>polars-stats after #119</th></tr></thead><tbody>" & rows &
    "</tbody></table></div>"

nbText: """
The cheap kernels felt it most, as they should: there the check is a large
share of the work. The normal pdf went from 144 to 122 ms and is now level
with Nim (126). Normal sampling went from 151 to 135 ms, a nose ahead of Nim's
ziggurat (140 to 153 ms across runs). The normal quantile went from 256 to
234 ms, still behind AS241. Everything else moved within the noise of the
machine, about 10% between runs.

The new scorecard: the Nim plugin is faster by more than 10% in five cases
(seven before), level in four, slower in five.

The real result is elsewhere, though. This page set out to convince Francesco
to give Nim a try, and it convinced him to make polars-stats faster instead.
Mission accomplished, in reverse. The ball is in Nim's court now: hoisting
constant checks out of the row loop in the macro, a closed-form start for the
gamma quantile, sampler constants reused across draws. Round three, someday.
(Someday came two days later.)
"""

nbText: """
## Appendix: round three, polars-stats 0.2

Two days later polars-stats 0.2.0 was on PyPI. Besides #119 it brings
[#120](https://github.com/FBruzzesi/polars-stats/pull/120): with column
parameters, `pdf`, `cdf`, `ppf` and friends now run through one row loop that
writes every answer into a single buffer and allocates the validity bitmap
only at the first null. Bernoulli even picks its answer without a branch, so
that a column of random 0s and 1s does not trip the branch predictor.
Francesco measured 0.90x on geomean at a million rows, and the most on the
cheapest formulas.

At ten million rows, same benchmark as above (on a slower machine than the
earlier rounds, so compare columns, not tables;
`benchmarks/results/stats_10M_round3.json`):
"""
block:
  let bench = parseJson(readFile(repo / "benchmarks" / "results" / "stats_10M_round3.json"))
  var rows = ""
  for r in bench["results"]:
    let ms = proc (k: string): string = $int(round(r[k].getFloat * 1000))
    rows.add &"<tr><td>{r[\"case\"].getStr}</td><td>{ms(\"nim\")}</td><td>{ms(\"rust_before\")}</td>" &
              &"<td>{ms(\"rust_119\")}</td><td>{ms(\"rust_020\")}</td></tr>"
  nbRawHtml: "<div class=\"tablewrap\"><table class=\"bench\"><thead><tr><th>ms</th><th>Nim plugin</th>" &
    "<th>polars-stats before #119</th><th>after #119</th><th>0.2.0</th></tr></thead><tbody>" & rows &
    "</tbody></table></div>"

nbText: """
Here the new loop hides behind memory traffic: 0.2.0 matches the #119 build
within the noise. The scorecard is still five faster, four level, five
slower, but the normal pdf has crossed to Rust's side (138 ms against Nim's
165), while normal sampling is back to level.

At a million rows, where Francesco measured, it is another story. Cheap
formulas, column parameters, best of 21 calls
(`benchmarks/bench_cheap.py`, `benchmarks/results/cheap_1M_round3.json`):
"""
block:
  let bench = parseJson(readFile(repo / "benchmarks" / "results" / "cheap_1M_round3.json"))
  var rows = ""
  for r in bench["results"]:
    let ms = proc (k: string): string = formatFloat(r[k].getFloat * 1000, ffDecimal, 1)
    rows.add &"<tr><td>{r[\"case\"].getStr}</td><td>{ms(\"nim\")}</td><td>{ms(\"rust_119\")}</td>" &
              &"<td>{ms(\"rust_020\")}</td></tr>"
  nbRawHtml: "<div class=\"tablewrap\"><table class=\"bench\"><thead><tr><th>ms</th><th>Nim plugin</th>" &
    "<th>polars-stats after #119</th><th>0.2.0</th></tr></thead><tbody>" & rows &
    "</tbody></table></div>"

nbText: """
The Bernoulli pmf went from 11.2 to 3.2 ms, the uniform pdf from 5.9 to 3.3,
the normal pdf from 12.2 to 9.3. And the Nim plugin sits at 12 to 14 ms
whatever the formula, uniform or normal alike: that looks like a fixed cost
of about 12 ns a row in polarsplugin's row wrapper (per-row null and
parameter checks, an output builder), which the cheapest formulas cannot
hide. On Bernoulli and uniform, polars-stats now spends about a quarter of
that on the whole row.

Round three goes to Francesco, no contest. On the bright side, Nim's homework
is now a precise list rather than a vague hope: a row loop with no per-row
overhead (a validity bitmap only when there is a null, exactly like #120),
constant checks hoisted out of the loop, then the gamma quantile and the
samplers. The ball is in Nim's court, and it is bouncing rather fast.
"""

nbRawHtml: tabsScript
nbSave
