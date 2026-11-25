"""nanuq-more humanize (Nim plugin) vs Python's humanize through map_elements.

    uv run --with humanize python benchmarks/bench_humanize.py [rows]

The plugin runs on all the rows; humanize, one Python call per value, on a
tenth of them (scaled up, so both columns are per the same row count).
Also checks the two agree on that tenth.
"""
import datetime as dt, json, sys, time
import numpy as np
import polars as pl
import humanize
import nanuq_more.humanize as hz

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
SMALL = N // 10
rng = np.random.default_rng(0)
df = pl.DataFrame({
    "bytes": (10 ** rng.uniform(0, 13, N)).astype(np.int64),
    "x": rng.normal(0, 1e6, N),
    "secs": pl.Series(rng.integers(0, 10**9, N) * 1000, dtype=pl.Duration("ms")).cast(pl.Duration("us")),
})
small = df.head(SMALL)


def best(f, reps=3):
    f(); ts = []
    for _ in range(reps):
        t = time.perf_counter(); f(); ts.append(time.perf_counter() - t)
    return min(ts)


cases = [
    ("naturalsize(bytes)", "bytes", hz.naturalsize, humanize.naturalsize),
    ("intword(bytes)", "bytes", hz.intword, humanize.intword),
    ("intcomma(x)", "x", hz.intcomma, humanize.intcomma),
    ("ordinal(bytes)", "bytes", hz.ordinal, humanize.ordinal),
    ("metric(x, unit='V')", "x", lambda c: hz.metric(c, unit="V"), lambda v: humanize.metric(v, unit="V")),
    ("fractional(x)", "x", hz.fractional, humanize.fractional),
    ("naturaldelta(duration)", "secs", hz.naturaldelta, humanize.naturaldelta),
    ("precisedelta(duration)", "secs", hz.precisedelta, humanize.precisedelta),
]
rows = []
for name, c, nim, py in cases:
    t_nim = best(lambda: df.select(nim(c)))
    t_py = best(lambda: small.select(pl.col(c).map_elements(py, return_dtype=pl.String)), reps=1) * (N / SMALL)
    same = small.select(nim(c)).to_series().equals(small.select(pl.col(c).map_elements(py, return_dtype=pl.String)).to_series())
    rows.append({"case": name, "nim": t_nim, "python": t_py, "same": same})
    print(f"{name:26s} nim {t_nim*1e3:7.0f} ms   humanize {t_py*1e3:8.0f} ms  ({t_py/t_nim:5.0f}x)  same: {same}")

out = {"rows": N, "polars": pl.__version__, "humanize": humanize.__version__, "results": rows}
json.dump(out, open(f"benchmarks/results/humanize_{N // 1_000_000}M.json", "w"), indent=1)
