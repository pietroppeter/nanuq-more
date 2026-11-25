"""Checks nanuq_more.humanize against Python's humanize, value by value.

Every function, with each of its options, on tens of thousands of values: round
and random numbers of every size, ties, NaN and infinities, durations from a
microsecond to centuries, dates around today. Where humanize raises an error,
the plugin must give null. Prints one line per case and fails on any mismatch.

    python -I tests/check_humanize.py
"""
from __future__ import annotations

import datetime as dt
import math
import random
import sys

import humanize
import polars as pl

import nanuq_more.humanize as hz

rng = random.Random(20261125)


def expected(f, values, **kw):
    out = []
    for v in values:
        try:
            out.append(f(v, **kw))
        except (ValueError, OverflowError, TypeError):
            out.append(None)
    return out


failures = 0
checked = 0


def check(name: str, f_py, f_pl, series: pl.Series, py_values=None, **kw):
    global failures, checked
    py_values = series.to_list() if py_values is None else py_values
    want = expected(f_py, py_values, **kw)
    got = pl.DataFrame({"x": series}).select(f_pl("x", **kw)).to_series().to_list()
    bad = [(v, w, g) for v, w, g in zip(py_values, want, got) if w != g]
    checked += len(want)
    label = f"{name}({', '.join(f'{k}={v!r}' for k, v in kw.items())})"
    print(f"{label:60} {len(want):6} values, {len(bad)} mismatches")
    for v, w, g in bad[:5]:
        print(f"    {v!r}: humanize {w!r}, plugin {g!r}")
    failures += len(bad)


# ---------------------------------------------------------------- values

ints = sorted({0, 1, -1, 2, 9, 10, 11, 12, 13, 21, 99, 100, 101, 111, 112, 999, 1000, 1001, 1023, 1024, 1025,
               999_499, 999_500, 999_949, 999_950, 999_999, 1_000_000, 1_200_000, 12_400, 2**31, 2**53 + 1,
               10**15 - 1, 10**18, 2**63 - 1, -(2**63) + 1}
              | {sign * k * 10**e + d for sign in (1, -1) for k in (1, 5, 9, 95, 999) for e in range(0, 16)
                 for d in (-1, 0, 1)}
              | {rng.randrange(-10**e, 10**e) for e in range(1, 19) for _ in range(300)})
ints = [i for i in ints if -(2**63) < i < 2**63]
floats = ([0.0, -0.0, 0.3, 1.3, 1 / 3, 2 / 3, 0.5, 1.5, 2.5, -2.5, 0.05, 0.15, 0.25, 1234567.25, 14308.40, 1e16, 1e-5,
           1.5e-7, 123.456, 1e22, 1e30, 1e33, 1e40, 8.1e33, -2.9999999, 2.9999999, 0.999, 0.9999999, 1e-14, 220e-6,
           2e8, 1500.0, 9.995, 99.95, 999.5, 0.001, 1e-30, 1e-31, 123_000.0, 1_230_000.0, float("nan"),
           float("inf"), float("-inf")]
          + [rng.uniform(-1, 1) * 10 ** rng.uniform(-35, 40) for _ in range(6000)]
          + [round(rng.uniform(-1000, 1000), rng.randrange(0, 5)) for _ in range(3000)]
          + [rng.randrange(0, 2000) / 1000 for _ in range(1000)])
int_s = pl.Series(ints, dtype=pl.Int64)
float_s = pl.Series(floats, dtype=pl.Float64)
sizes = pl.Series([abs(i) for i in ints] + [x for x in floats if not math.isnan(x)], dtype=pl.Float64)

# ---------------------------------------------------------------- numbers

for s in (int_s, float_s):
    kind = s.dtype
    print(f"-- {kind}")
    check("naturalsize", humanize.naturalsize, hz.naturalsize, s)
    check("naturalsize", humanize.naturalsize, hz.naturalsize, s, binary=True)
    check("naturalsize", humanize.naturalsize, hz.naturalsize, s, gnu=True)
    check("naturalsize", humanize.naturalsize, hz.naturalsize, s, format="%.3f")
    check("naturalsize", humanize.naturalsize, hz.naturalsize, s, binary=True, format="%d")
    check("ordinal", humanize.ordinal, hz.ordinal, s)
    check("intcomma", humanize.intcomma, hz.intcomma, s)
    check("intcomma", humanize.intcomma, hz.intcomma, s, ndigits=2)
    check("intcomma", humanize.intcomma, hz.intcomma, s, ndigits=0)
    check("intword", humanize.intword, hz.intword, s)
    check("intword", humanize.intword, hz.intword, s, format="%0.3f")
    check("apnumber", humanize.apnumber, hz.apnumber, s)
    check("fractional", humanize.fractional, hz.fractional, s)
    check("scientific", humanize.scientific, hz.scientific, s)
    check("scientific", humanize.scientific, hz.scientific, s, precision=0)
    check("scientific", humanize.scientific, hz.scientific, s, precision=5)
    check("metric", humanize.metric, hz.metric, s)
    check("metric", humanize.metric, hz.metric, s, unit="V", precision=2)
    check("metric", humanize.metric, hz.metric, s, unit="°", precision=4)

