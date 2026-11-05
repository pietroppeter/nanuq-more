## polarsplugin: write Polars expression plugins in Nim.
##
## A Polars expression plugin is a shared library with a few C functions that
## take and return Arrow arrays (see `polarsplugin/arrow`). Python Polars loads
## it with `register_plugin_function`, Nanuq with `pluginFunction`. The
## `polarsExpr` macro turns a scalar Nim proc into such a function:
##
## ```nim
## proc normalCdf*(x, mu, sigma: float): float {.polarsExpr.} =
##   0.5 * erfc((mu - x) / (sigma * sqrt(2.0)))
## ```
##
## exports `_polars_plugin_normalCdf` (the kernel: a loop over the rows that
## skips nulls and broadcasts length-1 inputs) and `_polars_plugin_field_normalCdf`
## (the output field), and leaves `normalCdf` an ordinary Nim proc.

import std/[macros, options, typetraits, tables, hashes, compilesettings, os, strutils]
import arrow, pickle, rowrng
export arrow, pickle, rowrng, options, tables, os

type
  Date32* = distinct int32     ## days since 1970-01-01, Polars' Date
  StrView* = object            ## a string value, borrowed from the input
    p*: ptr UncheckedArray[char]
    n*: int
  ShortStr* = object           ## a string of up to 12 bytes, returned without allocating
    len*: int
    data*: array[12, char]
  Size* = distinct int         ## the `size` keyword argument: values per row of an Array output
  PluginError* = object of CatchableError

proc `==`*(a, b: Date32): bool {.borrow.}
proc `<`*(a, b: Date32): bool {.borrow.}
proc `$`*(s: StrView): string =
  result = newString(s.n)
  if s.n > 0: copyMem(result[0].addr, s.p, s.n)
proc len*(s: StrView): int = s.n
proc add*(s: var ShortStr, c: char) {.inline.} =
  s.data[s.len] = c; inc s.len
proc `$`*(s: ShortStr): string =
  result = newString(s.len)
  for i in 0 ..< s.len: result[i] = s.data[i]
proc `[]`*(s: StrView, i: int): char = s.p[i]

# ---------------------------------------------------------------- errors

var lastError {.threadvar.}: string

proc polarsPluginGetLastErrorMessage(): cstring
    {.exportc: "_polars_plugin_get_last_error_message", dynlib, cdecl.} =
  lastError.cstring

