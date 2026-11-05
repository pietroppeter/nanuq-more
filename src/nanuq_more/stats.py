"""Vectorized probability distributions, computed by a Nim plugin.

Parameters are numbers, column names or expressions, so each row can carry
its own distribution:

    from nanuq_more.stats import Normal
    df.with_columns(p=Normal(mu="mu", sigma="sigma").sf("x"))
"""
from __future__ import annotations

import polars as pl

from nanuq_more._lib import call, expr

ROW_INDEX = pl.int_range(0, pl.len(), dtype=pl.UInt64)


class _Distribution:
    _name: str
    _methods: tuple[str, ...] = ()

    def __init__(self, *params) -> None:
        self._params = [expr(p) for p in params]

    def _value(self, method: str, x) -> pl.Expr:
        if method not in self._methods:
            msg = f"{type(self).__name__} has no {method}"
            raise AttributeError(msg)
        return call(self._name + method, expr(x), *self._params)

    def pdf(self, x) -> pl.Expr:
        return self._value("Pdf", x)

    def pmf(self, x) -> pl.Expr:
        return self._value("Pmf", x)

    def logpdf(self, x) -> pl.Expr:
        return self._value("LogPdf", x)

    def cdf(self, x) -> pl.Expr:
        return self._value("Cdf", x)

    def sf(self, x) -> pl.Expr:
        return self._value("Sf", x)

    def ppf(self, q) -> pl.Expr:
        return self._value("Ppf", q)

    def sample(self, seed: int = 0, row_key: pl.Expr = ROW_INDEX) -> pl.Expr:
        """One draw per row, keyed on (seed, row_key): reruns repeat it."""
        return call(self._name + "Sample", row_key, *self._params, deterministic=False, seed=seed)


class Normal(_Distribution):
    _name, _methods = "normal", ("Pdf", "LogPdf", "Cdf", "Sf", "Ppf")

    def __init__(self, mu=0.0, sigma=1.0) -> None:
        super().__init__(mu, sigma)


class LogNormal(_Distribution):
    _name, _methods = "lognormal", ("Pdf", "Cdf", "Ppf")

    def __init__(self, mu=0.0, sigma=1.0) -> None:
        super().__init__(mu, sigma)


class Exponential(_Distribution):
    _name, _methods = "exponential", ("Pdf", "Cdf", "Sf", "Ppf")

    def __init__(self, rate=1.0) -> None:
        super().__init__(rate)


class Uniform(_Distribution):
    _name, _methods = "uniform", ("Pdf", "Cdf")

    def __init__(self, low=0.0, high=1.0) -> None:
        super().__init__(low, high)


class Gamma(_Distribution):
    _name, _methods = "gamma", ("Pdf", "Cdf", "Sf")

    def __init__(self, shape, rate=1.0) -> None:
        super().__init__(shape, rate)


class Beta(_Distribution):
    _name, _methods = "beta", ("Pdf", "Cdf")

    def __init__(self, alpha, beta) -> None:
        super().__init__(alpha, beta)


class Poisson(_Distribution):
    _name, _methods = "poisson", ("Pmf", "Cdf")

    def __init__(self, lam) -> None:
        super().__init__(lam)
