"""Locate the Nim-built plugin library and register its functions."""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

import polars as pl
from polars.plugins import register_plugin_function

_HERE = Path(__file__).parent


@lru_cache(maxsize=1)
def lib_path() -> Path:
    for p in sorted(_HERE.iterdir()):
        if p.name.startswith("plugins") and p.suffix in (".so", ".pyd", ".dylib"):
            return p
    msg = f"the nanuq-more plugin library is not built in {_HERE}"
    raise FileNotFoundError(msg)


def call(name: str, *args: pl.Expr | str, deterministic: bool = True, **kwargs) -> pl.Expr:
    """`name` from the Nim library, elementwise on `args` (strings are column names)."""
    return register_plugin_function(
        plugin_path=lib_path(),
        function_name=name,
        args=[pl.col(a) if isinstance(a, str) else a for a in args],
        kwargs=kwargs or None,
        is_elementwise=True,
        is_deterministic=deterministic,
        use_abs_path=True,
    )


def expr(x) -> pl.Expr:
    """A column name, an expression or a number, as an expression."""
    if isinstance(x, pl.Expr):
        return x
    if isinstance(x, str):
        return pl.col(x)
    return pl.lit(x, dtype=pl.Float64) if isinstance(x, float) else pl.lit(x)