# ---------------------------------------------------------------- time

seconds = ([0, 1, 2, 30, 59, 60, 61, 89, 90, 91, 149, 150, 151, 3599, 3600, 3601, 5399, 5400, 5401, 86399, 86400,
            86401, 45 * 86400, 46 * 86400, 364 * 86400, 365 * 86400, 366 * 86400, 400 * 86400, 730 * 86400,
            10**9, -1, -3700, -86400 * 40]
           + [rng.randrange(0, 10**e) for e in range(1, 11) for _ in range(400)])
fseconds = ([0.0, 0.0004, 0.0005, 0.0015, 0.5, 0.6, 1.5, 2.5, 59.5, 0.123456, 0.1234565, 3633.123, -0.5,
             float("nan"), float("inf"), float("-inf"), 1e15]
            + [rng.uniform(0, 10 ** rng.uniform(-7, 10)) for _ in range(4000)])
durations = [dt.timedelta(microseconds=rng.randrange(0, 10 ** rng.randrange(1, 17))) for _ in range(5000)] + [
    dt.timedelta(seconds=3633, days=2, microseconds=123000), dt.timedelta(seconds=90, microseconds=100),
    dt.timedelta(microseconds=999), dt.timedelta(microseconds=1000), dt.timedelta(days=-3, seconds=5)]
sec_s = pl.Series(seconds, dtype=pl.Int64)
fsec_s = pl.Series(fseconds, dtype=pl.Float64)
dur_s = pl.Series(durations, dtype=pl.Duration("us"))

for s in (sec_s, fsec_s, dur_s):
    print(f"-- {s.dtype}")
    for kw in ({}, {"months": False}, {"minimum_unit": "milliseconds"}, {"minimum_unit": "microseconds"}):
        check("naturaldelta", humanize.naturaldelta, hz.naturaldelta, s, **kw)
    for kw in ({}, {"minimum_unit": "microseconds"}, {"minimum_unit": "milliseconds"}, {"minimum_unit": "minutes"},
               {"minimum_unit": "hours", "format": "%0.1f"}, {"minimum_unit": "days"}, {"minimum_unit": "years"},
               {"suppress": ["days"]}, {"suppress": ["months", "years"]}, {"format": "%d"},
               {"suppress": ["seconds", "milliseconds", "microseconds"]}, {"minimum_unit": "months"}):
        check("precisedelta", humanize.precisedelta, hz.precisedelta, s, **kw)

# naturaltime: a fixed `when`, the same for both
now = dt.datetime(2026, 11, 25, 15, 30, 12, 345678)
when = {"when": now}
for s in (sec_s, fsec_s, dur_s):
    for kw in ({}, {"future": True}, {"months": False}, {"minimum_unit": "milliseconds"}):
        check("naturaltime", humanize.naturaltime, hz.naturaltime, s, **kw, **when)
moments = [now - dt.timedelta(microseconds=rng.randrange(-10**15, 10**15)) for _ in range(5000)] + [now]
mom_s = pl.Series(moments, dtype=pl.Datetime("us"))
for kw in ({}, {"months": False}, {"minimum_unit": "microseconds"}):
    check("naturaltime", humanize.naturaltime, hz.naturaltime, mom_s, **kw, **when)


# naturalday and naturaldate count from today: humanize's own (a run across midnight may fail)
today = dt.date.today()
days = [today + dt.timedelta(days=d) for d in range(-800, 800)] + [dt.date(1, 1, 1), dt.date(9999, 12, 31),
                                                                     dt.date(1600, 2, 29), dt.date(1970, 1, 1)]
day_s = pl.Series(days, dtype=pl.Date)
for fmt in ("%b %d", "%a %d %B %Y", "%Y-%m-%d (%j, %A, %u %w %y)", "%e %h %F"):
    want = expected(humanize.naturalday, days, format=fmt)
    got = pl.DataFrame({"x": day_s}).select(hz.naturalday("x", format=fmt, today=today)).to_series().to_list()
    bad = [(v, w, g) for v, w, g in zip(days, want, got) if w != g]
    checked += len(days)
    print(f"{'naturalday(format=' + repr(fmt) + ')':60} {len(days):6} values, {len(bad)} mismatches")
    for b in bad[:5]:
        print("   ", b)
    failures += len(bad)
want = expected(humanize.naturaldate, days)
got = pl.DataFrame({"x": day_s}).select(hz.naturaldate("x", today=today)).to_series().to_list()
bad = [(v, w, g) for v, w, g in zip(days, want, got) if w != g]
checked += len(days)
print(f"{'naturaldate()':60} {len(days):6} values, {len(bad)} mismatches")
for b in bad[:5]:
    print("   ", b)
failures += len(bad)

print(f"\n{checked} values checked, {failures} mismatches")
sys.exit(1 if failures else 0)
