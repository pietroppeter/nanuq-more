"""nanuq-more (Nim) vs polars-stats (Rust) vs scipy vs plain Polars expressions.

    uv run --with polars-stats --with scipy python benchmarks/bench_stats.py [rows]
"""
import json, math, sys, time

import numpy as np
import polars as pl
import polars_stats as ps
import scipy.stats as st

import nanuq_more.stats as nm

N = int(sys.argv[1]) if len(sys.argv) > 1 else 10_000_000
rng = np.random.default_rng(0)
df = pl.DataFrame({
    "x": rng.normal(0, 2, N), "q": rng.uniform(0, 1, N),
    "mu": rng.normal(0, 1, N), "sigma": rng.uniform(0.5, 2, N),
    "shape": rng.uniform(0.5, 10, N), "k": rng.integers(0, 40, N).astype(float),
    "lam": rng.uniform(1, 30, N),
})
a = {c: df[c].to_numpy() for c in df.columns}


def best(f, reps=5):
    f()
    ts = []
    for _ in range(reps):
        t = time.perf_counter(); f(); ts.append(time.perf_counter() - t)
    return min(ts)


def native_pdf():
    z = (pl.col("x") - pl.col("mu")) / pl.col("sigma")
    return (-0.5 * z * z).exp() / (pl.col("sigma") * math.sqrt(2 * math.pi))


cases = [
    ("Normal pdf", lambda: nm.Normal("mu", "sigma").pdf("x"), lambda: ps.Normal(mu="mu", sigma="sigma").pdf("x"),
     lambda: st.norm.pdf(a["x"], a["mu"], a["sigma"]), native_pdf),
    ("Normal cdf", lambda: nm.Normal("mu", "sigma").cdf("x"), lambda: ps.Normal(mu="mu", sigma="sigma").cdf("x"),
     lambda: st.norm.cdf(a["x"], a["mu"], a["sigma"]), None),
    ("Normal ppf", lambda: nm.Normal("mu", "sigma").ppf("q"), lambda: ps.Normal(mu="mu", sigma="sigma").ppf("q"),
     lambda: st.norm.ppf(a["q"], a["mu"], a["sigma"]), None),
    ("Normal sample", lambda: nm.Normal("mu", "sigma").sample(seed=1), lambda: ps.Normal(mu="mu", sigma="sigma").sample(seed=1),
     lambda: np.random.default_rng(1).normal(a["mu"], a["sigma"]), None),
    ("Normal cdf, scalar params", lambda: nm.Normal(0.0, 1.0).cdf("x"), lambda: ps.Normal(mu=0.0, sigma=1.0).cdf("x"),
     lambda: st.norm.cdf(a["x"], 0.0, 1.0), None),
    ("Exponential cdf", lambda: nm.Exponential("sigma").cdf("shape"), lambda: ps.Exponential(rate="sigma").cdf("shape"),
     lambda: st.expon.cdf(a["shape"], scale=1 / a["sigma"]), None),
    ("Beta cdf", lambda: nm.Beta("shape", "sigma").cdf("q"), lambda: ps.Beta(a="shape", b="sigma").cdf("q"),
     lambda: st.beta.cdf(a["q"], a["shape"], a["sigma"]), None),
    ("Gamma cdf", lambda: nm.Gamma("shape", "sigma").cdf("lam"), lambda: ps.Gamma(shape="shape", rate="sigma").cdf("lam"),
     lambda: st.gamma.cdf(a["lam"], a["shape"], scale=1 / a["sigma"]), None),
    ("Gamma ppf (derived: solved)", lambda: nm.Gamma("shape", "sigma").ppf("q"),
     lambda: ps.Gamma(shape="shape", rate="sigma").ppf("q"),
     lambda: st.gamma.ppf(a["q"], a["shape"], scale=1 / a["sigma"]), None),
    ("Weibull cdf", lambda: nm.Weibull("shape", "sigma").cdf("lam"), lambda: ps.Weibull(shape="shape", scale="sigma").cdf("lam"),
     lambda: st.weibull_min.cdf(a["lam"], a["shape"], scale=a["sigma"]), None),
    ("Poisson pmf", lambda: nm.Poisson("lam").pmf("k"), lambda: ps.Poisson(rate="lam").pmf("k"),
     lambda: st.poisson.pmf(a["k"], a["lam"]), None),
    ("Poisson ppf (derived: searched)", lambda: nm.Poisson("lam").ppf("q"), lambda: ps.Poisson(rate="lam").ppf("q"),
     lambda: st.poisson.ppf(a["q"], a["lam"]), None),
    ("Binomial cdf", lambda: nm.Binomial(40, "q").cdf("k"), lambda: ps.Binomial(n=40, p="q").cdf("k"),
     lambda: st.binom.cdf(a["k"], 40, a["q"]), None),
    ("Gamma samples(8)", lambda: nm.Gamma("shape", "sigma").samples(8, seed=1),
     lambda: ps.Gamma(shape="shape", rate="sigma").samples(8, seed=1),
     lambda: np.random.default_rng(1).gamma(a["shape"][:, None], 1 / a["sigma"][:, None], (N, 8)), None),
]

rows = []
for name, nim_e, rust_e, sp, native in cases:
    try:
        r_rust = best(lambda: df.select(rust_e()))
    except Exception as e:  # API differences
        print(name, "polars-stats:", e); r_rust = float("nan")
    r = {"case": name, "nim": best(lambda: df.select(nim_e())), "rust": r_rust,
         "scipy": best(sp, reps=3), "native": best(lambda: df.select(native())) if native else None}
    rows.append(r)
    print(f"{name:28s} nim {r['nim']*1e3:7.1f} ms  rust {r['rust']*1e3:7.1f} ms  scipy {r['scipy']*1e3:7.1f} ms"
          + (f"  polars exprs {r['native']*1e3:7.1f} ms" if native else ""))
json.dump({"rows": N, "polars": pl.__version__, "results": rows}, open(sys.argv[2] if len(sys.argv) > 2 else "bench_stats.json", "w"), indent=1)
