## "Inside the distributions": a nimib deep dive into how nanuq-more's
## probability distributions are built, from a block of maths to a Polars plugin
## function, through the `continuous`/`discrete` macros and `{.polarsExpr.}`.
##
## Render (from the repo root, with the nanuq repo next to this one):
##   NANUQ_MORE_PYTHON=<a python with polars and nanuq_more> \
##   nim r -d:release --path:../nanuq/src --path:../nanuq/docs --path:src --path:docs docs/distributions.nim

import nimib
import std/[os, osproc, strutils, strformat, math, sequtils, json, algorithm, monotimes, times, options]
import nanuqtheme
import nanuq
import polarsplugin
import nanuqmore/stats_plugin
import macroview, blocks

nbInit
nb.title = "Inside the distributions"
nb.doc.filename = "distributions.html"
nb.useNanuqTheme(
  titleHtml = "Inside the <em>distributions</em>",
  eyebrow = "nanuq-more · 19 November 2026 · deep dive",
  epigraph = "Fourteen distributions, fifteen methods each, one short block apiece. " &
             "This is what the macros write for them.",
  meta = "deep dive · Nanuq 0.6.1, Polars 2.1.0, Nim " & NimVersion & " · rendered with nimib",
  summary = "How nanuq-more's probability distributions are implemented: the continuous and " &
            "discrete macros, the polarsExpr macro that turns a Nim proc into a Polars plugin " &
            "function, the Arrow and pickle plumbing, the numerics, the random streams, and the " &
            "Python and Nanuq sides.",
  tableOfContents = true)
nb.doc.context["stylesheet"] = %(nb.doc.context["stylesheet"].getStr & sourceStyle)

let repo = currentSourcePath.parentDir.parentDir


proc loc(path: string): int =
  ## Lines of code in a file of the repository (no blanks, no comments).
  for line in readFile(repo / path).splitLines:
    let s = line.strip
    if s.len > 0 and not s.startsWith("#"): inc result

# Python cells run as the page renders, with NANUQ_MORE_PYTHON (a Python with
# polars and the nanuq_more wheel installed).
let python = getEnv("NANUQ_MORE_PYTHON", repo / ".venv/bin/python")

proc runPython(code: string): string =
  let file = getTempDir() / "nanuq_more_deep_dive.py"
  writeFile(file, "import polars as pl\npl.Config(tbl_rows=12, tbl_cols=10, tbl_width_chars=100)\n" & code)
  let (output, exitCode) = execCmdEx(python & " -I " & quoteShell(file))
  doAssert exitCode == 0, "python cell failed:\n" & code & "\n" & output
  output.strip(leading = false)

template nbPython(code: string) =
  ## A Python cell and what it printed.
  nbSource(code.strip, slPython)
  nbSource(runPython(code), slOutput)

# The expansions shown on the page, made at compile time from the real source.
const
  expoExp = expandedDistribution("src/nanuqmore/stats_plugin.nim", "continuous exponential")
  gammaExp = expandedDistribution("src/nanuqmore/stats_plugin.nim", "continuous gamma")
  poissonExp = expandedDistribution("src/nanuqmore/stats_plugin.nim", "discrete poisson")
  expoCdfExpansion = expandedPolarsExpr(procNamed(expoExp, "exponentialCdf"))
  expoSamplesExpansion = expandedPolarsExpr(procNamed(expoExp, "exponentialSamples"))
  expoPpfExpansion = expandedPolarsExpr(procNamed(expoExp, "exponentialPpf"))

proc chunk(text, start: string): string =
  ## The top-level statement of `text` that starts with `start`.
  blockOf(text & "\n", start)

proc between(text, first, last: string): string =
  ## The lines of `text` from the one containing `first` to the one containing `last`.
  var keep = false
  var got: seq[string]
  for line in text.splitLines:
    if first in line: keep = true
    if keep: got.add line
    if keep and last in line: break
  got.join("\n")

# ---------------------------------------------------------------------------

nbText: """
[Polars plugins, without the Rust](https://pietroppeter.github.io/nanuq-more/)
showed that a Polars expression plugin is plain C underneath, and that Nim can
write one: nanuq-more has ISO weeks and all of polars-stats, loaded by Python
Polars and by Nanuq. That page stays on the outside. This one opens the
distributions up: what each file does, what the two layers of macros write
(shown as the compiler sees it, expanded from the real source while this page
rendered), how the numbers are computed, and how Python and Nanuq end up
calling the same machine code.
"""

nbText: &"""
The code is in four layers. Each one only knows the layer below it:

| layer | file | lines | job |
|---|---|---|---|
| distributions | `stats_plugin.nim` | {loc("src/nanuqmore/stats_plugin.nim")} | one block of maths per distribution, plus the samplers |
| distribution macros | `distmacro.nim` | {loc("src/nanuqmore/distmacro.nim")} | `continuous` and `discrete`: derive the missing methods, add the checks |
| special functions | `specfun.nim` | {loc("src/nanuqmore/specfun.nim")} | `ndtri`, incomplete gamma and beta, root finders |
| plugin macro | `polarsplugin/native.nim` | {loc("src/polarsplugin/native.nim")} | `{{.polarsExpr.}}`: a Nim proc becomes a Polars plugin function |
| Arrow, pickle | `arrow.nim`, `pickle.nim` | {loc("src/polarsplugin/arrow.nim") + loc("src/polarsplugin/pickle.nim")} | the C structs Polars passes, the keyword arguments |
| random streams | `rowrng.nim` | {loc("src/polarsplugin/rowrng.nim")} | a random stream per row, the ziggurat |
| Python | `stats.py`, `_lib.py` | {loc("src/nanuq_more/stats.py") + loc("src/nanuq_more/_lib.py")} | the polars-stats classes, over `register_plugin_function` |

(Lines without blanks and comments.)
"""

