"""Every method of every distribution against scipy, on random parameters.

    python tests/check_stats.py    # prints the worst relative error per method
"""
import sys

import numpy as np
import polars as pl
import scipy.stats as st

from nanuq_more import stats as ns

rng = np.random.default_rng(1)
N = 20_000


def U(a, b):
    return rng.uniform(a, b, N)


# (class, params as numpy columns, scipy frozen-distribution factory, value generator)
CASES = {
    "Normal": (ns.Normal, {"mu": U(-3, 3), "sigma": U(0.1, 3)},
               lambda p: st.norm(p["mu"], p["sigma"]), lambda p: p["mu"] + p["sigma"] * rng.normal(0, 3, N)),
    "LogNormal": (ns.LogNormal, {"mu": U(-1, 1), "sigma": U(0.1, 2)},
                  lambda p: st.lognorm(p["sigma"], scale=np.exp(p["mu"])), lambda p: rng.lognormal(0, 2, N)),
    "Exponential": (ns.Exponential, {"rate": U(0.1, 5)},
                    lambda p: st.expon(scale=1 / p["rate"]), lambda p: rng.exponential(3, N)),
    "Uniform": (ns.Uniform, {"min": U(-5, 0), "max": U(0.5, 5)},
                lambda p: st.uniform(p["min"], p["max"] - p["min"]), lambda p: U(-6, 6)),
    "Gamma": (ns.Gamma, {"shape": U(0.2, 20), "rate": U(0.2, 5)},
              lambda p: st.gamma(p["shape"], scale=1 / p["rate"]), lambda p: rng.exponential(5, N)),
    "Beta": (ns.Beta, {"a": U(0.2, 10), "b": U(0.2, 10)},
             lambda p: st.beta(p["a"], p["b"]), lambda p: U(0, 1)),
    "Cauchy": (ns.Cauchy, {"loc": U(-3, 3), "scale": U(0.1, 3)},
               lambda p: st.cauchy(p["loc"], p["scale"]), lambda p: rng.standard_cauchy(N) * 3),
    "Pareto": (ns.Pareto, {"scale": U(0.5, 3), "shape": U(0.5, 6)},
               lambda p: st.pareto(p["shape"], scale=p["scale"]), lambda p: U(0, 20)),
    "Weibull": (ns.Weibull, {"shape": U(0.3, 5), "scale": U(0.2, 4)},
                lambda p: st.weibull_min(p["shape"], scale=p["scale"]), lambda p: rng.exponential(3, N)),
    "Bernoulli": (ns.Bernoulli, {"p": U(0, 1)},
                  lambda p: st.bernoulli(p["p"]), lambda p: rng.integers(-1, 3, N).astype(float)),
    "Binomial": (ns.Binomial, {"n": rng.integers(1, 500, N), "p": U(0, 1)},
                 lambda p: st.binom(p["n"], p["p"]), lambda p: np.floor(U(0, 1) * (p["n"] + 2)) - 1),
    "Poisson": (ns.Poisson, {"rate": U(0.1, 200)},
                lambda p: st.poisson(p["rate"]), lambda p: rng.integers(0, 260, N).astype(float)),
    "Geometric": (ns.Geometric, {"p": U(0.01, 1)},
                  lambda p: st.geom(p["p"]), lambda p: rng.integers(0, 60, N).astype(float)),
    "DiscreteUniform": (ns.DiscreteUniform, {"min": rng.integers(-20, 5, N), "max": rng.integers(5, 40, N)},
                        lambda p: st.randint(p["min"], p["max"] + 1), lambda p: rng.integers(-25, 45, N).astype(float)),
}

worst = 0.0
for name, (cls, params, ref, values) in CASES.items():
    discrete = issubclass(cls, ns.DiscreteDistribution)
    x = values(params)
    q = U(0, 1)
    d = ref(params)
    df = pl.DataFrame({**params, "x": x, "q": q})
    dist = cls(**{k: k for k in params})
    dens = "pmf" if discrete else "pdf"
    methods = {
        dens: (getattr(dist, dens)("x"), getattr(d, dens)(x)),
        "log_" + dens: (getattr(dist, "log_" + dens)("x"), getattr(d, "log" + dens)(x)),
        "cdf": (dist.cdf("x"), d.cdf(x)), "log_cdf": (dist.log_cdf("x"), d.logcdf(x)),
        "sf": (dist.sf("x"), d.sf(x)), "log_sf": (dist.log_sf("x"), d.logsf(x)),
        "ppf": (dist.ppf("q"), d.ppf(q)), "isf": (dist.isf("q"), d.isf(q)),
        "mean": (dist.mean(), d.mean()), "variance": (dist.variance(), d.var()),
        "std": (dist.std(), d.std()), "median": (dist.median(), d.median()),
        "entropy": (dist.entropy(), d.entropy()),
    }
    out = df.select(**{m: e for m, (e, _) in methods.items()})
    line = []
    for m, (_, want) in methods.items():
        got = out[m].to_numpy().astype(float)
        want = np.broadcast_to(np.asarray(want, dtype=float), got.shape)
        same = (got == want) | (np.isnan(got) & np.isnan(want))
        # Relative error; on the log scale, absolute error below 1 (so -1e-30 and 0 agree).
        floor = 1.0 if m.startswith("log_") else 1e-300
        with np.errstate(all="ignore"):
            rel = np.where(same, 0.0, np.abs(got - want) / np.maximum(np.abs(want), floor))
        nan_mismatch = int(np.sum(np.isnan(got) != np.isnan(want)))
        if nan_mismatch:
            print(f"  {name}.{m}: {nan_mismatch} rows NaN on one side only")
        rel = np.nan_to_num(rel, nan=0.0)
        # Far tails, where both sides underflow differently, say little.
        keep = (want > -650) if m.startswith("log_") else (np.abs(want) > 1e-250)
        rel = rel[keep | same]
        err = float(np.max(rel)) if rel.size else 0.0
        worst = max(worst, err if m not in ("ppf", "isf") or not discrete else 0.0)
        line.append(f"{m} {err:.0e}")
    print(f"{name:16s}", "  ".join(line))

# samples: moments against the distribution, and samples(1) == sample
print()
for name, (cls, params, ref, _) in CASES.items():
    p0 = {k: (float(v[0]) if v.dtype.kind == "f" else int(v[0])) for k, v in params.items()}
    dist = cls(**p0)
    df = pl.DataFrame({"i": range(200_000)})
    s = df.select(dist.sample(seed=3).alias("s"), dist.samples(4, seed=3).alias("m"))
    first = s["m"].arr.first()
    draws = s["s"].cast(pl.Float64).to_numpy()
    d = ref({k: np.asarray(v) for k, v in p0.items()})
    ks = st.kstest(draws, d.cdf).pvalue if not issubclass(cls, ns.DiscreteDistribution) else float("nan")
    print(f"{name:16s} {s['s'].dtype!s:8s} mean {draws.mean():9.4f} vs {float(d.mean()):9.4f}   "
          f"samples(4)[0] == sample: {first.equals(s['s'], check_names=False)}   ks p {ks:.2f}")

print("\nworst relative error (excluding discrete ppf/isf):", f"{worst:.1e}")
sys.exit(0 if worst < 1e-4 else 1)  # the binomial log tails below 1e-280 lose digits
