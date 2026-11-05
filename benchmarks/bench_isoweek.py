"""nanuq-more isoweek (Nim plugin) vs iso-week-date (Polars string expressions).

    uv run --with "iso-week-date[polars]" python benchmarks/bench_isoweek.py [rows]
"""
import datetime as dt, json, sys, time
import numpy as np
import polars as pl
from iso_week_date import IsoWeek as PyIsoWeek
from iso_week_date.polars_utils import datetime_to_isoweek, isoweek_to_datetime, is_isoweek_series
import nanuq_more.isoweek  # noqa: F401  (the .isoweek namespace)

N = int(sys.argv[1]) if len(sys.argv) > 1 else 10_000_000
rng = np.random.default_rng(0)
days = pl.Series("day", rng.integers(0, 40_000, N)).cast(pl.Date)
df = pl.DataFrame({"day": days}).with_columns(s=datetime_to_isoweek(pl.col("day")),
                                              n=pl.Series(rng.integers(-60, 60, N)))
df = df.with_columns(w=pl.col("s").isoweek.parse())

def best(f, reps=5):
    f(); ts = []
    for _ in range(reps):
        t = time.perf_counter(); f(); ts.append(time.perf_counter() - t)
    return min(ts)

cases = [
    ("date -> '2026-W45' string",
     lambda: df.select(pl.col("day").isoweek.from_date().isoweek.format()),
     lambda: df.select(datetime_to_isoweek(pl.col("day")))),
    ("date -> week (Nim: the isoweek type, no string)",
     lambda: df.select(pl.col("day").isoweek.from_date()), None),
    ("'2026-W45' -> Monday date",
     lambda: df.select(pl.col("s").isoweek.parse().isoweek.start()),
     lambda: df.select(isoweek_to_datetime(pl.col("s")))),
    ("validate '2026-W45' strings",
     lambda: df.select(pl.col("s").isoweek.parse().is_not_null().all()),
     lambda: df.select(is_isoweek_series(pl.col("s")))),
    ("add n weeks (per row)",
     lambda: df.select(pl.col("w").isoweek.add(pl.col("n"))),
     lambda: df.select(datetime_to_isoweek(isoweek_to_datetime(pl.col("s")) + pl.duration(weeks=pl.col("n"))))),
    ("weeks between two columns",
     lambda: df.select(pl.col("w").isoweek.diff(pl.col("w").isoweek.add(pl.col("n")))),
     lambda: df.select(((isoweek_to_datetime(pl.col("s")) - isoweek_to_datetime(datetime_to_isoweek(
         isoweek_to_datetime(pl.col("s")) + pl.duration(weeks=pl.col("n"))))).dt.total_days() // 7))),
]
rows = []
for name, nim, iwd in cases:
    r = {"case": name, "nim": best(nim), "iwd": best(iwd) if iwd else None}
    rows.append(r)
    print(f"{name:48s} nim {r['nim']*1e3:7.0f} ms" + (f"   iso-week-date {r['iwd']*1e3:7.0f} ms  ({r['iwd']/r['nim']:.1f}x)" if iwd else ""))

# the scalar class through map_elements, on 1/100 of the rows
small = df.head(N // 100)
t_py = best(lambda: small.select(pl.col("s").map_elements(lambda s: str(PyIsoWeek(s) + 3), return_dtype=pl.String)), reps=1)
t_nim = best(lambda: small.select(pl.col("w").isoweek.add(3).isoweek.format()))
print(f"{'IsoWeek(s) + 3 via map_elements, ' + str(N // 100) + ' rows':48s} nim {t_nim*1e3:7.0f} ms   iso-week-date {t_py*1e3:7.0f} ms  ({t_py/t_nim:.0f}x)")
rows.append({"case": f"IsoWeek(s) + 3, map_elements, {N // 100} rows", "nim": t_nim, "iwd": t_py})

# same answers?
chk = df.head(200_000).with_columns(a=pl.col("day").isoweek.from_date().isoweek.format(), b=datetime_to_isoweek(pl.col("day")),
                                    c=pl.col("s").isoweek.parse().isoweek.start(), d=isoweek_to_datetime(pl.col("s")))
print("same results:", chk["a"].equals(chk["b"]), chk["c"].equals(chk["d"]))
json.dump({"rows": N, "polars": pl.__version__, "results": rows},
          open(sys.argv[2] if len(sys.argv) > 2 else "bench_isoweek.json", "w"), indent=1)
