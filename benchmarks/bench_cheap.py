"""Cheap kernels with column parameters, where polars-stats 0.2 (#120) says it gains most.

    python benchmarks/bench_cheap.py [rows] [out.json]
"""
import json, sys, time

import numpy as np
import polars as pl
import polars_stats as ps

import nanuq_more.stats as nm

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
rng = np.random.default_rng(0)
df = pl.DataFrame({
    "x": rng.uniform(-1, 3, N), "lo": rng.uniform(-1, 0, N), "hi": rng.uniform(1, 2, N),
    "p": rng.uniform(0, 1, N), "k": rng.integers(0, 2, N).astype(float), "rate": rng.uniform(0.5, 2, N),
    "mu": rng.normal(0, 1, N), "sigma": rng.uniform(0.5, 2, N),
})


def best(f, reps=21):
    f()
    ts = []
    for _ in range(reps):
        t = time.perf_counter(); f(); ts.append(time.perf_counter() - t)
    return min(ts)


cases = [
    ("Uniform pdf", lambda: nm.Uniform("lo", "hi").pdf("x"), lambda: ps.Uniform(min="lo", max="hi").pdf("x")),
    ("Uniform cdf", lambda: nm.Uniform("lo", "hi").cdf("x"), lambda: ps.Uniform(min="lo", max="hi").cdf("x")),
    ("Bernoulli pmf", lambda: nm.Bernoulli("p").pmf("k"), lambda: ps.Bernoulli(p="p").pmf("k")),
    ("Bernoulli cdf", lambda: nm.Bernoulli("p").cdf("k"), lambda: ps.Bernoulli(p="p").cdf("k")),
    ("Exponential pdf", lambda: nm.Exponential("rate").pdf("x"), lambda: ps.Exponential(rate="rate").pdf("x")),
    ("Exponential cdf", lambda: nm.Exponential("rate").cdf("x"), lambda: ps.Exponential(rate="rate").cdf("x")),
    ("Normal pdf", lambda: nm.Normal("mu", "sigma").pdf("x"), lambda: ps.Normal(mu="mu", sigma="sigma").pdf("x")),
]

rows = []
for name, nim_e, rust_e in cases:
    r = {"case": name, "nim": best(lambda: df.select(nim_e())), "rust": best(lambda: df.select(rust_e()))}
    rows.append(r)
    print(f"{name:16s} nim {r['nim']*1e3:6.2f} ms  rust {r['rust']*1e3:6.2f} ms")
json.dump({"rows": N, "polars": pl.__version__, "results": rows},
          open(sys.argv[2] if len(sys.argv) > 2 else "bench_cheap.json", "w"), indent=1)
