# nanuq-more
We want more (who?)

Polars expression plugins written in Nim, for [Nanuq](https://github.com/pietroppeter/nanuq)
and for Python Polars, from the same shared library. Exploration prototype (5 November 2026);
the write-up is `docs/nim_plugins.nim` ("Polars plugins, without the Rust"), published as
this repository's GitHub Pages site.

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

df.with_columns(week=pl.col("day").isoweek.from_date(),
                tail=Normal(mu="mu", sigma="sigma").sf("x"))
```

## Use from Nanuq

Needs a Nanuq with `registerPluginFunction` (Nanuq branch `claude/project-thread-ez686y`).
Importing a plugin module builds its library at compile time and gives `Expr` versions of its
functions:

```nim
import nanuq, nanuqmore/[isoweek_plugin, stats_plugin]
df.withColumns(isoweek(col"day").alias("week"), normalSf(col"x", col"mu", col"sigma").alias("tail"))
```

## Checks and benchmarks

- `tests/check_iso.py`, `tests/check_stats.py`: against Python's `isocalendar` and scipy.stats
  (every method of every distribution; table in `benchmarks/results/accuracy_all.txt`).
- `tests/test_nanuq_*.nim`: the same functions from Nanuq.
- `benchmarks/bench_stats.py`, `bench_isoweek.py`: against polars-stats, scipy, plain Polars
  expressions and iso-week-date; run by hand (not in CI), results in `benchmarks/results/`,
  which the explainer reads.

## Render the explainer

CI (`.github/workflows/pages.yml`) renders it on every change and publishes it on main. Locally:

```sh
NANUQ_MORE_PYTHON=<python with polars, polars-stats, scipy and nanuq_more> \
nim r -d:release --path:../nanuq/src --path:../nanuq/docs --path:src \
  -d:nanuqLibDir=<Nanuq library built from the branch above> docs/nim_plugins.nim
```
