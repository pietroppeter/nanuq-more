## "Inside the distributions": a nimib deep dive into how nanuq-more's
## probability distributions are built, from a block of maths to a Polars plugin
## function, through the `continuous`/`discrete` macros and `{.polarsExpr.}`.
##
## Render (from the repo root, with the nanuq repo next to this one):
##   NANUQ_MORE_PYTHON=<a python with polars and nanuq_more> \
##   nim r -d:release --path:../nanuq/src --path:../nanuq/docs --path:src --path:docs docs/distributions.nim

import nimib
import std/[os, osproc, strutils, strformat, math, sequtils, json]
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

The samplers, by distribution:

- **normal**: the 128-layer ziggurat of Marsaglia and Tsang. The tables are
  computed by a Nim proc at compile time (`const (zigK, zigW, zigF) =
  zigTables()`), so the library carries them as constants. About 99% of draws
  take one 64-bit random number and a comparison.
- **gamma**: Marsaglia and Tsang's method, a normal draw cubed and accepted
  or rejected; for a shape below 1, a draw at shape + 1 times `u^(1/shape)`.
- **beta**: `X / (X + Y)` for two gamma draws.
- **Poisson**: sequential inversion below a rate of 30; above it, Hörmann's
  PTRS (transformed rejection with squeeze), whose cost hardly depends on the
  rate.
- **binomial**: Devroye's splitting by beta order statistics: a beta draw
  splits `n` trials in two halves and decides which half the boundary falls
  in, until 64 trials are left, which are drawn one by one.
- **the rest** by inversion (exponential, Cauchy, Pareto, Weibull, geometric)
  or directly (uniform, Bernoulli, discrete uniform).

Seeded draws repeat within nanuq-more, but they are not meant to match
polars-stats' draws number for number: the samplers differ. What
`tests/check_stats.py` checks is that they have the right moments and pass
Kolmogorov-Smirnov tests against the distribution.
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

nbSourceFiles:
  nbFoldCode "src/nanuqmore/stats_plugin.nim"
  nbFoldCode "src/nanuqmore/distmacro.nim"
  nbFoldCode "src/nanuqmore/specfun.nim"
  nbFoldCode "src/polarsplugin.nim"
  nbFoldCode "src/polarsplugin/native.nim"
  nbFoldCode "src/polarsplugin/arrow.nim"
  nbFoldCode "src/polarsplugin/pickle.nim"
  nbFoldCode "src/polarsplugin/rowrng.nim"
  nbFoldCode "src/polarsplugin/jsstub.nim"
  nbFoldCode "src/nanuq_more/plugins.nim"
  nbFoldCode "src/nanuq_more/_lib.py"
  nbFoldCode "src/nanuq_more/stats.py"
  nbFoldCode "tests/check_stats.py"

nbSave
