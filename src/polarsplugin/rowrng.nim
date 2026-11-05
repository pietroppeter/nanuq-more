## Counter-based random numbers, one stream per row: a draw is a pure function
## of (seed, row key, counter), so seeded samples do not depend on chunking or
## threads. Plain Nim, shared by the native plugin and the JavaScript side.

import std/math

type RowRng* = object
  seed*, key*, counter*: uint64

proc splitmix64*(x: uint64): uint64 {.inline.} =
  var z = x + 0x9E3779B97F4A7C15'u64
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc startRow*(r: var RowRng, row: uint64) {.inline.} =
  ## Positions the stream at the start of row `row`.
  r.key = splitmix64(r.seed xor splitmix64(row))
  r.counter = 0

proc next*(r: var RowRng): uint64 {.inline.} =
  ## The next 64 random bits of this row's stream.
  inc r.counter
  splitmix64(r.key + r.counter * 0x9E3779B97F4A7C15'u64)

proc uniform*(r: var RowRng): float {.inline.} =
  ## In (0, 1): never 0, so logs and inverse CDFs stay finite.
  (float(r.next shr 11) + 0.5) * (1.0 / 9007199254740992.0)

# ---------------------------------------------------------------- ziggurat

const zigR = 3.442619855899

proc zigTables(): (array[128, uint32], array[128, float], array[128, float]) =
  ## Marsaglia and Tsang's 128-layer ziggurat for the normal, built at compile time.
  const m1 = 2147483648.0
  const vn = 9.91256303526217e-3
  var (kn, wn, fn) = (default(array[128, uint32]), default(array[128, float]), default(array[128, float]))
  var dn = zigR
  var tn = dn
  let q = vn / exp(-0.5 * dn * dn)
  kn[0] = uint32((dn / q) * m1)
  kn[1] = 0
  wn[0] = q / m1
  wn[127] = dn / m1
  fn[0] = 1.0
  fn[127] = exp(-0.5 * dn * dn)
  for i in countdown(126, 1):
    dn = sqrt(-2 * ln(vn / dn + exp(-0.5 * dn * dn)))
    kn[i + 1] = uint32((dn / tn) * m1)
    tn = dn
    fn[i] = exp(-0.5 * dn * dn)
    wn[i] = dn / m1
  (kn, wn, fn)

const (zigK, zigW, zigF) = zigTables()

proc zigSlow(r: var RowRng, hz: int32, iz: int): float =
  var hz = hz
  var iz = iz
  while true:
    let x = float(hz) * zigW[iz]
    if iz == 0:
      # the tail beyond R
      var xx, y: float
      while true:
        xx = -ln(r.uniform) / zigR
        y = -ln(r.uniform)
        if y + y >= xx * xx: break
      return (if hz > 0: zigR + xx else: -zigR - xx)
    if zigF[iz] + r.uniform * (zigF[iz - 1] - zigF[iz]) < exp(-0.5 * x * x): return x
    let u = r.next
    hz = cast[int32](uint32(u shr 32))
    iz = int(u and 127)
    if uint64(abs(int64(hz))) < uint64(zigK[iz]): return float(hz) * zigW[iz]

proc normal*(r: var RowRng): float {.inline.} =
  ## A standard normal draw: one 64-bit draw for ~99% of the calls.
  let u = r.next
  let hz = cast[int32](uint32(u shr 32))
  let iz = int(u and 127)
  if uint64(abs(int64(hz))) < uint64(zigK[iz]): float(hz) * zigW[iz]
  else: zigSlow(r, hz, iz)