nbText: """
## One function, end to end

Take the exponential distribution. Its whole definition is this block:
"""
nbSource(sourceBlock("src/nanuqmore/stats_plugin.nim", "continuous exponential"))
nbText: """

From it come 15 functions (`exponentialPdf`, `exponentialCdf`, ...,
`exponentialSamples`). Follow one of them, `exponentialCdf`, through four steps:

1. **`continuous`** reads the block and writes Nim code: a private
   `exponentialCdfRaw` holding the maths, and a public `exponentialCdf` that
   checks the parameter and handles NaN, marked `{.polarsExpr.}`.
2. **`{.polarsExpr.}`** reads that public proc's signature and writes two C
   functions, `_polars_plugin_exponentialCdf` (the loop over the rows) and
   `_polars_plugin_field_exponentialCdf` (the output type), plus, in a Nanuq
   program, an `exponentialCdf(x, rate: Expr): Expr` twin.
3. **The compiler** builds the module as a shared library; the two C
   functions are exported symbols.
4. **Polars** (Python's or Nanuq's) loads the library, asks the field
   function for the output type while planning the query, then calls the
   kernel with Arrow arrays when the query runs.

The proc stays an ordinary Nim proc on floats, so step 0 is calling it:
"""

nbCode:
  echo exponentialCdf(1.0, rate = 2.0)
  echo exponentialPpf(0.5, rate = 2.0)   # an Option: none for a quantile outside [0, 1]
  echo exponentialPpf(1.5, rate = 2.0)

nbText: """
The sections below go through those steps in order, then the numerics, the
random numbers, and the Python and Nanuq sides.
"""

# ---------------------------------------------------------------------------

nbText: """
## The distribution macros

`continuous` and `discrete` share one implementation, `distributionImpl`. It
works in four moves.

**1. A fixed list of methods.** Every distribution has the same 16 methods,
each with a fixed signature; the distribution's parameters are appended to
every one. For the exponential (one parameter, `rate`) the macro starts by
declaring them all, so that the methods can call each other in any order:
"""
nbSource(forwardDecls(expoExp))
nbText: """
`Check` (extra parameter rules) and `Support` (the interval the variable lives
on) are helpers; the other 14 become plugin functions, plus `Samples`, made
from `Sample`. The `Raw` suffix marks the maths without checks: those procs
are not exported.

**2. The block's own methods, with short names in scope.** Each method the
block gives becomes the body of its `Raw` proc. To let the bodies say `cdf(x)`
or `mean()` instead of `exponentialCdfRaw(x, rate)`, every `Raw` proc opens
with a local template per method, which passes the parameters along. Here is
the median, with the templates written out (the last one, `guess0`, comes
up again below); its own body is the last line:
"""
nbSource(procNamed(expoExp, "exponentialMedianRaw"))
nbText: """
and here are two more, with the same 16 templates folded into a comment:
"""
nbSource(withoutTemplates(procNamed(expoExp, "exponentialCdfRaw")) & "\n\n" &
                   withoutTemplates(procNamed(expoExp, "exponentialSampleRaw")))
nbText: """
The templates are inlined where they are used and the `Raw` procs are
`{.inline.}`, so all this costs nothing at run time. The parameters keep their
names: in the uniform block, `min` and `max` are parameters, which is why the
generated helpers write `system.clamp` and `system.max` when they mean the
standard ones.
"""

nbText: """
**3. Defaults for the methods the block leaves out.** This is where most of the
saving comes from. The block must give `mean`, `variance` and `entropy` (the
macro stops with an error otherwise) and enough of the rest for these rules:

| missing | derived as |
|---|---|
| `support` | `(-Inf, Inf)`, or `(0, Inf)` for a discrete distribution |
| `pdf` (`pmf`) | `exp(logPdf(x))` |
| `logPdf` | `ln(pdf(x))` |
| `cdf` / `sf` | `1 - sf(x)` / `1 - cdf(x)` |
| `logCdf` / `logSf` | `ln(cdf(x))`, or `ln1p(-sf(x))` when `cdf(x) > 0.5`, which keeps the digits that `ln(1 - tiny)` loses |
| `ppf` / `isf` | solve `cdf(x) = q` (or `sf(x) = q`): Newton steps inside a bracket for a continuous distribution, a search over the integers for a discrete one |
| `sample` | inversion: `ppf(rng.uniform)` |
| `median` | `ppf(0.5)` |
| `std` | `sqrt(variance())` |

So the gamma block, which gives `logPdf`, `cdf`, `sf`, `sample` and the
moments, gets `pdf`, `logCdf`, `logSf`, `ppf`, `isf`, `median` and `std`
derived. Its quantile function, as generated:
"""
nbSource(withoutTemplates(procNamed(gammaExp, "gammaPpfRaw")))
nbText: """
`guess0` is the 16th template: a starting point for the solver, the normal
approximation `mean + sd * ndtri(q)` clamped to the support (or a point inside
the support when the mean or the variance is infinite, as for a Cauchy or a
heavy Pareto):
"""
nbSource("template guess0(q: float): float {.used.} =\n" &
                   between(procNamed(gammaExp, "gammaPpfRaw"), "    block:", "system.clamp"))
nbText: """
For a discrete distribution the same rule uses `searchInteger` instead. The
Poisson block gives no `ppf`:
"""
nbSource(withoutTemplates(procNamed(poissonExp, "poissonPpfRaw")))
nbText: """
The `4e-16` relaxes the test by a couple of rounding errors, so that a
quantile equal to a cdf value up to rounding still picks that integer.

Nothing checks that the rules end somewhere: a block with neither `pdf` nor
`logPdf`, or neither `cdf` nor `sf`, compiles to two procs that call each other
forever. All 14 blocks give one of each, but a fifteenth has to know.
"""

nbText: """
**4. The public functions.** For each method, one exported proc that checks
the parameters, applies the NaN and domain rules, and calls the `Raw` proc.
Parameter kinds come from the block's head (`rate: Positive`):
`Finite`, `Positive`, `Probability`, `Count` and `Integer`, each a type alias
with a `check` proc, plus the block's own `check` if it has one. These are
what `{.polarsExpr.}` turns into plugin functions:
"""
nbSource(procNamed(expoExp, "exponentialCdf") & "\n\n" &
                   procNamed(expoExp, "exponentialPpf") & "\n\n" &
                   procNamed(expoExp, "exponentialSamples"))