proc polarsPluginGetVersion(): uint32 {.exportc: "_polars_plugin_get_version", dynlib, cdecl.} =
  (0'u32 shl 16) or 1'u32    # polars-ffi 0.1: field functions take kwargs

proc setError*(msg: string) = lastError = msg

template guarded*(body: untyped) =
  try:
    body
  except Exception as e:
    setError(e.msg)

# ---------------------------------------------------------------- dtypes

template storageOf*(T: typedesc): typedesc =
  when T is distinct: distinctBase(T) else: T

proc arrowFormat*(T: typedesc): string =
  ## Arrow format string of the Polars dtype a Nim type maps to.
  when T is Date32: "tdD"
  elif T is distinct: arrowFormat(distinctBase(T))
  elif T is float64: "g"
  elif T is float32: "f"
  elif T is int64 or T is int: "l"
  elif T is int32: "i"
  elif T is int16: "s"
  elif T is int8: "c"
  elif T is uint64: "L"
  elif T is uint32: "I"
  elif T is uint16: "S"
  elif T is uint8: "C"
  elif T is bool: "b"
  elif T is string or T is StrView or T is ShortStr: "vu"
  else: {.error: "no Polars dtype for " & $T.}

proc arrowExtension*(T: typedesc): string =
  ## Overload for a distinct type to make it a Polars extension type.
  ""

# ---------------------------------------------------------------- input columns

type
  Col*[T] = object
    ## One input, as Nim values of type T: zero-copy when the Arrow type
    ## already is T's storage, converted once otherwise.
    name*: string
    len*: int
    stride: int                        # 0 broadcasts a length-1 input
    data: ptr UncheckedArray[storageOf(T)]
    valid: ptr UncheckedArray[uint8]   # nil: no nulls
    voff, doff: int
    ownedData: seq[storageOf(T)]
    ownedValid: seq[uint8]

proc bit(p: ptr UncheckedArray[uint8], i: int): bool {.inline.} =
  ((p[i shr 3] shr (i and 7)) and 1) == 1

proc isValid*[T](c: Col[T], i: int): bool {.inline.} =
  c.valid.isNil or bit(c.valid, c.voff + i * c.stride)

proc `[]`*[T](c: Col[T], i: int): T {.inline.} =
  T(c.data[c.doff + i * c.stride])

proc fmtOf(e: ptr SeriesExport): string = $e.field.format

proc numericAt(fmt: string, a: ptr ArrowArray, i: int): float64 =
  let buf = a.buffers[1]
  let j = a.offset.int + i
  case fmt
  of "g": cast[ptr UncheckedArray[float64]](buf)[j]
  of "f": cast[ptr UncheckedArray[float32]](buf)[j].float64
  of "l": cast[ptr UncheckedArray[int64]](buf)[j].float64
  of "i", "tdD": cast[ptr UncheckedArray[int32]](buf)[j].float64
  of "s": cast[ptr UncheckedArray[int16]](buf)[j].float64
  of "c": cast[ptr UncheckedArray[int8]](buf)[j].float64
  of "L": cast[ptr UncheckedArray[uint64]](buf)[j].float64
  of "I": cast[ptr UncheckedArray[uint32]](buf)[j].float64
  of "S": cast[ptr UncheckedArray[uint16]](buf)[j].float64
  of "C": cast[ptr UncheckedArray[uint8]](buf)[j].float64
  of "b": (if bit(cast[ptr UncheckedArray[uint8]](buf), j): 1.0 else: 0.0)
  else: raise newException(PluginError, "expected a numeric column, got Arrow format '" & fmt & "'")

proc intAt(fmt: string, a: ptr ArrowArray, i: int): int64 =
  let buf = a.buffers[1]
  let j = a.offset.int + i
  case fmt
  of "l": cast[ptr UncheckedArray[int64]](buf)[j]
  of "i", "tdD": cast[ptr UncheckedArray[int32]](buf)[j].int64
  of "s": cast[ptr UncheckedArray[int16]](buf)[j].int64
  of "c": cast[ptr UncheckedArray[int8]](buf)[j].int64
  of "L": cast[ptr UncheckedArray[uint64]](buf)[j].int64
  of "I": cast[ptr UncheckedArray[uint32]](buf)[j].int64
  of "S": cast[ptr UncheckedArray[uint16]](buf)[j].int64
  of "C": cast[ptr UncheckedArray[uint8]](buf)[j].int64
  else: raise newException(PluginError, "expected an integer column, got Arrow format '" & fmt & "'")

proc strAt(fmt: string, a: ptr ArrowArray, i: int): StrView =
  let j = a.offset.int + i
  case fmt
  of "u":
    let offs = cast[ptr UncheckedArray[int32]](a.buffers[1])
    let o = offs[j].int
    StrView(p: cast[ptr UncheckedArray[char]](cast[uint](a.buffers[2]) + o.uint), n: offs[j + 1].int - o)
  of "U":
    let offs = cast[ptr UncheckedArray[int64]](a.buffers[1])
    let o = offs[j].int
    StrView(p: cast[ptr UncheckedArray[char]](cast[uint](a.buffers[2]) + o.uint), n: offs[j + 1].int - o)
  of "vu", "vz":
    # Arrow string views: 16 bytes, inline up to 12 bytes, else (prefix, buffer, offset).
    let v = cast[ptr UncheckedArray[int32]](cast[uint](a.buffers[1]) + uint(16 * j))
    let n = v[0].int
    if n <= 12:
      StrView(p: cast[ptr UncheckedArray[char]](v[1].addr), n: n)
    else:
      let buf = a.buffers[2 + v[2].int]
      StrView(p: cast[ptr UncheckedArray[char]](cast[uint](buf) + v[3].uint32.uint), n: n)
  else: raise newException(PluginError, "expected a string column, got Arrow format '" & fmt & "'")

proc readCol*[T](e: ptr SeriesExport): Col[T] =
  type S = storageOf(T)
  result.name = $e.field.name
  let fmt = fmtOf(e)
  var total = 0
  for k in 0 ..< e.len.int: total += e.arrays[k].length.int
  result.len = total
  result.stride = (if total == 1: 0 else: 1)
  when T isnot StrView and T isnot bool:
    if e.len == 1 and fmt == arrowFormat(T):          # zero-copy
      let a = e.arrays[0]
      result.data = cast[ptr UncheckedArray[S]](a.buffers[1])
      result.doff = a.offset.int
      if a.nullCount != 0 and not a.buffers[0].isNil:
        result.valid = cast[ptr UncheckedArray[uint8]](a.buffers[0])
        result.voff = a.offset.int
      return
  result.ownedData = newSeq[S](total)
  var anyNull = false
  for k in 0 ..< e.len.int:
    if e.arrays[k].nullCount != 0: anyNull = true
  if anyNull: result.ownedValid = newSeq[uint8]((total + 7) div 8)
  var at = 0
  for k in 0 ..< e.len.int:
    let a = e.arrays[k]
    let vb = cast[ptr UncheckedArray[uint8]](a.buffers[0])
    for i in 0 ..< a.length.int:
      if anyNull and (a.nullCount == 0 or vb.isNil or bit(vb, a.offset.int + i)):
        result.ownedValid[at shr 3] = result.ownedValid[at shr 3] or uint8(1 shl (at and 7))
      if a.nullCount == 0 or vb.isNil or bit(vb, a.offset.int + i):
        when T is StrView: result.ownedData[at] = strAt(fmt, a, i)
        elif S is SomeFloat: result.ownedData[at] = S(numericAt(fmt, a, i))
        elif S is bool: result.ownedData[at] = numericAt(fmt, a, i) != 0
        elif S is SomeInteger: result.ownedData[at] = S(intAt(fmt, a, i))
        else: {.error: "cannot read " & $T.}
      inc at
  if total > 0: result.data = cast[ptr UncheckedArray[S]](result.ownedData[0].addr)
  if anyNull: result.valid = cast[ptr UncheckedArray[uint8]](result.ownedValid[0].addr)

# ---------------------------------------------------------------- output columns

type
  Out*[T] = object
    len: int
    data: pointer                     # malloc'ed, handed to Polars
    valid: ptr UncheckedArray[uint8]  # malloc'ed lazily on the first null
    nulls: int
    chars: seq[char]                  # strings longer than 12 bytes

proc initOut*[T](n: int): Out[T] =
  result.len = n
  when T is string or T is ShortStr:
    result.data = allocC0(16 * n)     # Arrow string views; a null or empty view is all zeros
  elif T is bool:
    result.data = allocC0((n + 7) div 8)
  else:
    result.data = allocC(n * sizeof(storageOf(T)))

proc setNull*[T](o: var Out[T], i: int) =
  if o.valid.isNil:
    o.valid = cast[ptr UncheckedArray[uint8]](allocC((o.len + 7) div 8))
    for k in 0 ..< (o.len + 7) div 8: o.valid[k] = 0xff
  o.valid[i shr 3] = o.valid[i shr 3] and not uint8(1 shl (i and 7))
  inc o.nulls

proc setView[T](o: var Out[T], i: int, p: ptr UncheckedArray[char], n: int) {.inline.} =
  # A view is (int32 len, 12 bytes inline) or (int32 len, 4-byte prefix,
  # int32 buffer index, int32 offset) for longer strings.
  let v = cast[ptr UncheckedArray[char]](cast[uint](o.data) + uint(16 * i))
  cast[ptr int32](v)[] = n.int32
  if n <= 12:
    if n > 0: copyMem(v[4].addr, p, n)
  else:
    copyMem(v[4].addr, p, 4)
    cast[ptr int32](v[8].addr)[] = 0
    cast[ptr int32](v[12].addr)[] = o.chars.len.int32
    let at = o.chars.len
    o.chars.setLen(at + n)
    copyMem(o.chars[at].addr, p, n)

proc set*[T](o: var Out[T], i: int, v: T) {.inline.} =
  when T is string:
    if v.len > 0: o.setView(i, cast[ptr UncheckedArray[char]](v[0].unsafeAddr), v.len)
  elif T is ShortStr:
    o.setView(i, cast[ptr UncheckedArray[char]](v.data[0].unsafeAddr), v.len)
  elif T is bool:
    if v:
      let p = cast[ptr UncheckedArray[uint8]](o.data)
      p[i shr 3] = p[i shr 3] or uint8(1 shl (i and 7))
  else:
    cast[ptr UncheckedArray[storageOf(T)]](o.data)[i] = storageOf(T)(v)

proc finish*[T](o: var Out[T], name: string): SeriesExport =
  mixin arrowExtension
  let ext = arrowExtension(T)
  let schema = newSchema(arrowFormat(T), name,
                         if ext.len > 0: @[("ARROW:extension:name", ext)] else: @[])
  let arr =
    when T is string or T is ShortStr:
      # validity, views, one data buffer, then the data buffers' sizes (int64)
      let chars = allocC(o.chars.len)
      if o.chars.len > 0: copyMem(chars, o.chars[0].addr, o.chars.len)
      let sizes = cast[ptr int64](allocC(8))
      sizes[] = o.chars.len.int64
      newArray(o.len, o.nulls, [pointer(o.valid), o.data, chars, pointer(sizes)])
    else:
      newArray(o.len, o.nulls, [pointer(o.valid), o.data])
  exportSeries(schema, arr)

proc fieldOf*(T: typedesc, name: string, size = 0): ArrowSchema =
  mixin arrowExtension
  when T is seq:
    newSchema("+w:" & $size, name, fieldOf(typeof(default(T)[0]), "item"))
  else:
    let ext = arrowExtension(T)
    newSchema(arrowFormat(T), name, if ext.len > 0: @[("ARROW:extension:name", ext)] else: @[])

type
  ArrOut*[E] = object
    ## Output of a proc returning `seq[E]` with a `Size` parameter: a Polars
    ## Array(E, size), every row `size` values long.
    len, size: int
    valid: ptr UncheckedArray[uint8]
    nulls: int
    inner: Out[E]

proc initArrOut*[E](n, size: int): ArrOut[E] =
  ArrOut[E](len: n, size: size, inner: initOut[E](n * size))

proc setNull*[E](o: var ArrOut[E], i: int) =
  if o.valid.isNil:
    o.valid = cast[ptr UncheckedArray[uint8]](allocC((o.len + 7) div 8))
    for k in 0 ..< (o.len + 7) div 8: o.valid[k] = 0xff
  o.valid[i shr 3] = o.valid[i shr 3] and not uint8(1 shl (i and 7))
  inc o.nulls
  for k in 0 ..< o.size: o.inner.set(i * o.size + k, default(E))

proc set*[E](o: var ArrOut[E], i: int, v: seq[E]) {.inline.} =
  if v.len != o.size:
    raise newException(PluginError, "expected " & $o.size & " values per row, got " & $v.len)
  for k in 0 ..< o.size: o.inner.set(i * o.size + k, v[k])

proc finish*[E](o: var ArrOut[E], name: string): SeriesExport =
  let child = o.inner.finish("item")
  let inner = child.arrays[0][]
  let field = child.field[]
  # Take the child's array and schema out of its series export, then free the export's boxes.
  child.field.release = nil
  child.arrays[0].release = nil
  var c = child
  c.release(c.addr)
  let schema = newSchema("+w:" & $o.size, name, field)
  exportSeries(schema, newArray(o.len, o.nulls, [pointer(o.valid)], inner))

template initOutFor*(T: typedesc, n, size: int): untyped =
  when T is seq: initArrOut[typeof(default(T)[0])](n, size)
  else: initOut[T](n)

# ---------------------------------------------------------------- inputs

proc inputsLen*(inputs: ptr UncheckedArray[SeriesExport], n: int): int =
  ## Row count of a call: the common length; length-1 inputs broadcast.
  result = 1
  for k in 0 ..< n:
    var l = 0
    for c in 0 ..< inputs[k].len.int: l += inputs[k].arrays[c].length.int
    if l != 1:
      if result != 1 and l != result:
        raise newException(PluginError, "inputs have different lengths: " & $result & " and " & $l)
      result = l

proc kwargsOf*(p: ptr uint8, n: csize_t): Kwargs =
  if n == 0: return
  readPickle(toOpenArray(cast[ptr UncheckedArray[byte]](p), 0, n.int - 1))

proc kwInt*(kw: Kwargs, key: string, default: int64): int64 =
  if key in kw and kw[key].kind == pkInt: kw[key].i else: default

# ---------------------------------------------------------------- Nanuq bindings

proc buildPlugin*(source, name: string): string {.compileTime.} =
  ## Compiles the Nim module `source` into a plugin library at compile time
  ## (cached on the module's text) and returns its path.
  # The key covers the module, its siblings (the modules it likely imports) and polarsplugin.
  var text = staticRead(source)
  for d in [source.parentDir, currentSourcePath.parentDir]:
    for f in staticExec("ls " & quoteShell(d)).splitLines:
      if f.endsWith(".nim"): text.add staticRead(d / f)
  let key = $hash(text)
  let dir = querySetting(nimcacheDir)
  result = dir & "/lib" & name & "-" & key & (when defined(windows): ".dll" elif defined(macosx): ".dylib" else: ".so")
  let cmd = "nim c --app:lib -d:release -d:useMalloc --threads:on --hints:off --nimcache:" &
            dir & "/plugin_" & name & " --out:" & result & " " & source
  let (output, code) = gorgeEx(cmd, cache = key)
  if code != 0: error("building the plugin " & source & " failed:\n" & output)

when not compileOption("app", "lib"):
  import std/osproc
  proc compilePlugin*(source: string, outDir = getTempDir(), extra = ""): string =
    ## Compiles the Nim module `source` into a plugin library now (at run time)
    ## and returns its path: for a plugin written on the spot, in a notebook.
    let name = source.splitFile.name
    result = outDir / (DynlibFormat % name)
    let (output, code) = execCmdEx("nim c --app:lib -d:release -d:useMalloc --threads:on " &
      "--hints:off --path:" & quoteShell(currentSourcePath.parentDir.parentDir) & " --nimcache:" &
      quoteShell(outDir / "nimcache_" & name) & " --out:" & quoteShell(result) & " " & extra & " " &
      quoteShell(source))
    if code != 0: raise newException(PluginError, "building " & source & " failed:\n" & output)

template nanuqBindings*() =
  ## In a plugin module: when the module is imported by a program (not built
  ## as the library itself), build the library at compile time and give every
  ## `polarsExpr` proc a Nanuq twin that takes and returns `Expr`.
  when not compileOption("app", "lib"):
    import nanuq
    const polarsPluginLib {.inject, used.} = buildPlugin(instantiationInfo(-1, true).filename,
                                                     instantiationInfo(-1).filename.splitFile.name)

# ---------------------------------------------------------------- the macro

proc unwrapOption(t: NimNode): (bool, NimNode) =
  if t.kind == nnkBracketExpr and t[0].eqIdent("Option"): (true, t[1]) else: (false, t)

macro polarsExpr*(fn: untyped): untyped =
  ## Exports the scalar proc `fn` as an elementwise Polars plugin function.
  ## A parameter of type `RowRng` takes an input column of row keys (a row
  ## index) and gets a random stream per row, keyed by the row key and the
  ## `seed` keyword argument; a parameter of type `Kwargs` gets the keyword
  ## arguments; every other parameter is an input column. Returning
  ## `Option[T]` makes `none` a null.
  fn.expectKind nnkProcDef
  let name = $fn.name.basename
  let retT = fn.params[0]
  let (isOpt, outT) = unwrapOption(retT)
  let inputs = genSym(nskParam, "inputs")
  let nIn = genSym(nskParam, "nIn")
  let kwPtr = genSym(nskParam, "kwPtr")
  let kwLen = genSym(nskParam, "kwLen")
  let ret = genSym(nskParam, "ret")
  let ctx = genSym(nskParam, "ctx")
  let rows = genSym(nskLet, "rows")
  let kw = genSym(nskLet, "kw")
  let o = genSym(nskVar, "o")
  let i = genSym(nskForVar, "i")
  var setup = newStmtList()
  var call = newCall(fn.name.basename)
  var validCheck = newLit(true)
  var nCols = 0
  var rngVars: seq[NimNode]
  var sizeSym = newLit(0)
  for p in fn.params[1 .. ^1]:
    let t = (if p[^2].kind == nnkVarTy: p[^2][0] else: p[^2])
    for id in p[0 ..< ^2]:
      if t.eqIdent("RowRng"):
        # A random stream keyed by (seed, row key): the row key is an input
        # column (a row index), so draws repeat across chunks and threads.
        let r = genSym(nskVar, "rng")
        let c = genSym(nskLet, "rowKey")
        let k = newLit(nCols)
        setup.add quote do:
          var `r` = RowRng(seed: cast[uint64](kwInt(`kw`, "seed", 0)))
          let `c` = readCol[uint64](`inputs`[`k`].addr)
        validCheck = infix(validCheck, "and", newCall("isValid", c, i))
        rngVars.add newTree(nnkPar, r, c)
        call.add r
        inc nCols
      elif t.eqIdent("Kwargs"):
        call.add kw
      elif t.eqIdent("Size"):
        sizeSym = genSym(nskLet, "size")
        let s = sizeSym
        setup.add quote do:
          let `s` = kwInt(`kw`, "size", 1).int
          if `s` <= 0: raise newException(PluginError, "size must be a positive integer, got " & $`s`)
        call.add newCall("Size", s)
      else:
        let c = genSym(nskLet, "c" & $nCols)
        let k = newLit(nCols)
        setup.add quote do:
          let `c` = readCol[`t`](`inputs`[`k`].addr)
        validCheck = infix(validCheck, "and", newCall("isValid", c, i))
        call.add newCall("[]", c, i)
        inc nCols
  let nColsLit = newLit(nCols)
  var rngReset = newStmtList()
  for rc in rngVars:
    let (r, c) = (rc[0], rc[1])
    rngReset.add quote do:
      `r`.startRow(`c`[`i`])
  let store =
    if isOpt:
      quote do:
        let v = `call`
        if v.isSome: `o`.set(`i`, v.get) else: `o`.setNull(`i`)
    else:
      quote do: `o`.set(`i`, `call`)
  # The Nanuq twin: same name, Expr parameters, a call to the plugin.
  var twinParams = @[ident"Expr"]
  var twinArgs = newNimNode(nnkBracket)
  var hasRng, hasKw, hasSize = false
  for p in fn.params[1 .. ^1]:
    let t = (if p[^2].kind == nnkVarTy: p[^2][0] else: p[^2])
    for id in p[0 ..< ^2]:
      if t.eqIdent("RowRng"):
        hasRng = true
        twinArgs.add quote do: intRange(0, len(), dtype = UInt64)
      elif t.eqIdent("Kwargs"): hasKw = true
      elif t.eqIdent("Size"): hasSize = true
      else:
        twinParams.add newIdentDefs(ident($id), ident"Expr")
        twinArgs.add ident($id)
  if hasSize: twinParams.add newIdentDefs(ident"size", ident"int")
  if hasRng: twinParams.add newIdentDefs(ident"seed", newEmptyNode(), newLit(0))
  if hasKw: twinParams.add newIdentDefs(ident"kwargs", quote do: seq[(string, PickleValue)], quote do: @[])
  var kwPairs = newNimNode(nnkBracket)
  if hasSize: kwPairs.add quote do: ("size", toPickle(size))
  if hasRng: kwPairs.add quote do: ("seed", toPickle(seed))
  let kwExpr =
    if hasKw: quote do: writePickle(kwargs)
    elif kwPairs.len > 0: quote do: writePickle(`kwPairs`)
    else: quote do: newSeq[byte]()
  let twinName = (if fn[0].kind == nnkPostfix: postfix(ident(name), "*") else: ident(name))
  let det = newLit(not hasRng)
  let twinBody = quote do:
    registerPluginFunction(polarsPluginLib, `name`, `twinArgs`, kwargs = `kwExpr`,
                           isElementwise = true, isDeterministic = `det`)
  let twin = newProc(twinName, twinParams, twinBody)
  twin.addPragma ident"used"
  let kernelName = newLit("_polars_plugin_" & name)
  let fieldName = newLit("_polars_plugin_field_" & name)
  let kernel = genSym(nskProc, name & "Kernel")
  let field = genSym(nskProc, name & "Field")
  let fields = genSym(nskParam, "fields")
  let fret = genSym(nskParam, "fret")
  let nFlds = genSym(nskParam, "nFields")
  let fkwPtr = genSym(nskParam, "kwPtr")
  let fkwLen = genSym(nskParam, "kwLen")
  result = newStmtList(fn)
  result.add quote do:
    when declared(polarsPluginLib):
      `twin`
  result.add quote do:
    proc `kernel`(`inputs`: ptr UncheckedArray[SeriesExport], `nIn`: csize_t,
                  `kwPtr`: ptr uint8, `kwLen`: csize_t, `ret`: ptr SeriesExport,
                  `ctx`: ptr CallerContext) {.exportc: `kernelName`, dynlib, cdecl.} =
      guarded:
        try:
          if `nIn`.int != `nColsLit`:
            raise newException(PluginError, `name` & " takes " & $`nColsLit` &
                               " inputs, got " & $`nIn`)
          let `kw` = kwargsOf(`kwPtr`, `kwLen`)
          let `rows` = inputsLen(`inputs`, `nIn`.int)
          `setup`
          var `o` = initOutFor(`outT`, `rows`, `sizeSym`)
          for `i` in 0 ..< `rows`:
            `rngReset`
            if `validCheck`:
              `store`
            else:
              `o`.setNull(`i`)
          `ret`[] = `o`.finish(if `nIn` > 0: $`inputs`[0].field.name else: `name`)
        finally:
          for k in 0 ..< `nIn`.int: releaseInput(`inputs`[k].addr)
    proc `field`(`fields`: ptr UncheckedArray[ArrowSchema], `nFlds`: csize_t,
                 `fret`: ptr ArrowSchema, `fkwPtr`: ptr uint8, `fkwLen`: csize_t)
                {.exportc: `fieldName`, dynlib, cdecl.} =
      guarded:
        let fsize = (if `fkwLen` > 0: kwInt(kwargsOf(`fkwPtr`, `fkwLen`), "size", 1).int else: 1)
        `fret`[] = fieldOf(`outT`, if `nFlds` > 0: $`fields`[0].name else: `name`, fsize)
