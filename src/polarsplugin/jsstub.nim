## The JavaScript side of polarsplugin: the plugin types, the random streams
## and a `polarsExpr` that changes nothing, so a plugin module's procs compile
## to JavaScript as plain functions.

import std/[macros, options, tables]
import rowrng
export options, tables, rowrng

type
  Date32* = distinct int32
  StrView* = string
  ShortStr* = string
  Size* = distinct int
  Kwargs* = Table[string, string]
  PluginError* = object of CatchableError

proc `==`*(a, b: Date32): bool {.borrow.}
proc `<`*(a, b: Date32): bool {.borrow.}

macro polarsExpr*(fn: untyped): untyped = fn
template nanuqBindings*() = discard