nbText: """
NaN in gives NaN out; a quantile outside [0, 1] gives `none`, which becomes a
null (polars-stats does the same); `samples(size)` is `size` consecutive draws
of the row's random stream, so `samples(1)` equals `sample`. A bad parameter
raises `ValueError`, which reaches the user as a Polars `ComputeError` (shown
in the Python section below). The checks are a template, `require`, so the
error message is only built when a check fails; as a proc it built the string
on every row and made the whole function 10 times slower.

The macro writes all of this as *text*: it assembles Nim source in strings and
parses it with `parseStmt` (with `-d:distDebug` it prints that text). Only the
block's own method bodies are spliced in as syntax trees, so an error inside
them still points at `stats_plugin.nim`. Strings made the macro short and easy
to read next to its output; the cost is that a mistake in the generated part
shows up as an error in code nobody can open. In the end, each distribution
expands to about this much code (most of it the 16 templates, repeated in
every method), before `{.polarsExpr.}` adds its part:
"""

nbCode:
  for (name, code) in [("exponential", expoExp), ("gamma", gammaExp), ("poisson", poissonExp)]:
    echo &"{name:<12} {code.countLines:>5} lines, {publicProcs(code).len} plugin functions"

# ---------------------------------------------------------------------------

nbText: """
## The `{.polarsExpr.}` macro

`polarsExpr` is a pragma macro: written on a proc, it receives the proc's
syntax tree and returns code that replaces it. It returns the proc itself,
untouched, followed by three new definitions. It reads two things from the
signature.

**The return type** decides the output column: `T` gives a column of `T`;
`Option[T]` makes `none` a null; `seq[E]` (with a `Size` parameter) gives a
Polars `Array(E, size)`. The Arrow type comes from `arrowFormat`: `float` is
`g` (Float64), `int64` is `l`, `uint64` is `L`, `bool` is `b`, `string` is
`vu` (a string view), and a distinct type such as the ISO week takes its base
type's format plus an extension name.

**Each parameter** is one of four kinds:

| parameter type | what the kernel passes | in the Nanuq twin |
|---|---|---|
| any data type (`float`, `int64`, `StrView`, ...) | row `i` of an input column | an `Expr` |
| `var RowRng` | a random stream, positioned at the row's key | a row-index column, and a `seed` argument |
| `Size` | the `size` keyword argument | a `size: int` argument |
| `Kwargs` | all keyword arguments, unpickled | a `kwargs` argument |

Here is what it writes for `exponentialCdf`: the generated public proc above
goes in, and this comes out (the proc itself, repeated first, is left out):
"""
nbSource(expoCdfExpansion.split("\n\n", 1)[1])
nbText: """
Line by line, the kernel:

- checks it got as many input columns as the proc has column parameters;
- unpickles the keyword arguments (none here: `kwPtr` is empty);
- works out the row count, `inputsLen`: the common length of the inputs,
  where a length-1 input (a literal such as `pl.lit(2.0)`) broadcasts;
- wraps each input in a `Col[float]`, typed from the parameter;
- allocates the output, `Out[float]`;
- loops over the rows: if every input is valid at row `i`, it calls the proc
  on the values and stores the result, else it stores a null;
- hands the output over through `ret`, named after the first input, as
  Polars expects of an elementwise function;
- in `finally`, releases the inputs, which the plugin owns.

`guarded` wraps it all: an exception, from a parameter check or anywhere else,
is caught and its message stored. The field function answers the planner's
question (what comes out of this, given these input fields?) with the same
type and naming rules, without seeing any data.

For `exponentialPpf` the only difference is the store, because the proc
returns `Option[float]`:
"""
nbSource(between(expoPpfExpansion, "for i in", "setNull(i)") &
                   "\n          ...")
nbText: """
And `exponentialSamples`, which takes a `RowRng` and a `Size` and returns a
`seq`, shows the other parameter kinds at work: the twin gets a row-index
column, `size` and `seed`, both pickled into the keyword arguments; the kernel
reads `seed` into the stream and `size` from the keyword arguments, positions
the stream at each row's key before calling the proc, and writes an
`ArrOut`, the fixed-size array output:
"""
nbSource(between(expoSamplesExpansion, "when declared", "isDeterministic") & "\n\n" &
                   between(expoSamplesExpansion, "proc exponentialSamplesKernel", "o.setNull(i)") &
                   "\n      ...")
nbText: """
`isDeterministic = false` tells the Polars optimizer not to merge or cache two
identical sampling expressions.
"""

nbText: """
### Under the generated code

The kernel leans on a few generic types in `native.nim`. They are where the
Arrow details live, so that the macro can stay a template of a loop.

**`Col[T]`, an input column.** It holds a pointer to the values, a pointer to
the validity bitmap (nil when there are no nulls), an offset, and a *stride*.
When the column is a single chunk whose Arrow type already is `T`'s storage
(Float64 for `float`), `readCol` points straight into Polars' buffer:
**zero-copy**. Otherwise (several chunks, or an `Int32` column passed where
a `float` is expected) it converts once into a buffer of its own. A length-1
input gets stride 0, so `c[i]` reads element 0 for every `i`: that is the
broadcasting, at the cost of one multiplication per read.

**`Out[T]`, the output.** A `malloc`'ed buffer of `n` values, handed over to
Polars as is. The validity bitmap is allocated only at the first null, so a
column without nulls never pays for one. `finish` wraps buffer and bitmap in
an `ArrowArray` with a `release` callback that frees them, and an
`ArrowSchema` (format, name, metadata), into a `SeriesExport`. `ArrOut[E]`
does the same for fixed-size arrays (a child array of `n * size` values) and
the string outputs write Arrow string views, where strings of up to 12 bytes
live inside the view itself.

**Ownership.** The plugin owns everything it is given: `releaseInput` calls
each chunk's `release`, then the export's. Everything it returns, Polars
owns, and frees through the callbacks. The structs are allocated with C's
`malloc`, not Nim's allocator, because Polars frees them from its own
threads; that is also why the library is built with `-d:useMalloc`.

**Errors.** The ABI has no error return. A failed call stores its message in
a thread-local string, leaves `ret` as it was, and Polars, seeing an output
whose private data is nil, calls `_polars_plugin_get_last_error_message` and
raises with that message.

All of that can be exercised without Polars. The page links the plugin's
kernel into this very program, so here it is called by hand, with Arrow
arrays built by hand: `x = [0, 0.5, null, 3]` and a length-1 `rate = [2]`:
"""

