## The Arrow C data interface (https://arrow.apache.org/docs/format/CDataInterface.html)
## and the `SeriesExport` wrapper Polars passes to expression plugins
## (polars-ffi `version_0`). Everything here is plain C layout: no Rust needed.

type
  ArrowSchema* {.bycopy.} = object
    format*: cstring
    name*: cstring
    metadata*: cstring
    flags*: int64
    nChildren*: int64
    children*: ptr UncheckedArray[ptr ArrowSchema]
    dictionary*: ptr ArrowSchema
    release*: proc (s: ptr ArrowSchema) {.cdecl, gcsafe, raises: [].}
    privateData*: pointer

  ArrowArray* {.bycopy.} = object
    length*: int64
    nullCount*: int64
    offset*: int64
    nBuffers*: int64
    nChildren*: int64
    buffers*: ptr UncheckedArray[pointer]
    children*: ptr UncheckedArray[ptr ArrowArray]
    dictionary*: ptr ArrowArray
    release*: proc (a: ptr ArrowArray) {.cdecl, gcsafe, raises: [].}
    privateData*: pointer

  SeriesExport* {.bycopy.} = object
    ## One Series: its field and its chunks (one ArrowArray each).
    field*: ptr ArrowSchema
    arrays*: ptr UncheckedArray[ptr ArrowArray]
    len*: csize_t
    release*: proc (e: ptr SeriesExport) {.cdecl, gcsafe, raises: [].}
    privateData*: pointer

  CallerContext* {.bycopy.} = object
    bitflags*: uint64

proc cmalloc(n: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc ccalloc(n, s: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>".}
proc cfree*(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc allocC*(n: int): pointer = cmalloc(max(n, 1).csize_t)
proc allocC0*(n: int): pointer = ccalloc(max(n, 1).csize_t, 1)

proc cstrdup*(s: string): cstring =
  let p = cast[ptr UncheckedArray[char]](allocC(s.len + 1))
  for i, c in s: p[i] = c
  p[s.len] = '\0'
  cast[cstring](p)

# ---------------------------------------------------------------- metadata

proc encodeMetadata*(pairs: openArray[(string, string)]): cstring =
  ## Arrow's binary metadata: int32 count, then (int32 len, bytes) per key and value.
  if pairs.len == 0: return nil
  var n = 4
  for (k, v) in pairs: n += 8 + k.len + v.len
  let p = cast[ptr UncheckedArray[byte]](allocC(n))
  var at = 0
  proc i32(x: int) =
    let u = cast[uint32](x.int32)
    for k in 0 ..< 4: p[at + k] = byte((u shr (8 * k)) and 0xff)
    at += 4
  proc bytes(s: string) =
    i32 s.len
    for c in s: p[at] = byte(c); inc at
  i32 pairs.len
  for (k, v) in pairs: bytes k; bytes v
  cast[cstring](p)

proc decodeMetadata*(m: cstring): seq[(string, string)] =
  if m.isNil: return
  let p = cast[ptr UncheckedArray[byte]](m)
  var at = 0
  proc i32(): int =
    var u: uint32
    for k in countdown(3, 0): u = (u shl 8) or p[at + k].uint32
    at += 4
    cast[int32](u).int
  proc str(): string =
    let n = i32()
    result = newString(n)
    for k in 0 ..< n: result[k] = char(p[at + k])
    at += n
  for _ in 0 ..< i32():
    let k = str()
    result.add (k, str())

proc extensionName*(s: ptr ArrowSchema): string =
  for (k, v) in decodeMetadata(s.metadata):
    if k == "ARROW:extension:name": return v

# ---------------------------------------------------------------- schemas we export

proc releaseSchema(s: ptr ArrowSchema) {.cdecl, gcsafe, raises: [].} =
  if s.isNil or s.release.isNil: return
  cfree(s.format); cfree(s.name); cfree(s.metadata); cfree(s.privateData)
  s.release = nil

proc newSchema*(format, name: string, metadata: openArray[(string, string)] = []): ArrowSchema =
  ArrowSchema(format: cstrdup(format), name: cstrdup(name),
              metadata: encodeMetadata(metadata), flags: 2,   # ARROW_FLAG_NULLABLE
              release: releaseSchema,
              privateData: allocC(1))   # Polars reads a nil privateData as "no schema"


# ---------------------------------------------------------------- arrays we export

type ArrayPrivate = object
  buffers: array[4, pointer]

proc releaseArray(a: ptr ArrowArray) {.cdecl, gcsafe, raises: [].} =
  if a.isNil or a.release.isNil: return
  let priv = cast[ptr ArrayPrivate](a.privateData)
  for b in priv.buffers: cfree(b)
  cfree(priv)
  a.release = nil

proc newArray*(length, nullCount: int, buffers: openArray[pointer]): ArrowArray =
  ## An array that owns `buffers` (malloc'ed) and frees them on release.
  let priv = cast[ptr ArrayPrivate](allocC0(sizeof(ArrayPrivate)))
  for i, b in buffers: priv.buffers[i] = b
  ArrowArray(length: length, nullCount: nullCount, nBuffers: buffers.len,
             buffers: cast[ptr UncheckedArray[pointer]](priv.buffers.addr),
             release: releaseArray, privateData: priv)

# ---------------------------------------------------------------- series we export

type SeriesPrivate = object
  schema: ArrowSchema
  array: ptr ArrowArray
  arrays: array[1, ptr ArrowArray]

proc releaseSeries(e: ptr SeriesExport) {.cdecl, gcsafe, raises: [].} =
  # Polars moved the ArrowArray out (and releases its buffers itself); we free
  # only the boxes and the schema, as polars-ffi's own release does.
  if e.isNil or e.release.isNil: return
  let priv = cast[ptr SeriesPrivate](e.privateData)
  if not priv.schema.release.isNil: priv.schema.release(priv.schema.addr)
  cfree(priv.array)
  cfree(priv)
  e.release = nil

proc exportSeries*(schema: ArrowSchema, arr: ArrowArray): SeriesExport =
  let priv = cast[ptr SeriesPrivate](allocC0(sizeof(SeriesPrivate)))
  priv.schema = schema
  priv.array = cast[ptr ArrowArray](allocC(sizeof(ArrowArray)))
  priv.array[] = arr
  priv.arrays[0] = priv.array
  SeriesExport(field: priv.schema.addr,
               arrays: cast[ptr UncheckedArray[ptr ArrowArray]](priv.arrays.addr),
               len: 1, release: releaseSeries, privateData: priv)

proc releaseInput*(e: ptr SeriesExport) =
  ## A plugin owns its inputs: release every chunk, then the export itself.
  for i in 0 ..< e.len.int:
    let a = e.arrays[i]
    if not a.isNil and not a.release.isNil: a.release(a)
  if not e.release.isNil: e.release(e)
