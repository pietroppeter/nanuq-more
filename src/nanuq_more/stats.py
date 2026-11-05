"""Vectorized probability distributions, computed by a Nim plugin.

The same classes, parameters and methods as polars-stats (and so scipy):
parameters are numbers, column names or expressions, so each row can carry
its own distribution.

    from nanuq_more.stats import Normal
    df.with_columns(p=Normal(mu="mu", sigma="sigma").sf("x"))
"""
from __future__ import annotations

import polars as pl

from nanuq_more._lib import call, expr

ROW_INDEX = pl.int_range(0, pl.len(), dtype=pl.UInt64)


def _param(x, integer: bool) -> pl.Expr:
    if integer and isinstance(x, int) and not isinstance(x, bool):
        return pl.lit(x, dtype=pl.Int64)
    if not integer and isinstance(x, (int, float)) and not isinstance(x, bool):
        return pl.lit(float(x), dtype=pl.Float64)
    return expr(x)


class _Distribution:
    _name: str
    _params: tuple[str, ...]
    _integer: tuple[str, ...] = ()

    def __init__(self, *args, **kwargs) -> None:
        values = dict(zip(self._params, args)) | kwargs
        self._args = [_param(values[p], p in self._integer) for p in self._params]
        self._repr = ", ".join(f"{p}={values[p]!r}" for p in self._params)

    def __repr__(self) -> str:
        return f"{type(self).__name__}({self._repr})"

    def _f(self, method: str, *first: pl.Expr, **kw) -> pl.Expr:
        return call(self._name + method, *first, *self._args, **kw)

    def cdf(self, value) -> pl.Expr:
        return self._f("Cdf", expr(value))

    def log_cdf(self, value) -> pl.Expr:
        return self._f("LogCdf", expr(value))

    def sf(self, value) -> pl.Expr:
        return self._f("Sf", expr(value))

    def log_sf(self, value) -> pl.Expr:
        return self._f("LogSf", expr(value))

    def ppf(self, quantile) -> pl.Expr:
        return self._f("Ppf", expr(quantile))

    def isf(self, quantile) -> pl.Expr:
        return self._f("Isf", expr(quantile))

    def mean(self) -> pl.Expr:
        return self._f("Mean")

    def variance(self) -> pl.Expr:
        return self._f("Variance")

    def std(self) -> pl.Expr:
        return self._f("Std")

    def median(self) -> pl.Expr:
        return self._f("Median")

    def entropy(self) -> pl.Expr:
        return self._f("Entropy")

    def _draw_name(self, default: str) -> str:
        # As polars-stats: named after the first parameter column, else after the method.
        name = self._args[0].meta.output_name(raise_if_undetermined=False)
        return default if name in (None, "literal") else name

    def sample(self, seed: int = 0, row_key: pl.Expr = ROW_INDEX) -> pl.Expr:
        """One draw per row, keyed on (seed, row_key): reruns repeat it."""
        return call(self._name + "Sample", row_key.alias(self._draw_name("sample")), *self._args,
                    deterministic=False, seed=seed)

    def samples(self, size: int, seed: int = 0, row_key: pl.Expr = ROW_INDEX) -> pl.Expr:
        """`size` draws per row as an Array; `samples(1)` matches `sample`."""
        return call(self._name + "Samples", row_key.alias(self._draw_name("samples")), *self._args,
                    deterministic=False, seed=seed, size=size)


class ContinuousDistribution(_Distribution):
    def pdf(self, value) -> pl.Expr:
        return self._f("Pdf", expr(value))

    def log_pdf(self, value) -> pl.Expr:
        return self._f("LogPdf", expr(value))


class DiscreteDistribution(_Distribution):
    def pmf(self, value) -> pl.Expr:
        return self._f("Pmf", expr(value))

    def log_pmf(self, value) -> pl.Expr:
        return self._f("LogPmf", expr(value))


def _dist(cls_name: str, base: type, name: str, params: str, integer: str = "", defaults: dict | None = None, doc: str = ""):
    names = tuple(params.split())

    def __init__(self, *args, **kwargs):
        for k, v in (defaults or {}).items():
            if k not in kwargs and names.index(k) >= len(args):
                kwargs[k] = v
        _Distribution.__init__(self, *args, **kwargs)

    return type(cls_name, (base,), {"_name": name, "_params": names, "_integer": tuple(integer.split()),
                                    "__init__": __init__, "__doc__": doc})


Normal = _dist("Normal", ContinuousDistribution, "normal", "mu sigma", defaults={"mu": 0.0, "sigma": 1.0},
               doc="Normal(mu=0, sigma=1), scipy.stats.norm(loc=mu, scale=sigma).")
LogNormal = _dist("LogNormal", ContinuousDistribution, "lognormal", "mu sigma", defaults={"mu": 0.0, "sigma": 1.0},
                  doc="LogNormal(mu=0, sigma=1): exp of a Normal(mu, sigma).")
Exponential = _dist("Exponential", ContinuousDistribution, "exponential", "rate", doc="Exponential(rate).")
Uniform = _dist("Uniform", ContinuousDistribution, "uniform", "min max", doc="Uniform(min, max) on [min, max].")
Gamma = _dist("Gamma", ContinuousDistribution, "gamma", "shape rate", doc="Gamma(shape, rate).")
Beta = _dist("Beta", ContinuousDistribution, "beta", "a b", doc="Beta(a, b) on [0, 1].")
Cauchy = _dist("Cauchy", ContinuousDistribution, "cauchy", "loc scale", doc="Cauchy(loc, scale); mean and variance are NaN.")
Pareto = _dist("Pareto", ContinuousDistribution, "pareto", "scale shape", doc="Pareto(scale, shape) on [scale, inf).")
Weibull = _dist("Weibull", ContinuousDistribution, "weibull", "shape scale", doc="Weibull(shape, scale).")
Bernoulli = _dist("Bernoulli", DiscreteDistribution, "bernoulli", "p", doc="Bernoulli(p); samples are Boolean.")
Binomial = _dist("Binomial", DiscreteDistribution, "binomial", "n p", integer="n", doc="Binomial(n, p).")
Poisson = _dist("Poisson", DiscreteDistribution, "poisson", "rate", doc="Poisson(rate).")
Geometric = _dist("Geometric", DiscreteDistribution, "geometric", "p",
                  doc="Geometric(p): trials up to and including the first success (support 1, 2, ...).")
DiscreteUniform = _dist("DiscreteUniform", DiscreteDistribution, "discreteuniform", "min max", integer="min max",
                        doc="DiscreteUniform(min, max): every integer in [min, max].")

__all__ = ["Bernoulli", "Beta", "Binomial", "Cauchy", "DiscreteUniform", "Exponential", "Gamma", "Geometric",
           "LogNormal", "Normal", "Pareto", "Poisson", "Uniform", "Weibull"]