nbCode:
  proc expoCdfKernel(inputs: ptr UncheckedArray[SeriesExport], n: csize_t,
                     kw: ptr uint8, kwLen: csize_t, ret: ptr SeriesExport,
                     ctx: ptr CallerContext) {.importc: "_polars_plugin_exponentialCdf", cdecl.}
  proc lastErrorMessage(): cstring {.importc: "_polars_plugin_get_last_error_message", cdecl.}

  proc float64Series(name: string, values: openArray[float], nulls: openArray[int] = []): SeriesExport =
    ## A Float64 column as Polars would pass it: one chunk, malloc'ed buffers.
    let data = cast[ptr UncheckedArray[float64]](allocC(8 * values.len))
    for i, v in values: data[i] = v
    var valid: ptr UncheckedArray[uint8]
    if nulls.len > 0:
      valid = cast[ptr UncheckedArray[uint8]](allocC((values.len + 7) div 8))
      for k in 0 ..< (values.len + 7) div 8: valid[k] = 0xff
      for i in nulls: valid[i shr 3] = valid[i shr 3] and not uint8(1 shl (i and 7))
    exportSeries(newSchema("g", name), newArray(values.len, nulls.len, [pointer(valid), pointer(data)]))

  proc callCdf(x, rate: SeriesExport) =
    var inputs = [x, rate]
    var ret: SeriesExport                      # all zeros: "no result yet"
    expoCdfKernel(cast[ptr UncheckedArray[SeriesExport]](inputs[0].addr), 2, nil, 0, ret.addr, nil)
    if ret.privateData.isNil:
      echo "failed: ", lastErrorMessage()
      return
    let a = ret.arrays[0]
    let values = cast[ptr UncheckedArray[float64]](a.buffers[1])
    let valid = cast[ptr UncheckedArray[uint8]](a.buffers[0])
    echo "format ", ret.field.format, ", name ", ret.field.name, ", length ", a.length,
         ", nulls ", a.nullCount
    echo "values ", (0 ..< a.length.int).mapIt(
      if valid.isNil or ((valid[it shr 3] shr (it and 7)) and 1) == 1: $values[it] else: "null")
    releaseInput(ret.addr)                     # we are Polars now: we own the output

  callCdf(float64Series("x", [0.0, 0.5, 0.0, 3.0], nulls = [2]), float64Series("rate", [2.0]))
  callCdf(float64Series("x", [1.0]), float64Series("rate", [-1.0]))

nbText: """
Row 2 is null because `x` is null there, `rate` was broadcast, the output is
named after `x`, and a negative rate fails with the parameter check's message,
which Polars would raise as a `ComputeError`.

### Keyword arguments, pickled

Python Polars passes `kwargs` as a pickled dict (pickle protocol 5) and Rust
plugins read it with serde-pickle. nanuq-more has its own 180 lines of pickle:
a reader for flat dicts of numbers, strings, booleans and None (the shapes
keyword arguments take), and a writer, for Nanuq's twins. What the samples
twin sends for `size = 3, seed = 1`, and what the kernel reads back:
"""

nbCode:
  let bytes = writePickle([("size", toPickle(3)), ("seed", toPickle(1))])
  echo bytes.len, " bytes: ", bytes.mapIt(it.toHex).join(" ")
  echo readPickle(bytes)

nbText: """
`80 02` is the protocol, `7D` an empty dict, `28` a mark, `58` a string with
its 4-byte length, `8A 08` an 8-byte integer, `75` "set the items since the
mark", `2E` the end. The reader also handles the opcodes Python's protocol 5
writes (frames, short strings, memo entries), which the writer never needs.

### The other three things the macro writes

**The field function** is called at planning time, before any data exists:
`fieldOf(T, name, size)` turns the Nim return type into an Arrow schema
(`+w:3` with a Float64 child for `samples(3)`). `size` arrives here too, in
the keyword arguments, because the output type depends on it.

**The Nanuq twin** sits under `when declared(polarsPluginLib)`, so it exists
only in a module that called `nanuqBindings()`, and only when that module is
compiled into a program, not as the library itself. `nanuqBindings` imports
Nanuq and defines `polarsPluginLib`: at compile time, `buildPlugin` runs
`nim c --app:lib` on the module's own file, caches the library under a hash of
the module's text, its siblings and polarsplugin (so an edit rebuilds it, and
an unchanged module is not rebuilt), and returns its path. The twin is then
one call to Nanuq's `registerPluginFunction`, with the same flags as the
Python wrapper.

**Nothing at all, on the JavaScript backend.** `polarsplugin.nim` imports
`polarsplugin/jsstub` there, whose `polarsExpr` is `macro polarsExpr*(fn:
untyped): untyped = fn`. The plugin module compiles to JavaScript as plain
functions, which is how the plugins explainer draws the distributions in the
browser with the same code. `specfun.nim` has a JavaScript branch for the
three C functions it imports (`expm1` and `log1p` come from `Math`, `lgamma`
is a Lanczos approximation, `erfc` a Chebyshev fit good to 1e-7, enough for a
plot).
"""

# ---------------------------------------------------------------------------

