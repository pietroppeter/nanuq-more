## Renders both pages in one program: one compile and one link against the Polars
## library instead of one per page. Each page renders when its module is
## initialised, in import order.
##
##   nim r ... docs/all.nim             # both pages (what CI runs)
##   nim r ... docs/nim_plugins.nim     # one page, as before

{.warning[UnusedImport]: off.}
import nim_plugins, distributions
