# nanuq-more
We want more (who?)

Polars expression plugins written in Nim, for [Nanuq](https://github.com/pietroppeter/nanuq)
and for Python Polars, from the same shared library. Exploration prototype (5 November 2026);
the write-up is `docs/nim_plugins.nim` ("Polars plugins, without the Rust").

- `src/polarsplugin.nim` (+ `polarsplugin/arrow.nim`, `polarsplugin/pickle.nim`): the Polars
  plugin ABI in pure Nim (Arrow C data interface, `SeriesExport`, pickled kwargs) and the
  `{.polarsExpr.}` macro that turns a scalar proc into a plugin function.
- `src/nanuqmore/isoweek_plugin.nim`: ISO weeks as a Polars extension type (`nanuq.isoweek`,
  Int32 storage `year * 100 + week`).
- `src/nanuqmore/stats_plugin.nim`: normal, log-normal, exponential, uniform, gamma, beta and
  Poisson distributions (pdf/pmf, cdf, sf, ppf, keyed sampling), polars-stats style.
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

- `tests/check_iso.py`, `tests/check_stats.py`: against Python's `isocalendar` and scipy.stats.
- `tests/test_nanuq_*.nim`: the same functions from Nanuq.
- `benchmarks/bench_stats.py`: against polars-stats, scipy and plain Polars expressions;
  results in `benchmarks/results/`.

## Render the explainer

```sh
NANUQ_MORE_PYTHON=<python with polars, polars-stats, scipy and nanuq_more> \
nim r -d:release --path:../nanuq/src --path:../nanuq/docs --path:src \
  -d:nanuqLibDir=<Nanuq library built from the branch above> docs/nim_plugins.nim
```
