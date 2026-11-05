"""ISO 8601 weeks as a Polars extension type, computed by a Nim plugin.

    import polars as pl
    import nanuq_more.isoweek  # registers the type and the `isoweek` namespace

    df.with_columns(week=pl.col("date").isoweek.from_date())
"""
from __future__ import annotations

import polars as pl

from nanuq_more._lib import call, expr

EXT_NAME = "nanuq.isoweek"


class IsoWeek(pl.BaseExtension):
    """An ISO week, stored as Int32 `year * 100 + week` (202645 is 2026-W45)."""

    def __init__(self) -> None:
        super().__init__(EXT_NAME, pl.Int32)

    def _string_repr(self) -> str:
        return "isoweek"


try:
    pl.register_extension_type(EXT_NAME, IsoWeek)
except ValueError:  # already registered (module reloaded)
    pass


@pl.api.register_expr_namespace("isoweek")
class IsoWeekNamespace:
    def __init__(self, e: pl.Expr) -> None:
        self._e = e

    # constructors
    def from_date(self) -> pl.Expr:
        """The ISO week a Date falls in."""
        return call("isoweek", self._e)

    def parse(self) -> pl.Expr:
        """`2026-W45`, `2026W45` or `2026-W45-3` to an IsoWeek; null if invalid."""
        return call("isoweekParse", self._e)

    def from_int(self) -> pl.Expr:
        """yyyyww integers to an IsoWeek; null if the week does not exist."""
        return call("isoweekFromInt", self._e.cast(pl.Int32))

    # on an IsoWeek column
    def format(self) -> pl.Expr:
        return call("isoweekFormat", self._e)

    def start(self) -> pl.Expr:
        """The Monday the week starts on."""
        return call("isoweekStart", self._e)

    def day(self, weekday: int | pl.Expr) -> pl.Expr:
        """The date of `weekday` (1 = Monday ... 7 = Sunday)."""
        return call("isoweekDay", self._e, expr(weekday))

    def add(self, n: int | pl.Expr) -> pl.Expr:
        """`n` weeks later."""
        return call("isoweekAdd", self._e, expr(n))

    def diff(self, other: pl.Expr | str) -> pl.Expr:
        """Whole weeks from `other` to this week."""
        return call("isoweekDiff", self._e, expr(other))

    def year(self) -> pl.Expr:
        return call("isoweekYear", self._e)

    def week(self) -> pl.Expr:
        return call("isoweekNumber", self._e)
