import polars as pl, datetime as dt
from polars.plugins import register_plugin_function as reg
from nanuq_more._lib import lib_path; import nanuq_more.isoweek; LIB = str(lib_path())
f = lambda name, *args, **kw: reg(plugin_path=LIB, function_name=name, args=list(args), is_elementwise=True, use_abs_path=True, kwargs=kw or None)
df = pl.DataFrame({"d": pl.date_range(dt.date(2020,12,26), dt.date(2021,1,12), eager=True)})
df = df.with_columns(w=f("isoweek", "d"))
print(df.with_columns(s=f("isoweekFormat","w"), start=f("isoweekStart","w"), plus=f("isoweekFormat", f("isoweekAdd","w", pl.lit(53))), pol=pl.col("d").dt.week(), poly=pl.col("d").dt.iso_year()).head(12))
print(df.schema)
s = pl.DataFrame({"s": ["2026-W45", "2026W01", "2026-W53", "2020-W53", "junk", None]})
print(s.with_columns(w=f("isoweekParse","s")).with_columns(back=f("isoweekFormat","w"), y=f("isoweekYear","w"), n=f("isoweekNumber","w"), thu=f("isoweekDay","w", pl.lit(4))))
# validate against Python's isocalendar on a big range
big = pl.DataFrame({"d": pl.date_range(dt.date(1600,1,1), dt.date(2400,12,31), eager=True)})
out = big.with_columns(s=f("isoweekFormat", f("isoweek","d")))
exp = [f"{d.isocalendar()[0]}-W{d.isocalendar()[1]:02d}" for d in big["d"]]
print("dates checked:", len(exp), "mismatches:", sum(a!=b for a,b in zip(out["s"], exp)))
print(df.group_by("w").agg(pl.len()).sort("w"))
