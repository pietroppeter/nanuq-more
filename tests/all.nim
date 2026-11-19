## The Nim tests in one program (one compile, one link against the Polars library):
##   nim r -d:nanuqLib=prebuilt --path:../nanuq/src --path:src tests/all.nim

{.warning[UnusedImport]: off.}
import test_nanuq_isoweek, test_nanuq_stats
