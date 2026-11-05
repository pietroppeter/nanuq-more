## "Polars plugins, without the Rust": a nimib explainer for nanuq-more.
##
## Render (from the repo root, with the nanuq repo next to this one):
##   NANUQ_MORE_PYTHON=<a python with polars, polars-stats and nanuq_more> \
##   nim r -d:release --path:../nanuq/src --path:../nanuq/docs --path:src \
##     -d:nanuqLibDir=<a Nanuq library with expression plugins> docs/nim_plugins.nim

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
  eyebrow = "nanuq-more · 5 November 2026 · exploration",
  epigraph = "A friend wrote two Polars extensions in Rust. Could Nim write them too, " &
             "and serve both Nanuq and Python Polars?",
  meta = "exploration report · Nanuq 0.6 (+ plugins), Polars 2.1.0, Nim " & NimVersion &
         " · rendered with nimib",
  summary = "How Polars expression plugins work, and two of them (ISO weeks and " &
            "probability distributions) written in Nim, loaded by Nanuq and by Python Polars.",
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

# ---------------------------------------------------------------------------

nbText: """
Francesco Bruzzesi, a friend of this project, extends Polars in Rust. One of his
extensions adds an **ISO week** data type (`2026-W45`, the week numbering that
calendars, retail and payroll live by). Another, [polars-stats](https://github.com/FBruzzesi/polars-stats),
adds **vectorized probability distributions**: `Normal(mu="mu", sigma="sigma").sf("x")`
scores every row against its own distribution, inside a lazy query, without
leaving Polars. He is presenting it at Compute Paris.

Nanuq is Polars for Nim, so the question writes itself: can we write such
extensions in Nim? And since Nim compiles to C, could the very same library also
plug into **Python** Polars, as an alternative to Rust for people who'd rather
not learn Rust?

The short answer is yes, both. This post explains how Polars plugins work, then
builds both extensions in Nim, runs them from Nanuq and from Python, and
compares them with the Rust approach. The code lives in *nanuq-more*.
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

`polarsplugin` is about 600 lines of Nim: the Arrow structs, the version and
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
"""

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

The second extension follows polars-stats: every distribution function takes the
evaluation point and the parameters as columns, so each row can carry its own
distribution. Seven distributions (normal, log-normal, exponential, uniform,
gamma, beta, Poisson) with their pdf, cdf, survival function, quantiles and
sampling come to about 300 lines, special functions included. The normal
survival function:
"""
nbRawHtml: "<pre><code class=\"nohighlight nim hljs\">" &
  highlightNim(lines("src/nanuqmore/stats_plugin.nim", 178, 180)) & "</code></pre>"

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

How good are the numbers? On 200,000 random parameter sets, the largest
relative difference from scipy.stats is 4e-13 for the normal cdf, 3e-11 for
the normal quantile function (deep in the tails), and below 1e-13 everywhere
else. Seeded samples pass Kolmogorov-Smirnov tests against scipy's
distributions. The checks are in `tests/check_stats.py`.
"""

nbText: """
## One file, three uses

Look at the Nim tab above again: `normalSf(col"value", col"mu", col"sigma")`
is Nanuq code, taking and returning `Expr`. Nobody wrote that function. The
plugin module starts with one line, `nanuqBindings()`, and from then on the
same source file is used three ways:

1. **as a library**: `nim c --app:lib stats_plugin.nim` gives the shared library
   that Python Polars loads;
2. **as Nanuq bindings**: imported by a Nanuq program, it compiles *itself* into
   that library at compile time (with `gorgeEx`, cached on the source text), and
   `{.polarsExpr.}` adds an `Expr` twin of every function that calls
   `registerPluginFunction` on it;
3. **as plain Nim**: `normalSf(12.1, 10.0, 0.5)` is still a proc on floats, for
   tests and for scalar code.
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
| polars-stats 0.1.0 (Rust, 14 distributions) | 6.6 MB | 24.5 MB |
| nanuq-more 0.0.1 (Nim, 7 distributions + ISO weeks) | 0.09 MB | 0.22 MB |

polars-stats has twice the distributions, but the gap is not about the maths:
most of its 24 MB is the copy of Polars that `pyo3-polars` needs to rebuild
`Series` on its side of the boundary. Builds differ the same way: the Nim
library compiles from scratch in about 4 seconds; a Rust plugin starts with
compiling Polars, minutes on a laptop.
"""

