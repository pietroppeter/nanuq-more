import time, numpy as np, polars as pl, polars_stats as ps, nanuq_more.stats as nm
N=10_000_000; rng=np.random.default_rng(0)
lf = pl.DataFrame({"x": rng.normal(0,2,N), "mu": rng.normal(0,1,N), "sigma": rng.uniform(.5,2,N)}).lazy()
def best(f):
    f(); return min((lambda t: (f(), time.perf_counter()-t)[1])(time.perf_counter()) for _ in range(5))
for eng in ["in-memory", "streaming"]:
    print(eng, "nim %.0f ms" % (1e3*best(lambda: lf.select(nm.Normal("mu","sigma").cdf("x")).collect(engine=eng))),
          "rust %.0f ms" % (1e3*best(lambda: lf.select(ps.Normal(mu="mu",sigma="sigma").cdf("x")).collect(engine=eng))))
