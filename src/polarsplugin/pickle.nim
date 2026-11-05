## Just enough pickle for plugin keyword arguments.
##
## Python Polars pickles the `kwargs` dict of `register_plugin_function`
## (protocol 5) and Rust plugins read it with serde-pickle. Keyword arguments
## are flat dicts of numbers, strings, booleans and None, so a reader for that
## subset (and a writer, for Nanuq) is all a Nim plugin needs.

import std/[tables, strutils]

type
  PickleKind* = enum pkNone, pkBool, pkInt, pkFloat, pkStr, pkList
  PickleValue* = object
    case kind*: PickleKind
    of pkNone: discard
    of pkBool: b*: bool
    of pkInt: i*: int64
    of pkFloat: f*: float64
    of pkStr: s*: string
    of pkList: items*: seq[PickleValue]
  Kwargs* = OrderedTable[string, PickleValue]
  PickleError* = object of ValueError

proc `$`*(v: PickleValue): string =
  case v.kind
  of pkNone: "None"
  of pkBool: (if v.b: "True" else: "False")
  of pkInt: $v.i
  of pkFloat: $v.f
  of pkStr: v.s.escape
  of pkList: "[" & v.items.join(", ") & "]"

proc readPickle*(data: openArray[byte]): Kwargs =
  ## The dict pickled in `data`; an empty buffer is an empty dict.
  result = initOrderedTable[string, PickleValue]()
  if data.len == 0: return
  var
    pos = 0
    stack: seq[PickleValue]
    marks: seq[int]
    memo: seq[PickleValue]
    isDict: seq[bool]           # parallel to stack: is this slot the dict?
  template need(n: int) =
    if pos + n > data.len: raise newException(PickleError, "truncated pickle")
  proc le(data: openArray[byte], at, n: int): uint64 =
    for k in countdown(n - 1, 0): result = (result shl 8) or data[at + k].uint64
  template push(v: PickleValue) =
    stack.add v; isDict.add false
  template str(n: int): string =
    need n
    var s = newString(n)
    for k in 0 ..< n: s[k] = char(data[pos + k])
    pos += n
    s
  proc setItems(res: var Kwargs, stack: var seq[PickleValue], isDict: var seq[bool], frm: int) =
    var k = frm
    while k + 1 < stack.len:
      if stack[k].kind != pkStr: raise newException(PickleError, "kwargs keys must be strings")
      res[stack[k].s] = stack[k + 1]
      k += 2
    stack.setLen frm; isDict.setLen frm
  while pos < data.len:
    let op = data[pos].char
    inc pos
    case op
    of '\x80': need 1; inc pos                       # PROTO
    of '\x95': need 8; pos += 8                      # FRAME
    of '}': stack.add PickleValue(kind: pkNone); isDict.add true   # EMPTY_DICT
    of ']', ')': push PickleValue(kind: pkList)      # EMPTY_LIST / EMPTY_TUPLE
    of '(': marks.add stack.len                      # MARK
    of '\x94': memo.add stack[^1]                    # MEMOIZE
    of 'q': need 1; inc pos; memo.add stack[^1]      # BINPUT
    of 'r': need 4; pos += 4; memo.add stack[^1]     # LONG_BINPUT
    of 'h':                                          # BINGET
      need 1; push memo[data[pos].int]; inc pos
    of 'j':
      need 4; push memo[le(data, pos, 4).int]; pos += 4
    of 'N': push PickleValue(kind: pkNone)
    of '\x88': push PickleValue(kind: pkBool, b: true)
    of '\x89': push PickleValue(kind: pkBool, b: false)
    of 'K': need 1; push PickleValue(kind: pkInt, i: data[pos].int64); inc pos
    of 'M': need 2; push PickleValue(kind: pkInt, i: le(data, pos, 2).int64); pos += 2
    of 'J': need 4; push PickleValue(kind: pkInt, i: cast[int32](le(data, pos, 4).uint32).int64); pos += 4
    of '\x8a':                                       # LONG1
      need 1
      let n = data[pos].int
      inc pos
      need n
      if n > 8: raise newException(PickleError, "integer too large")
      var u = le(data, pos, n)
      if n > 0 and n < 8 and (data[pos + n - 1] and 0x80) != 0:
        u = u or (not 0'u64 shl (8 * n))             # sign-extend
      push PickleValue(kind: pkInt, i: cast[int64](u)); pos += n
    of 'G':                                          # BINFLOAT, big endian
      need 8
      var u: uint64
      for k in 0 ..< 8: u = (u shl 8) or data[pos + k].uint64
      push PickleValue(kind: pkFloat, f: cast[float64](u)); pos += 8
    of '\x8c', 'X', '\x8d':                          # SHORT_BINUNICODE, BINUNICODE, BINUNICODE8
      let w = (if op == '\x8c': 1 elif op == 'X': 4 else: 8)
      need w
      let n = le(data, pos, w).int
      pos += w
      push PickleValue(kind: pkStr, s: str(n))
    of 'a':                                          # APPEND
      let v = stack.pop; discard isDict.pop
      stack[^1].items.add v
    of 'e', 't':                                     # APPENDS / TUPLE
      let m = marks.pop
      let vals = stack[m .. ^1]
      stack.setLen m; isDict.setLen m
      if op == 'e': stack[^1].items.add vals
      else: push PickleValue(kind: pkList, items: vals)
    of '\x85', '\x86', '\x87':                       # TUPLE1..3
      let n = op.int - 0x84
      let vals = stack[^n .. ^1]
      stack.setLen stack.len - n; isDict.setLen isDict.len - n
      push PickleValue(kind: pkList, items: vals)
    of 's':                                          # SETITEM
      setItems(result, stack, isDict, stack.len - 2)
    of 'u':                                          # SETITEMS
      setItems(result, stack, isDict, marks.pop)
    of '.': return                                   # STOP
    else:
      raise newException(PickleError, "unsupported pickle opcode 0x" & toHex(op.int, 2))

proc writePickle*(kw: openArray[(string, PickleValue)]): seq[byte] =
  ## A protocol-2 pickle of the dict `kw`, readable by Python, serde-pickle
  ## (Rust plugins) and `readPickle`.
  if kw.len == 0: return
  proc u32(r: var seq[byte], n: int) =
    for k in 0 ..< 4: r.add byte((n shr (8 * k)) and 0xff)
  proc value(r: var seq[byte], v: PickleValue) =
    case v.kind
    of pkNone: r.add byte('N')
    of pkBool: r.add(if v.b: 0x88'u8 else: 0x89'u8)
    of pkInt:
      r.add 0x8a; r.add 8
      for k in 0 ..< 8: r.add byte((cast[uint64](v.i) shr (8 * k)) and 0xff)
    of pkFloat:
      r.add byte('G')
      let u = cast[uint64](v.f)
      for k in countdown(7, 0): r.add byte((u shr (8 * k)) and 0xff)
    of pkStr:
      r.add byte('X'); r.u32 v.s.len
      for c in v.s: r.add byte(c)
    of pkList:
      r.add byte(']'); r.add byte('(')
      for it in v.items: r.value it
      r.add byte('e')
  result = @[0x80'u8, 2, byte('}'), byte('(')]
  for (k, v) in kw:
    result.value PickleValue(kind: pkStr, s: k)
    result.value v
  result.add byte('u'); result.add byte('.')

converter toPickle*(x: float): PickleValue = PickleValue(kind: pkFloat, f: x)
converter toPickle*(x: int): PickleValue = PickleValue(kind: pkInt, i: x)
converter toPickle*(x: bool): PickleValue = PickleValue(kind: pkBool, b: x)
converter toPickle*(x: string): PickleValue = PickleValue(kind: pkStr, s: x)

proc to*(v: PickleValue, T: typedesc): T =
  ## `v` as a Nim value of type `T` (numbers widen, ints become floats).
  when T is SomeFloat:
    case v.kind
    of pkFloat: T(v.f)
    of pkInt: T(v.i)
    else: raise newException(PickleError, "expected a number, got " & $v)
  elif T is bool:
    if v.kind != pkBool: raise newException(PickleError, "expected a bool, got " & $v)
    v.b
  elif T is SomeInteger:
    if v.kind != pkInt: raise newException(PickleError, "expected an int, got " & $v)
    T(v.i)
  elif T is string:
    if v.kind != pkStr: raise newException(PickleError, "expected a string, got " & $v)
    v.s
  else:
    {.error: "unsupported kwargs field type " & $T.}
