# nanuq-more
We want more (who?)

Polars expression plugins written in Nim, for [Nanuq](https://github.com/pietroppeter/nanuq)
and for Python Polars, from the same shared library. Exploration prototype (5 November 2026);
the write-up is the explainer **[Polars plugins, without the Rust](https://pietroppeter.github.io/nanuq-more/)**
(source: `docs/nim_plugins.nim`), this repository's GitHub Pages site. How the distributions are
built (the `continuous`/`discrete` macros, `{.polarsExpr.}`, the numerics) is in the deep dive
**[Inside the distributions](https://pietroppeter.github.io/nanuq-more/distributions.html)**
(source: `docs/distributions.nim`). Python's humanize as a plugin is
**[humanize, vectorized](https://pietroppeter.github.io/nanuq-more/humanize.html)**
(source: `docs/humanize.nim`).

- `src/polarsplugin.nim` (`polarsplugin/native.nim`, `arrow.nim`, `pickle.nim`): the Polars
  plugin ABI in pure Nim (Arrow C data interface, `SeriesExport`, pickled kwargs) and the
  `{.polarsExpr.}` macro that turns a scalar proc into a plugin function. On the JavaScript
  backend (`polarsplugin/jsstub.nim`) the macro is a no-op, so plugin modules also run in a browser.
- `src/nanuqmore/isoweek_plugin.nim`: ISO weeks as a Polars extension type (`nanuq.isoweek`,
  Int32 storage `year * 100 + week`).
- `src/nanuqmore/stats_plugin.nim`: the 14 distributions of polars-stats with its 15 methods
  each (pdf/pmf and log, cdf, sf and logs, ppf, isf, mean, variance, std, median, entropy,
  keyed `sample` and `samples`). Each distribution is a `continuous` or `discrete` block
  (`distmacro.nim`) that gives only its own maths; `specfun.nim` has the special functions.
- `src/nanuqmore/humanize_plugin.nim`: Python's [humanize](https://github.com/python-humanize/humanize)
  (4.17) as plugin functions, the 13 that take a value (`naturalsize`, `intword`, `naturaldelta`,
  `precisedelta`, ...), with humanize's arguments and the same English text; `pyformat.nim` has
  Python's float formatting (`%`-formats, `round`, `repr`), exact and fast.
- `src/nanuq_more/`: the Python package (built with `uv build`, through the nimlang hatch hook).

## Use from Python

```sh
uv build --wheel            # needs only uv: nimlang brings Nim and zig cc
uv run --with dist/nanuq_more-*.whl python -c "import nanuq_more"
```

```python
import polars as pl
import nanuq_more.isoweek
from nanuq_more.stats import Normal
import nanuq_more.humanize as hz

df.with_columns(week=pl.col("day").isoweek.from_date(),
                tail=Normal(mu="mu", sigma="sigma").sf("x"),
                size=hz.naturalsize("bytes"))
```

## Use from Nanuq

Needs Nanuq 0.6.1 or later (`registerPluginFunction`).
Importing a plugin module builds its library at compile time and gives `Expr` versions of its
functions:

```nim
import nanuq, nanuqmore/[isoweek_plugin, stats_plugin, humanize_plugin]
df.withColumns(isoweek(col"day").alias("week"), normalSf(col"x", col"mu", col"sigma").alias("tail"),
               naturalsize(col"bytes", binary = true).alias("size"))
```

## Checks and benchmarks

- `tests/check_iso.py`, `tests/check_stats.py`: against Python's `isocalendar` and scipy.stats
  (every method of every distribution; table in `benchmarks/results/accuracy_all.txt`).
- `tests/check_humanize.py`: against Python's humanize, value by value (about 580 000 values,
  every function and option; last run in `benchmarks/results/humanize_check.txt`).
- `tests/test_nanuq_*.nim`: the same functions from Nanuq (`tests/all.nim` runs both in one program).
- `benchmarks/bench_stats.py`, `bench_isoweek.py`, `bench_humanize.py`: against polars-stats,
  scipy, plain Polars expressions, iso-week-date and humanize through `map_elements`; run by hand (not in CI), results in `benchmarks/results/`,
  which the explainer reads.

## Render the explainers

CI (`.github/workflows/ci.yml`) renders all three in one program (`docs/all.nim`) on every change and
publishes them on main; next to it, a test job runs the checks and the Nim tests. Locally:

```sh
NANUQ_MORE_PYTHON=<python with polars, polars-stats, scipy and nanuq_more> \
nim r -d:release --path:../nanuq/src --path:../nanuq/docs --path:src docs/nim_plugins.nim
NANUQ_MORE_PYTHON=<python with polars and nanuq_more> \
nim r -d:release --path:../nanuq/src --path:../nanuq/docs --path:src --path:docs docs/distributions.nim
```
