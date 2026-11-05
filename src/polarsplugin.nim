## polarsplugin: write Polars expression plugins in Nim.
##
## Natively (see `polarsplugin/native`) the `polarsExpr` macro turns a scalar
## Nim proc into a Polars plugin function. On the JavaScript backend there is
## no Polars to plug into: `polarsExpr` leaves the proc as it is, so the same
## module (its math) also runs in a browser.

when defined(js):
  import polarsplugin/jsstub
  export jsstub
else:
  import polarsplugin/native
  export native
