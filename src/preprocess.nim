## Build-time preprocessor.
## Reads references.json (decompressed) and writes:
##   vectors.bin -- D arrays of N float16 values, SoA layout
##   labels.bin  -- N bytes (1 = fraud, 0 = legit)

import std/[os, math, memfiles]

const D = 14
const ExpectedN = 3_000_000

proc f32ToF16(x: float32): uint16 =
  let bits = cast[uint32](x)
  let sign = uint16((bits shr 16) and 0x8000'u32)
  let expField = int((bits shr 23) and 0xff'u32)
  let mantissa = bits and 0x7fffff'u32

  if expField == 0xff:
    if mantissa == 0:
      return sign or 0x7c00'u16
    else:
      return sign or 0x7e00'u16  # qNaN

  if expField == 0:
    return sign  # zero or subnormal in f32 -> zero in f16

  let unbiased = expField - 127

  if unbiased > 15:
    return sign or 0x7c00'u16  # overflow -> Inf

  if unbiased < -24:
    return sign  # underflow -> 0

  if unbiased < -14:
    # Subnormal in f16
    let shift = -14 - unbiased
    let m = (mantissa or 0x800000'u32) shr (uint32(13 + shift))
    let half = 1'u32 shl uint32(12 + shift)
    let kept = m
    var rounded = kept
    let lowMask = (1'u32 shl uint32(13 + shift)) - 1'u32
    let dropped = (mantissa or 0x800000'u32) and lowMask
    if dropped > half or (dropped == half and (kept and 1'u32) != 0'u32):
      rounded += 1
    return sign or uint16(rounded and 0x3ff'u32)

  let exp16Field = uint32(unbiased + 15) shl 10
  let mantTrunc = mantissa shr 13
  let dropped = mantissa and 0x1fff'u32
  let halfway = 0x1000'u32
  var mantOut = mantTrunc
  if dropped > halfway or (dropped == halfway and (mantTrunc and 1'u32) != 0'u32):
    mantOut += 1
  var expOut = exp16Field
  if mantOut == 0x400'u32:
    mantOut = 0
    expOut += 0x400'u32
  if (expOut shr 10) >= 0x1f'u32:
    return sign or 0x7c00'u16  # overflow to Inf
  return sign or uint16((expOut or mantOut) and 0x7fff'u32)

template skipWs(s: cstring; n: int; p: var int) =
  while p < n:
    let c = s[p]
    if c == ' ' or c == '\n' or c == '\r' or c == '\t':
      inc p
    else:
      break

proc parseNumberFast(s: cstring; n: int; p: var int): float64 =
  skipWs(s, n, p)
  var sign = 1.0
  if p < n and s[p] == '-':
    sign = -1.0
    inc p
  elif p < n and s[p] == '+':
    inc p

  var v = 0.0
  while p < n and s[p] >= '0' and s[p] <= '9':
    v = v * 10.0 + float64(ord(s[p]) - ord('0'))
    inc p

  if p < n and s[p] == '.':
    inc p
    var scale = 0.1
    while p < n and s[p] >= '0' and s[p] <= '9':
      v += float64(ord(s[p]) - ord('0')) * scale
      scale *= 0.1
      inc p

  if p < n and (s[p] == 'e' or s[p] == 'E'):
    inc p
    var expSign = 1
    if s[p] == '-':
      expSign = -1
      inc p
    elif s[p] == '+':
      inc p
    var ev = 0
    while p < n and s[p] >= '0' and s[p] <= '9':
      ev = ev * 10 + (ord(s[p]) - ord('0'))
      inc p
    v *= pow(10.0, float64(expSign * ev))

  sign * v

proc main() =
  if paramCount() != 3:
    quit("usage: preprocess <input.json> <vectors.bin> <labels.bin>", 1)

  let inPath = paramStr(1)
  let outVecPath = paramStr(2)
  let outLblPath = paramStr(3)

  echo "opening ", inPath
  var mf = memfiles.open(inPath, mode = fmRead)
  let raw = cast[cstring](mf.mem)
  let total = mf.size
  echo "mapped ", total, " bytes"

  var vectors: array[D, seq[uint16]]
  for d in 0..<D:
    vectors[d] = newSeqOfCap[uint16](ExpectedN)
  var labels = newSeqOfCap[uint8](ExpectedN)

  var p = 0
  skipWs(raw, total, p)
  if p >= total or raw[p] != '[':
    quit("expected top-level array", 1)
  inc p

  var n = 0
  while true:
    skipWs(raw, total, p)
    if p >= total: break
    if raw[p] == ']':
      break
    if raw[p] == ',':
      inc p
      continue
    if raw[p] != '{':
      quit("expected object at offset " & $p, 1)
    inc p

    var dimIdx = 0
    var currentVec: array[D, uint16]
    var labelByte: uint8 = 0
    var sawVector = false
    var sawLabel = false

    while true:
      skipWs(raw, total, p)
      if p >= total: quit("unexpected EOF in object", 1)
      if raw[p] == '}':
        inc p
        break
      if raw[p] == ',':
        inc p
        continue

      if raw[p] != '"':
        quit("expected key string at " & $p, 1)
      inc p
      let keyStart = p
      while p < total and raw[p] != '"':
        inc p
      let keyLen = p - keyStart
      inc p  # closing quote

      skipWs(raw, total, p)
      if p >= total or raw[p] != ':':
        quit("expected colon", 1)
      inc p

      if keyLen == 6 and raw[keyStart] == 'v':
        # "vector"
        skipWs(raw, total, p)
        if raw[p] != '[':
          quit("expected vector array", 1)
        inc p
        dimIdx = 0
        while true:
          skipWs(raw, total, p)
          if raw[p] == ']':
            inc p
            break
          if raw[p] == ',':
            inc p
            continue
          let v = parseNumberFast(raw, total, p)
          if dimIdx < D:
            currentVec[dimIdx] = f32ToF16(float32(v))
          inc dimIdx
        sawVector = true
      elif keyLen == 5 and raw[keyStart] == 'l':
        # "label"
        skipWs(raw, total, p)
        if raw[p] != '"':
          quit("expected label string", 1)
        inc p
        # First char tells us 'f' = fraud, 'l' = legit
        if p < total and raw[p] == 'f':
          labelByte = 1'u8
        else:
          labelByte = 0'u8
        while p < total and raw[p] != '"':
          inc p
        inc p
        sawLabel = true
      else:
        # Unknown key - skip value (string, number, array, object, true, false, null)
        skipWs(raw, total, p)
        let c = raw[p]
        if c == '"':
          inc p
          while p < total and raw[p] != '"': inc p
          inc p
        elif c == '[' or c == '{':
          let openCh = c
          let closeCh = if c == '[': ']' else: '}'
          var depth = 1
          inc p
          while p < total and depth > 0:
            if raw[p] == '"':
              inc p
              while p < total and raw[p] != '"': inc p
              inc p
            elif raw[p] == openCh:
              inc depth
              inc p
            elif raw[p] == closeCh:
              dec depth
              inc p
            else:
              inc p
        else:
          while p < total and raw[p] != ',' and raw[p] != '}':
            inc p

    if not sawVector or not sawLabel:
      quit("record missing vector or label", 1)

    for d in 0..<D:
      vectors[d].add(currentVec[d])
    labels.add(labelByte)
    inc n

    if (n mod 250_000) == 0:
      echo "  processed ", n, " records"

  echo "total parsed: ", n, " records"

  if n == 0:
    quit("no records parsed", 1)

  echo "writing ", outVecPath, " (", n * D * 2, " bytes)"
  var outVec = system.open(outVecPath, fmWrite)
  for d in 0..<D:
    let written = outVec.writeBuffer(addr vectors[d][0], n * 2)
    if written != n * 2:
      quit("short write on vectors.bin", 1)
  outVec.close()

  echo "writing ", outLblPath, " (", n, " bytes)"
  var outLbl = system.open(outLblPath, fmWrite)
  let writtenL = outLbl.writeBuffer(addr labels[0], n)
  if writtenL != n:
    quit("short write on labels.bin", 1)
  outLbl.close()

  mf.close()
  echo "done"

main()
