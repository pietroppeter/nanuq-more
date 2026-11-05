import nanuq
import nanuqmore/isoweek_plugin

let df = newDataFrame(series("day", ["2026-11-05", "2027-01-01", "2020-12-31", "2021-01-04"]))
  .withColumns(col("day").str.toDate("%Y-%m-%d"))
let w = df.withColumns(isoweek(col"day").alias("week"))
echo w
echo w.schema
echo w.withColumns(isoweekFormat(isoweekAdd(col"week", lit 8)).alias("in8"),
                   isoweekStart(col"week").alias("monday"))
echo w.groupBy("week").agg(len().alias("n")).sort("week")
echo w.filter(col("week") == isoweekParse(lit "2020-W53"))
