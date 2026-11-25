"""Python's `humanize`, vectorized: a Polars plugin written in Nim.

The same functions, arguments and English text as `humanize` (4.17), on whole
columns. Each takes an expression or a column name; the rest are keyword
arguments, as in humanize.

    import polars as pl
    import nanuq_more.humanize as hz

    df.with_columns(size=hz.naturalsize("bytes"), age=hz.naturaltime("created"))
    df.with_columns(pl.col("bytes").humanize.naturalsize(binary=True))

Values humanize would raise an error on (an overflowing number of seconds,
a NaN file size) give null.
"""
from __future__ import annotations

import datetime as dt
from collections.abc import Iterable

import polars as pl

from nanuq_more._lib import call, expr

IntoExpr = "pl.Expr | str"


def _now(when: dt.datetime | pl.Expr | str | None) -> pl.Expr:
    if when is None:
        return pl.lit(dt.datetime.now(), dtype=pl.Datetime("us"))  # naive local time, as humanize
    if isinstance(when, dt.datetime):
        return pl.lit(when, dtype=pl.Datetime("us"))
    if isinstance(when, dt.date):
        return pl.lit(when, dtype=pl.Date)
    return expr(when)


def _today(today: dt.date | pl.Expr | str | None) -> pl.Expr:
    if today is None:
        return pl.lit(dt.date.today(), dtype=pl.Date)
    if isinstance(today, dt.date):
        return pl.lit(today, dtype=pl.Date)
    return expr(today)


# ---------------------------------------------------------------- numbers and sizes

def naturalsize(value: IntoExpr, binary: bool = False, gnu: bool = False, format: str = "%.1f") -> pl.Expr:
    """Bytes as a file size: '3.0 MB', with `binary` '2.9 KiB', with `gnu` '2.9K'."""
    return call("naturalsize", expr(value), binary=binary, gnu=gnu, format=format)


def ordinal(value: IntoExpr, gender: str = "male") -> pl.Expr:
    """'1st', '2nd', '3rd', '11th', '101st'."""
    return call("ordinal", expr(value), gender=gender)


def intcomma(value: IntoExpr, ndigits: int | None = None) -> pl.Expr:
    """Commas every three digits: '1,000,000', '1,234.55' (with `ndigits=2`)."""
    return call("intcomma", expr(value), ndigits=-1 if ndigits is None else ndigits)


def intword(value: IntoExpr, format: str = "%.1f") -> pl.Expr:
    """Large numbers in words: '1.2 million'."""
    return call("intword", expr(value), format=format)


def apnumber(value: IntoExpr) -> pl.Expr:
    """Associated Press style: 'five', but '10'."""
    return call("apnumber", expr(value))


def fractional(value: IntoExpr) -> pl.Expr:
    """'1/3', '1 3/10' (denominators up to 1000)."""
    return call("fractional", expr(value))


def scientific(value: IntoExpr, precision: int = 2) -> pl.Expr:
    """'3.00 x 10⁻¹'."""
    return call("scientific", expr(value), precision=precision)


def metric(value: IntoExpr, unit: str = "", precision: int = 3) -> pl.Expr:
    """An SI prefix: '1.50 kV', '220 μF'."""
    return call("metric", expr(value), unit=unit, precision=precision)


# ---------------------------------------------------------------- time

def naturaldelta(value: IntoExpr, months: bool = True, minimum_unit: str = "seconds") -> pl.Expr:
    """A Duration or a number of seconds in words: 'an hour', '3 days', '1 year, 2 months'."""
    return call("naturaldelta", expr(value), months=months, minimumUnit=minimum_unit)


def naturaltime(value: IntoExpr, future: bool = False, months: bool = True, minimum_unit: str = "seconds",
                when: dt.datetime | pl.Expr | str | None = None) -> pl.Expr:
    """'an hour ago', '3 days from now', 'now'.

    Datetimes count from `when` (default: now, naive local time, as humanize);
    `when` can also be a column, for the time between two columns. A Duration is
    in the past when positive; a number of seconds is unless `future`.
    """
    return call("naturaltime", expr(value), _now(when), deterministic=when is not None,
                future=future, months=months, minimumUnit=minimum_unit)


def naturalday(value: IntoExpr, format: str = "%b %d", today: dt.date | pl.Expr | str | None = None) -> pl.Expr:
    """'today', 'tomorrow', 'yesterday', else the date in `format` ('Nov 25')."""
    return call("naturalday", expr(value), _today(today), deterministic=today is not None, format=format)


def naturaldate(value: IntoExpr, today: dt.date | pl.Expr | str | None = None) -> pl.Expr:
    """As `naturalday`, with the year for dates about five months away or more."""
    return call("naturaldate", expr(value), _today(today), deterministic=today is not None)


def precisedelta(value: IntoExpr, minimum_unit: str = "seconds", suppress: Iterable[str] = (),
                 format: str = "%0.2f") -> pl.Expr:
    """'2 days, 1 hour and 33.12 seconds': exact, down to `minimum_unit`."""
    return call("precisedelta", expr(value), minimumUnit=minimum_unit, suppress=list(suppress), format=format)


@pl.api.register_expr_namespace("humanize")
class HumanizeNamespace:
    """`pl.col("x").humanize.naturalsize()` and the rest, as the functions above."""

    def __init__(self, e: pl.Expr) -> None:
        self._e = e

    def __getattr__(self, name: str):
        f = _FUNCTIONS.get(name)
        if f is None:
            raise AttributeError(name)
        return lambda *args, **kwargs: f(self._e, *args, **kwargs)


__all__ = ["apnumber", "fractional", "intcomma", "intword", "metric", "naturaldate", "naturalday",
           "naturaldelta", "naturalsize", "naturaltime", "ordinal", "precisedelta", "scientific"]
_FUNCTIONS = {name: globals()[name] for name in __all__}