nbText: """
## The numerics

What each distribution's block computes with:

| distribution | density | cdf and sf | quantiles | sampling |
|---|---|---|---|---|
| normal | closed form | `erfc`, `logNdtr` for the logs | `ndtri` | ziggurat |
| log-normal | closed form | `erfc` of `ln x` | `exp` of `ndtri` | `exp` of a normal |
| exponential | closed form | `expm1`, `exp` | `ln1p`, `ln` | inversion |
| uniform | closed form | clamped line | line | scaled uniform |
| gamma | `lgamma` | `gammaP`, `gammaQ` | solved | Marsaglia-Tsang |
| beta | `lbeta` | `betaI`, `betaIc` | solved | two gammas |
| Cauchy, Pareto, Weibull | closed form | closed form | closed form | inversion |
| Bernoulli, geometric, discrete uniform | closed form | closed form | closed form or searched | comparison, logs, scaling |
| binomial | `lgamma` | `betaIc`, `betaI` | searched | beta splitting |
| Poisson | `lgamma` | `gammaQ`, `gammaP` | searched | inversion or PTRS |

Every special function is in `specfun.nim`, about 240 lines of plain Nim
(C's `erfc`, `lgamma`, `expm1` and `log1p` aside).

**Normal quantiles: `ndtri`** is Wichura's algorithm AS241 (PPND16): two
rational functions of degree 7, one for the centre (`|q - 0.5| <= 0.425`) and
one for the tails in `sqrt(-ln q)`, good to about 1e-16. The log-cdf,
`logNdtr`, switches to an asymptotic series below `z = -20`, where `erfc`
underflows to 0 and `ln` of it would give `-Inf`.

**The incomplete gamma** gives the gamma cdf, `gammaP(shape, rate * x)`, and,
by an identity, the Poisson one: P(N <= k) for rate λ is `gammaQ(k + 1, λ)`.
`gammaP` sums a power series, which converges fast for `x < a + 1`;
`gammaQ` evaluates a continued fraction (Lentz's method), which converges fast
for `x >= a + 1`. Each computes its own region and gets the other as the
complement, so the small tail is always computed directly, never as
`1 - (almost 1)`.

**The incomplete beta** gives the beta cdf and, by another identity, the
binomial one: P(X <= k) is `betaIc(k + 1, n - k, p)`. The continued fraction
`betacf` converges for `x < (a + 1) / (a + b + 2)`; past that point it is used
on the mirrored problem, `I_x(a, b) = 1 - I_(1-x)(b, a)`. `betaI` and `betaIc`
compute the lower and upper tails, and each picks the fraction that gives its
tail directly when the complement would cancel. The difference shows far in
the upper tail:
"""

nbCode:
  let x = 0.999
  echo "1 - betaI:  ", 1 - betaI(2.0, 30.0, x)   # the complement, computed by subtraction
  echo "betaIc:     ", betaIc(2.0, 30.0, x)      # the upper tail, computed directly

nbText: """
**Solving for a quantile.** `solveIncreasing` finds `x` with `cdf(x) = q`. It
takes Newton steps, using the pdf as the derivative, and keeps a bracket
`[a, b]` that every evaluation narrows; a step that would leave the bracket
bisects it instead, or doubles away from the guess while one side is still
infinite. Here is the gamma(2, 1) quantile at 0.99, printing each point
where the cdf is evaluated:
"""

nbCode:
  var evals = 0
  let guess = 2.0 + sqrt(2.0) * ndtri(0.99)       # what guess0 gives: mean + sd * ndtri(q)
  let q99 = solveIncreasing((inc evals; echo "  x = ", x; gammaCdf(x, 2.0, 1.0)),
                            gammaPdf(x, 2.0, 1.0), 0.99, 0.0, Inf, guess)
  echo "quantile ", q99, " after ", evals, " cdf evaluations; cdf there: ", gammaCdf(q99, 2.0, 1.0)

nbText: """
Newton converges quadratically once it is close, so a handful of evaluations
is typical. That is still several incomplete-gamma evaluations per row, which
is why the blocks give a closed-form `ppf` wherever one exists.

**Searching an integer.** For a discrete distribution, `searchInteger` finds
the smallest integer `k` whose cdf reaches `q`: from the guess it gallops
(steps of 1, 2, 4, ...) until the test flips, then bisects. With the normal
approximation as the guess, a binomial with a million trials takes a handful
of cdf evaluations:
"""

nbCode:
  var tests = 0
  let k = searchInteger((inc tests; binomialCdf(k, 1_000_000, 0.3) >= 0.999), 0.0, 1e6,
                        300_000.0 + sqrt(210_000.0) * ndtri(0.999))   # guess0
  echo "quantile 0.999: ", k, " after ", tests, " cdf evaluations"
  echo "binomialPpf:    ", binomialPpf(0.999, 1_000_000, 0.3)

nbText: """
**Discrete entropy** has no closed form for the binomial and the Poisson.
`sumEntropy` sums `-p ln p` over the mean ± 40 standard deviations, and above
a standard deviation of 10⁴ switches to the normal limit `½ ln(2πe σ²)`,
whose error is then below 1e-9.

How close is all this? `tests/check_stats.py` compares every method of every
distribution with scipy.stats on 20,000 random parameter sets. The largest
relative difference is below 1e-10, most methods are below 1e-13, discrete
quantiles agree exactly, and only the binomial log-tails below 1e-280 lose
digits.
"""

# ---------------------------------------------------------------------------

nbText: """
## Random numbers

Polars may split a column into chunks and run them on different threads, in
any order. A sampler that keeps one random state and advances it row by row
would give different numbers for different chunkings. polars-stats solves this
by keying each draw on the row, and nanuq-more does the same with `RowRng`
(`polarsplugin/rowrng.nim`, about 80 lines):

- a stream is three numbers: the seed, the row's key, a counter;
- `startRow(row)` sets the key to `splitmix64(seed xor splitmix64(row))` and
  the counter to 0;
- each draw is `splitmix64(key + counter * golden)`, after bumping the counter.

A draw is then a pure function of (seed, row key, draw number). The row key
is an input column, the row index by default (`pl.int_range(0, pl.len())`),
so it is right in every chunk. The same row gives the same draws in any
order:
"""