nbText: """
## Is it fast?

Same machine (4 cores), Python Polars 2.1.0, 10 million rows with column-valued
parameters, best of five, the Nim plugin built by nimlang with `zig cc`
(`benchmarks/bench_stats.py`):
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
On par, as hoped: within 10% of the Rust plugin for most functions, faster for
the normal quantile function (Wichura's AS241 against statrs' inverse erfc)
and for the beta cdf, slower in two places. Sampling is 1.6x slower: Rust
draws normals with a ziggurat, the Nim version inverts the cdf of one uniform
draw. The scalar-parameter cdf is 1.3x slower because polars-stats checks a
constant parameter once, and the Nim kernel checks it on every row; the macro
could hoist that. On the streaming engine, which runs the plugin on all four
cores, the normal cdf takes 74 ms in Nim and 82 ms in Rust: the Nim plugin is
thread-safe as is.

One lesson from getting there: the first run was ten times slower than
Rust. A `check(cond, msg)` *proc* built its error message on every row; making
it a *template* builds the message only when the check fails.
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
## Nim or Rust for a Polars plugin?

**What Nim brings**

- **No Polars inside.** A Nim plugin speaks Arrow directly, so it is small
  (a 90 KB wheel), builds in seconds, and does not have to match the Polars
  version it runs in, only the plugin ABI. A Rust plugin compiles a Polars of
  its own, and must be rebuilt for each new Polars.
- **One library for every host.** The same `.so` serves Python Polars and
  Nanuq, and nothing ties it to Python. A pyo3 plugin needs libpython.
- **Metaprogramming.** A scalar proc becomes a vectorized kernel, a C export,
  an output schema and a typed Nanuq function, by a macro of about 150 lines.
  Generic Rust can do much of it; a Nim macro does it from the signature alone.
- **Accessibility.** The code reads like the maths. A data scientist who knows
  Python can write `proc gumbelCdf(x, mu, beta: float): float` without meeting
  lifetimes, `PolarsResult` or `ChunkedArray`.
- **Interactivity.** Seconds to rebuild, and the same file is a plain Nim module
  you can test with `echo`.

**What Rust has**

- **The Polars API inside the plugin.** Rust plugins work on `Series` and
  `ChunkedArray` and can call Polars' own kernels (casts, aggregations, string
  functions). A Nim plugin gets raw Arrow and does those itself;
  polarsplugin covers numbers, booleans, dates and strings so far, not lists or
  structs.
- **The crate ecosystem.** polars-stats leans on `statrs` and `rand_distr`; the
  Nim version had to write its incomplete gamma and beta functions, the normal
  quantile and the samplers (all short, but each needs testing).
- **The beaten path.** pyo3-polars is maintained with Polars, the ABI is
  documented through it, and maturin builds wheels for every platform. The
  Nim route depends on an ABI that Polars calls version 0, and on extension
  types that are unstable.

So: not faster, but on par; much lighter; open to Nanuq; and a lower entry
step for people who don't write Rust. A good fit for elementwise maths and
types like ISO weeks; for plugins that need Polars' own machinery, Rust stays
the natural choice.
"""

nbText: """
## What's next

- **Francesco's isoweek.** His Rust version is not public yet; once it is, the
  two designs (storage, operations, how the type displays) can be compared, and
  the Nim one aligned.
- **Nanuq.** `registerPluginFunction` is a small, self-contained change to
  Nanuq, a candidate for 0.7 (it also opens Nanuq to Rust plugins).
- **polarsplugin.** Aggregations (not elementwise), list and struct outputs,
  constant parameters checked once, a faster normal sampler, and Windows and
  macOS wheels (nimlang can cross-build them from Linux).
- **nanuq-more.** The prototype lives in the project files until the
  repository exists; it has the plugin library, both extensions, the Python
  package, the checks and the benchmarks.
"""

nbRawHtml: tabsScript
nbSave
