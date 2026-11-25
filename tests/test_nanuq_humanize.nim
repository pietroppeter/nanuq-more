import nanuq
import nanuqmore/humanize_plugin

let df = newDataFrame(series("bytes", [100_000'i64, 1_200_000, 3700, 1]),
                      series("x", [0.3, 1.3, 1234567.25, -2.9999999]))
echo df.withColumns(
  naturalsize(col"bytes").alias("size"),
  naturalsize(col"bytes", binary = true).alias("binary"),
  intword(col"bytes").alias("word"),
  ordinal(col"bytes").alias("ordinal"),
  intcomma(col"x").alias("commas"),
  fractional(col"x").alias("fraction"),
  metric(col"x", unit = "V").alias("volts"))
echo df.select(
  naturaldelta(col"bytes").alias("delta"),
  precisedelta(col"bytes", suppress = @["days"]).alias("precise"),
  naturaltime(col"bytes", future = true).alias("time"))

let days = newDataFrame(series("day", ["2026-11-24", "2026-11-25", "2027-06-01"]))
  .withColumns(col("day").str.toDate("%Y-%m-%d"))
echo days.withColumns(naturalday(col"day", today = lit date(2026, 11, 25)).alias("natural"),
                      naturaldelta(col("day") - col("day").min).alias("since first"))

# the plain Nim procs
echo "scalar: ", naturalsize(Num(i: 100_000), SizeOpts()).get, ", ",
     intword(Num(i: 1_200_000), IntwordOpts()), ", ",
     naturaldelta(TimeValue(kind: tkDuration, us: 3_700_000_000), DeltaOpts()).get