nbCode:
  var r = RowRng(seed: 1)
  for row in [7'u64, 3, 7]:
    r.startRow(row)
    echo "row ", row, ": ", normalSample(r, 0.0, 1.0), "  ", normalSample(r, 0.0, 1.0)

nbText: """
`uniform` takes the top 53 bits and adds half a step, so it never returns
0 or 1, and `ln(u)` or `ppf(u)` are always finite.

How each distribution turns these uniform numbers into its own draws is
the next section.
"""


# Helpers for the sampling section: what a sampler costs, how its draws are
# spread, and how far they are from the distribution.

proc costLine(label: string, numbers, ns: float) =
  echo &"{label:<26} {numbers:>7.2f} {ns:>9.1f}"

template cost(label: string, n: int, draw: untyped) =
  ## Draws `n` values on one row's stream; prints random numbers used and ns per draw.
  block:
    var rng {.inject.} = RowRng(seed: 1)
    rng.startRow(0)
    var sink = 0.0
    let t0 = getMonoTime()
    for _ in 0 ..< n: sink += float(draw)
    let ns = float((getMonoTime() - t0).inNanoseconds) / float(n)
    doAssert sink == sink
    costLine(label, float(rng.counter) / float(n), ns)

template drawMany(n: int, draw: untyped): seq[float] =
  ## `n` draws, one row each (as in a Polars column).
  block:
    var rng {.inject.} = RowRng(seed: 1)
    var got = newSeq[float](n)
    for row in 0 ..< n:
      rng.startRow(uint64(row))
      got[row] = float(draw)
    got

proc histogram(draws: seq[float], lo, hi: float, bins: int, cdf: proc (x: float): float) =
  ## Bars for the draws in each bin; `|` marks where the distribution says the bar should end.
  var counts = newSeq[int](bins)
  let w = (hi - lo) / float(bins)
  for d in draws:
    let b = int(floor((d - lo) / w))
    if b >= 0 and b < bins: inc counts[b]
  var expected = newSeq[float](bins)
  for b in 0 ..< bins:
    let a = lo + float(b) * w
    expected[b] = float(draws.len) * (cdf(a + w) - cdf(a))
  let scale = 50 / max(expected)       # the tallest expected bar is 50 characters
  for b in 0 ..< bins:
    let a = lo + float(b) * w
    let bar = int(round(float(counts[b]) * scale))
    let mark = int(round(expected[b] * scale))
    var line = repeat('#', bar)
    if mark >= line.len: line.add repeat(' ', mark - line.len) & "|"
    else: line[mark] = '|'
    echo &"{a:>5.2f} {line}"

proc ksDistance(draws: seq[float], cdf: proc (x: float): float): float =
  ## Kolmogorov-Smirnov: the largest gap between the draws' cdf and the true one.
  let sorted = draws.sorted
  let n = float(sorted.len)
  for i, x in sorted:
    let f = cdf(x)
    result = max(result, max(abs(float(i + 1) / n - f), abs(f - float(i) / n)))

nbText: """
## Sampling, from scratch

The exponential block says `proc sample(rng: var RowRng): float =
-ln(rng.uniform) / rate`, one line. The binomial block calls `binomialDraw`,
twenty lines of splitting and coin flips, and the normal one goes through a
table of 128 layers built at compile time. This section explains why the
samplers look so different, starting from what a sampler is.

### What a sampler does

A computer has no source of "normal numbers" or "Poisson numbers". It has one
thing: a stream of random bits (here `RowRng`), which `rng.uniform` turns into
a number between 0 and 1 where every value is equally likely. A **sampler**
for a distribution is a recipe that turns one or more of those uniform numbers
into a number that behaves like a draw from the distribution: drawn many times,
the values pile up the way the distribution's density says they should.

Every recipe is judged on two things:

- **Is it exact?** The draws must follow the distribution exactly, not
  approximately. All recipes below are exact (up to floating-point rounding).
- **What does it cost?** How many uniform numbers one draw uses up, and how
  much arithmetic it does with them. That is where the recipes differ.

### Recipe 1: inversion

The cdf of a distribution, `F(x)`, is the chance that a draw is at most `x`.
It climbs from 0 to 1. Turn it around: take a uniform `u` and find the `x`
where `F(x) = u`. That `x` is the quantile, `ppf(u)`, and it is a draw from
the distribution. Why: the chance that `ppf(u) <= x` is the chance that
`u <= F(x)`, and for a uniform `u` that chance is exactly `F(x)`.

In pictures: the cdf is steep where the distribution has a lot of values, so
a whole range of `u` values lands on a narrow range of `x`. Where the cdf is
flat, few `u` values land.

For the exponential, `F(x) = 1 - exp(-rate * x)`, which solves to
`x = -ln(1 - u) / rate`. Since `1 - u` is just as uniform as `u`, the block
writes `-ln(u) / rate`. That is the whole sampler: one uniform and one
logarithm. Here are a few uniforms and the draws they become (rate 1):
"""

nbCode:
  for u in [0.01, 0.25, 0.5, 0.75, 0.99]:
    echo &"u = {u:<5}  ->  x = -ln(1 - u) = {-ln(1 - u):.3f}"

nbText: """
Half of the draws are below 0.693 (the median, `ln 2`), and a 1% chance gives
a draw above 4.6. Do that 100,000 times, one row each as in a Polars column,
and count how many draws fall in each bin of width 0.5. Each `#` is a share
of the draws; the `|` marks where the exponential distribution says the bar
should end:
"""

nbCode:
  let expDraws = drawMany(100_000, exponentialSample(rng, 1.0))
  histogram(expDraws, 0.0, 5.0, 10, proc (x: float): float = exponentialCdf(x, 1.0))

nbText: """
Inversion works for every distribution, which is why it is the macro's
default: a block without `sample` gets `ppf(rng.uniform)`. It is a good
sampler when the quantile has a formula, so the exponential, Cauchy, Pareto,
Weibull, geometric and both uniforms use it, each with its own formula. It is
a bad one when the quantile has to be *solved*: for the gamma, each draw
would run the Newton solver of the numerics section, about seven evaluations
of the incomplete gamma function. That is why the other distributions bring
recipes of their own. The table below, measured while this page rendered,
compares the costs (random 64-bit numbers used per draw, and nanoseconds per
draw on this machine):
"""

nbCode:
  echo "sampler                    numbers   ns/draw"
  cost("uniform", 2_000_000, rng.uniform)
  cost("exponential, inversion", 2_000_000, exponentialSample(rng, 1.0))
  cost("normal, inversion", 2_000_000, ndtri(rng.uniform))
  cost("normal, ziggurat", 2_000_000, normalSample(rng, 0.0, 1.0))
  cost("gamma(2), inversion", 20_000, get(gammaPpf(rng.uniform, 2.0, 1.0)))
  cost("gamma(2), Marsaglia-Tsang", 2_000_000, gammaSample(rng, 2.0, 1.0))

nbText: """
Solving the gamma quantile makes inversion about 20 times slower than the
gamma sampler nanuq-more uses. The normal has a quantile formula (`ndtri`),
but even there a specialised method wins.

### Recipe 2: a ziggurat for the normal

The ziggurat method covers the bell curve with a stack of 128 horizontal
rectangles of equal area, wide at the bottom and narrow at the top, like a
stepped pyramid. A draw picks one rectangle and a horizontal position in it,
both from a single 64-bit random number (7 bits for the rectangle, 32 for the
position). Most of each rectangle lies under the curve. When the point lands
there, which happens about 99% of the time, its horizontal position is the
draw: one comparison and one multiplication, no logarithm or square root.
Only a point in the thin sliver outside the curve, or in the bottom layer
that reaches into the infinite tail, needs a slower second test.

The table above shows it: barely more than one random number per draw (the
extra is the second tests), and faster than inversion. The rectangles' sizes come from a
small computation, which a Nim `const` runs at compile time, so the library
carries the 384 numbers as constants.

### Recipe 3: rejection, for the gamma

Rejection sampling is a dartboard. Draw the density curve, put a box around
it, throw darts uniformly into the box, and keep the `x` of every dart that
lands under the curve. The kept values follow the distribution exactly,
because there are more of them where the curve is higher. The rejected darts
are the price, so the art is to throw from a shape that hugs the curve (a
*proposal*), not from a box.

Marsaglia and Tsang's gamma sampler uses a transformed normal draw as its
proposal, which hugs the gamma density closely:
"""

nbSource(sourceBlock("src/nanuqmore/stats_plugin.nim", "proc stdGamma"))

nbText: """
Each attempt costs one normal draw and one uniform, and a cheap formula
accepts more than 95% of the attempts for any shape of 1 or more, so a draw
costs about two random numbers whatever the shape. For a shape below 1 the
proposal fits badly, so the code draws at shape + 1 and shrinks the result
by `u^(1/shape)`, a known identity: one more uniform per draw.

A rejection sampler uses a *varying* number of random numbers per draw. That
is where the per-row streams pay off: one row's rejected attempts use up
numbers from that row's stream only, so they cannot shift the draws of the
rows after it, however Polars splits the column.

### Recipe 4: build from other distributions

Some distributions are easy to make from others. Two gamma draws `X` (shape
`a`) and `Y` (shape `b`) give a beta draw: `X / (X + Y)` follows Beta(a, b)
exactly. The beta block says just that, and a beta draw costs two gamma draws.
The log-normal is `exp` of a normal draw, and a Bernoulli is "is `u` below
`p`?".

### Discrete distributions: counting instead of measuring

For a distribution on whole numbers, inversion becomes a walk: start at 0,
add up the probabilities of 0, 1, 2, ... until the sum passes `u`, and return
where it stopped. It is exact and needs one uniform, but the walk is about as
long as the mean, so it gets slower as the rate grows. The Poisson sampler
walks for rates below 30. From 30 on it switches to PTRS, a rejection sampler
by Hörmann with a proposal shaped like the Poisson's own bell, whose cost is
about the same at any rate:
"""

nbCode:
  echo "sampler                    numbers   ns/draw"
  for rate in [1, 10, 29]:
    cost(&"poisson({rate}), walk", 1_000_000, float(poissonSample(rng, float(rate))))
  for rate in [31, 10_000, 1_000_000]:
    cost(&"poisson({rate}), PTRS", 1_000_000, float(poissonSample(rng, float(rate))))
  cost("poisson(10000), quantile", 2_000, get(poissonPpf(rng.uniform, 10_000.0)))

nbText: """
The walk takes longer as the rate goes from 1 to 29, then PTRS jumps in at a
roughly constant cost (a bit over 2 random numbers per draw, for the rejected
attempts). The last line shows the default the macro would have given: a
search over the cdf for every draw, dozens of times slower.

### The binomial: the expensive one

A binomial draw counts the successes in `n` trials. The obvious sampler flips
`n` coins: `n` uniforms, fine for small `n`, hopeless for a million. nanuq-more
splits instead. A beta draw tells where the middle trial's uniform would fall,
which decides whether the boundary `p` lies in the lower or the upper half of
the trials; then it recurses into that half, with `p` rescaled. Each round
halves `n` for the price of two gamma draws, and the last 64 or fewer trials
are flipped one by one:
"""

nbCode:
  echo "sampler                    numbers   ns/draw"
  for n in [10'i64, 64, 1_000, 1_000_000, 1_000_000_000]:
    cost(&"binomial({n}, 0.3)", 200_000, float(binomialSample(rng, n, 0.3)))

nbText: """
The cost grows with the logarithm of `n`: a billion trials cost less than
200 coin flips would. But it is still the slowest sampler here,
at around a microsecond for large `n`. Rejection samplers for the binomial
(BTPE, which NumPy uses) take a constant few random numbers at any `n`; that
is the obvious next improvement.

### Are the draws right?

A sampler can be fast and wrong, so here is a check on 100,000 draws (one row
each) of several distributions. The **Kolmogorov-Smirnov distance** is the
largest gap between the share of draws below `x` and the cdf `F(x)`, over all
`x`. For a correct sampler it shrinks like `1 / sqrt(n)`: `sqrt(n)` times the
distance stays below about 1.36 in 95% of runs, whatever the distribution.
A wrong sampler gives a value that grows with `n`.
"""

nbCode:
  let n = 100_000
  let checks = [
    ("exponential(1)", drawMany(n, exponentialSample(rng, 1.0)),
     proc (x: float): float = exponentialCdf(x, 1.0)),
    ("normal(0, 1)", drawMany(n, normalSample(rng, 0.0, 1.0)),
     proc (x: float): float = normalCdf(x, 0.0, 1.0)),
    ("gamma(0.5, 1)", drawMany(n, gammaSample(rng, 0.5, 1.0)),
     proc (x: float): float = gammaCdf(x, 0.5, 1.0)),
    ("gamma(7, 1)", drawMany(n, gammaSample(rng, 7.0, 1.0)),
     proc (x: float): float = gammaCdf(x, 7.0, 1.0)),
    ("beta(2, 3)", drawMany(n, betaSample(rng, 2.0, 3.0)),
     proc (x: float): float = betaCdf(x, 2.0, 3.0))]
  for (name, draws, cdf) in checks:
    echo &"{name:<16} sqrt(n) * distance = {sqrt(float(n)) * ksDistance(draws, cdf):.2f}"

nbText: """
For discrete distributions the same idea compares how often each value comes
up with its probability; `tests/check_stats.py` runs these checks, plus means
and variances, for all fourteen distributions against scipy.stats. Seeded
draws repeat within nanuq-more, but they are not meant to match polars-stats'
draws number for number: the recipes differ, so the same seed gives different
(and equally valid) numbers.

### The whole table

| distribution | recipe | random numbers per draw |
|---|---|---|
| uniform, discrete uniform | scale `u` | 1 |
| exponential, Cauchy, Pareto, Weibull, geometric | inversion by formula | 1 |
| Bernoulli | `u < p` | 1 |
| normal | ziggurat | about 1 |
| log-normal | `exp` of a normal | about 1 |
| gamma | Marsaglia-Tsang rejection | about 2 (3 for shape below 1) |
| beta | two gammas | about 4 |
| Poisson | walk below rate 30, PTRS from 30 | 1, then about 2 |
| binomial | beta splitting, then coin flips | grows with log n |

So the one-line exponential and the twenty-line binomial are the same idea
(turn uniform numbers into draws, exactly) at different prices: when the
quantile has a formula, inversion is short and fast, and otherwise a
sampler has to be cleverer than the default.
"""

# ---------------------------------------------------------------------------

nbText: """
## The Python side

The Python package has no maths in it. `pip install` brings the shared
library (`plugins.so`, built from `src/nanuq_more/plugins.nim`, which imports
both plugin modules, by the nimlang build hook) and two small modules.
`_lib.call` is the one place that talks to Polars:
"""
nbSource(sourceBlock("src/nanuq_more/_lib.py", "def call"), slPython)
nbText: """
`stats.py` rebuilds polars-stats' classes on top. A base class turns the
constructor's parameters into expressions (numbers become typed literals,
strings column names) and maps each method to a plugin function by name:
"""
nbSource(dedent(sourceBlock("src/nanuq_more/stats.py", "    def _f") & "\n\n" &
                      sourceBlock("src/nanuq_more/stats.py", "    def cdf") & "\n\n" &
                      sourceBlock("src/nanuq_more/stats.py", "    def sample(")), slPython)
nbText: """
and each distribution is one line, made by a small class factory:
"""
nbSource(sourceBlock("src/nanuq_more/stats.py", "Gamma =") & "\n" &
                      sourceBlock("src/nanuq_more/stats.py", "Binomial ="), slPython)
nbText: """
Integer parameters (`n`, the discrete uniform's bounds) become `Int64`
literals, because the Nim proc takes `int64` and `readCol` refuses to read a
float column as integers. A null in, a bad parameter, a quantile out of
range, and an integer quantile:
"""
nbPython("""
from nanuq_more.stats import Binomial, Gamma, Normal

df = pl.DataFrame({"x": [9.8, 12.1, None], "sigma": [0.5, 0.5, 0.5]})
print(df.with_columns(
    tail=Normal(mu=10.0, sigma="sigma").sf("x"),
    q=Gamma(2.0, 1.0).ppf(pl.Series([0.5, 0.99, 1.5])),
    median=Binomial(10, 0.3).ppf(0.5),
))
try:
    df.select(Normal(0.0, -1.0).cdf("x"))
except pl.exceptions.ComputeError as e:
    print(str(e).splitlines()[0])
""")
nbText: """
The error line is the message of the `require` in the Nim parameter check,
stored by `guarded` and read back by Polars.
"""

# ---------------------------------------------------------------------------

nbText: """
## The Nanuq side

Nanuq needed one function for all this, `registerPluginFunction`, with the
same name and options as Python's (nanuq#70, released in 0.6.1). It packs the
flags into a bit set and calls `nq_expr_plugin` in Nanuq's Rust bridge, which
builds the same `FunctionExpr::FfiPlugin` node that Python Polars builds:
Polars itself then loads the library and calls the kernel, as it would for
Python.

On top of it come the twins. This page imports `nanuqmore/stats_plugin`
(which calls `nanuqBindings()`), so it has them; the plugin library was built
while this page compiled:
"""

nbCode:
  let readings = newDataFrame(series("x", [9.8, 101.0, 12.1]), series("mu", [10.0, 100.0, 10.0]),
                              series("sigma", [0.5, 2.0, 0.5]))
  echo readings.withColumns(
    normalSf(col"x", col"mu", col"sigma").alias("tail"),
    poissonSample(lit 4.0, seed = 1).alias("draws"),
    gammaSamples(lit 2.0, lit 1.0, size = 3, seed = 1).alias("three"))

nbText: """
`normalSf(col"x", col"mu", col"sigma")` and `normalSf(12.1, 10.0, 0.5)` are
the same name with different parameter types, and Nim picks by type: the
first builds a query, the second computes a float. The draws match the Python
package's, with the same seed, because it is the same code on the same row
keys.
"""

# ---------------------------------------------------------------------------

nbText: """
## Sharp edges

What this design costs, as of today:

- **Per-row work that could be per-column.** The parameter checks, the NaN
  test and the validity test run on every row, even when the parameters are a
  literal. The plugins explainer measured the result: about 12 ns of fixed
  cost per row, which polars-stats 0.2 no longer pays on its cheap kernels.
  The fix belongs in `polarsExpr`: check length-1 inputs once, before the loop,
  and skip the validity test when no input has nulls.
- **Text-built code.** `distributionImpl` writes code as strings. It is easy
  to read but easy to break, and the compiler's error then points into code
  that exists only in memory (`-d:distDebug` prints it).
- **No termination check on defaults.** A block without `pdf` or `logPdf`, or
  without `cdf` or `sf`, compiles to infinite recursion.
- **Solved quantiles are slow.** The gamma and beta quantiles cost several cdf
  evaluations a row; a better first guess (Wilson-Hilferty for the gamma)
  could save some of them.
- **Two ABIs to follow.** The plugin ABI (polars-ffi 0.1) and the Arrow C data
  interface are stable by design, but the plugin ABI is Polars' internal
  contract, documented by its code; a change there needs a change in
  `native.nim`.

The homework list at the end of the plugins explainer starts with the first one.
"""

nbSave
