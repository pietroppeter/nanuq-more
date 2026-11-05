import nanuq
import nanuqmore/stats_plugin

let df = newDataFrame(series("x", [9.8, 101.0, 12.1]), series("mu", [10.0, 100.0, 10.0]),
                      series("sigma", [0.5, 2.0, 0.5]))
echo df.withColumns(
  normalSf(col"x", col"mu", col"sigma").alias("tail"),
  poissonSample(lit 4.0, seed = 1).alias("draws"))
echo "scalar twin: ", normalSf(12.1, 10.0, 0.5)

