import polars as pl, numpy as np, scipy.stats as st
from polars.plugins import register_plugin_function as reg
from nanuq_more._lib import lib_path; import nanuq_more.isoweek; LIB = str(lib_path())
def f(name, *args, elementwise=True, **kw):
    return reg(plugin_path=LIB, function_name=name, args=list(args), is_elementwise=elementwise, use_abs_path=True, kwargs=kw or None, is_deterministic=not name.endswith("Sample"))
rng = np.random.default_rng(1)
n = 200_000
df = pl.DataFrame({"x": rng.normal(0, 3, n), "q": rng.uniform(0, 1, n), "mu": rng.normal(0, 1, n), "sigma": rng.uniform(0.1, 3, n),
                   "a": rng.uniform(0.2, 8, n), "b": rng.uniform(0.2, 8, n), "u": rng.uniform(0,1,n), "k": rng.integers(0, 60, n).astype(float), "lam": rng.uniform(0.5, 50, n)})
d = {c: df[c].to_numpy() for c in df.columns}
x, q, mu, sg, a, b, u, k, lam = (d[c] for c in "x q mu sigma a b u k lam".split())
cases = {
 "normalPdf": (["x","mu","sigma"], st.norm.pdf(x, mu, sg)),
 "normalLogPdf": (["x","mu","sigma"], st.norm.logpdf(x, mu, sg)),
 "normalCdf": (["x","mu","sigma"], st.norm.cdf(x, mu, sg)),
 "normalSf": (["x","mu","sigma"], st.norm.sf(x, mu, sg)),
 "normalPpf": (["q","mu","sigma"], st.norm.ppf(q, mu, sg)),
 "lognormalPdf": (["a","mu","sigma"], st.lognorm.pdf(a, sg, scale=np.exp(mu))),
 "lognormalCdf": (["a","mu","sigma"], st.lognorm.cdf(a, sg, scale=np.exp(mu))),
 "lognormalPpf": (["q","mu","sigma"], st.lognorm.ppf(q, sg, scale=np.exp(mu))),
 "exponentialPdf": (["a","sigma"], st.expon.pdf(a, scale=1/sg)),
 "exponentialCdf": (["a","sigma"], st.expon.cdf(a, scale=1/sg)),
 "exponentialPpf": (["q","sigma"], st.expon.ppf(q, scale=1/sg)),
 "gammaPdf": (["b","a","sigma"], st.gamma.pdf(b, a, scale=1/sg)),
 "gammaCdf": (["b","a","sigma"], st.gamma.cdf(b, a, scale=1/sg)),
 "gammaSf": (["b","a","sigma"], st.gamma.sf(b, a, scale=1/sg)),
 "betaPdf": (["u","a","b"], st.beta.pdf(u, a, b)),
 "betaCdf": (["u","a","b"], st.beta.cdf(u, a, b)),
 "poissonPmf": (["k","lam"], st.poisson.pmf(k, lam)),
 "poissonCdf": (["k","lam"], st.poisson.cdf(k, lam)),
}
out = df.select(**{name: f(name, *args) for name, (args, _) in cases.items()})
for name, (_, ref) in cases.items():
    got = out[name].to_numpy()
    rel = np.abs(got - ref) / np.maximum(np.abs(ref), 1e-300)
    rel = rel[np.isfinite(ref) & (np.abs(ref) > 1e-280)]
    print(f"{name:16s} max rel err vs scipy {rel.max():.1e}  median {np.median(rel):.1e}")
# samples: moments + reproducibility
RI = pl.int_range(0, pl.len(), dtype=pl.UInt64)
smp = df.select(n=f("normalSample", RI, pl.lit(2.0), pl.lit(0.5), seed=42),
                g=f("gammaSample", RI, pl.lit(3.0), pl.lit(2.0), seed=42),
                p=f("poissonSample", RI, "lam", seed=7),
                bt=f("betaSample", RI, pl.lit(2.0), pl.lit(5.0), seed=1))
print(smp.describe())
print("poisson mean ratio", (smp["p"].to_numpy() / lam).mean())
print("ks normal", st.kstest(smp["n"], st.norm(2, .5).cdf).pvalue, "ks gamma", st.kstest(smp["g"], st.gamma(3, scale=.5).cdf).pvalue, "ks beta", st.kstest(smp["bt"], st.beta(2,5).cdf).pvalue)
again = pl.concat([df.head(1000), df.slice(1000)], rechunk=False).select(n=f("normalSample", RI, pl.lit(2.0), pl.lit(0.5), seed=42))
print("reproducible:", again["n"].equals(smp["n"]))
# nulls, broadcasting, errors
t = pl.DataFrame({"x": [0.0, None, 1.0], "s": [1.0, 2.0, None]})
print(t.with_columns(c=f("normalCdf", "x", pl.lit(0.0), "s")))
try:
    t.with_columns(c=f("normalCdf", "x", pl.lit(0.0), pl.lit(-1.0)))
except Exception as e: print("error:", type(e).__name__, str(e).splitlines()[0])
# group_by / over contexts
g = pl.DataFrame({"grp": ["a","a","b","b"], "x": [1.0, 2.0, 3.0, 4.0]})
print(g.with_columns(z=f("normalCdf", "x", pl.col("x").mean().over("grp"), pl.col("x").std().over("grp"))))
print(g.lazy().group_by("grp").agg(f("normalPdf","x",pl.lit(0.0),pl.lit(1.0))).collect())
