import std/[asyncdispatch, math, options, os, strutils]
import httpbeast


const
  MaxAmount = 10_000.0'f32
  MaxInstallments = 12.0'f32
  AmountVsAvgRatio = 10.0'f32
  MaxMinutes = 1_440.0'f32
  MaxKm = 1_000.0'f32
  MaxTxCount24h = 20.0'f32
  MaxMerchantAvgAmount = 10_000.0'f32
  D = 14
  K = 5


proc vc_init(vecPath: cstring; lblPath: cstring; ivfPath: cstring): cint {.importc, gcsafe.}
proc vc_count(): csize_t {.importc, gcsafe.}
proc vc_query(query: ptr float32): cint {.importc, gcsafe.}


template isDigit(c: char): bool = c >= '0' and c <= '9'

proc skipWs(s: string; p: var int) {.inline.} =
  while p < s.len:
    let c = s[p]
    if c == ' ' or c == '\n' or c == '\r' or c == '\t':
      inc p
    else:
      return

proc valuePos(s: string; key: string; lo, hi: int): int =
  
  let keyPos = s.find(key, lo, hi - 1)
  if keyPos < 0:
    return -1
  var p = keyPos + key.len
  while p < hi and s[p] != ':':
    inc p
  if p >= hi: return -1
  inc p
  while p < hi:
    let c = s[p]
    if c == ' ' or c == '\n' or c == '\r' or c == '\t': inc p
    else: break
  return p

proc parseFloatAt(s: string; p0: int): float64 =
  var p = p0
  var sign = 1.0
  if p < s.len and s[p] == '-':
    sign = -1.0
    inc p
  elif p < s.len and s[p] == '+':
    inc p

  var v = 0.0
  while p < s.len and isDigit(s[p]):
    v = v * 10.0 + float64(ord(s[p]) - ord('0'))
    inc p

  if p < s.len and s[p] == '.':
    inc p
    var scale = 0.1
    while p < s.len and isDigit(s[p]):
      v += float64(ord(s[p]) - ord('0')) * scale
      scale *= 0.1
      inc p

  if p < s.len and (s[p] == 'e' or s[p] == 'E'):
    inc p
    var expSign = 1
    if p < s.len and s[p] == '-':
      expSign = -1
      inc p
    elif p < s.len and s[p] == '+':
      inc p
    var ev = 0
    while p < s.len and isDigit(s[p]):
      ev = ev * 10 + (ord(s[p]) - ord('0'))
      inc p
    v *= pow(10.0, float64(expSign * ev))
  sign * v

proc parseIntAt(s: string; p0: int): int =
  var p = p0
  var sign = 1
  if p < s.len and s[p] == '-':
    sign = -1
    inc p
  var v = 0
  while p < s.len and isDigit(s[p]):
    v = v * 10 + (ord(s[p]) - ord('0'))
    inc p
  sign * v

proc parseFloat(s: string; key: string; lo, hi: int): float64 =
  let p = valuePos(s, key, lo, hi)
  if p < 0: raise newException(ValueError, "missing " & key)
  parseFloatAt(s, p)

proc parseInt(s: string; key: string; lo, hi: int): int =
  let p = valuePos(s, key, lo, hi)
  if p < 0: raise newException(ValueError, "missing " & key)
  parseIntAt(s, p)

proc parseBool(s: string; key: string; lo, hi: int): bool =
  let p = valuePos(s, key, lo, hi)
  if p < 0: raise newException(ValueError, "missing " & key)
  s[p] == 't'

proc parseStringSpan(s: string; key: string; lo, hi: int; outLo: var int; outHi: var int) =
  let p = valuePos(s, key, lo, hi)
  if p < 0 or s[p] != '"':
    raise newException(ValueError, "missing string " & key)
  outLo = p + 1
  var q = outLo
  while q < s.len and s[q] != '"':
    inc q
  outHi = q

proc parseDigitsAt(s: string; p0, p1: int): int =
  var v = 0
  for i in p0..<p1:
    if not isDigit(s[i]): break
    v = v * 10 + (ord(s[i]) - ord('0'))
  v


proc dayOfWeek(year, month, day: int): int =
  var y = year
  var m = month
  if m < 3:
    m += 12
    y -= 1
  let kk = y mod 100
  let jj = y div 100
  let h = (day + (13 * (m + 1)) div 5 + kk + kk div 4 + jj div 4 + 5 * jj) mod 7
  
  (h + 5) mod 7


proc daysFromCivil(y, m, d: int): int64 =
  var year = y
  if m <= 2: year -= 1
  let era = (if year >= 0: year else: year - 399) div 400
  let yoe = year - era * 400
  let mp = if m > 2: m - 3 else: m + 9
  let doy = (153 * mp + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era.int64 * 146097'i64 + doe.int64 - 719468'i64


proc parseTimestamp(s: string; lo: int): tuple[hour, dow: int, totalMinutes: int64] =
  let year = parseDigitsAt(s, lo, lo + 4)
  let month = parseDigitsAt(s, lo + 5, lo + 7)
  let day = parseDigitsAt(s, lo + 8, lo + 10)
  let hour = parseDigitsAt(s, lo + 11, lo + 13)
  let minute = parseDigitsAt(s, lo + 14, lo + 16)
  let dow = dayOfWeek(year, month, day)
  let days = daysFromCivil(year, month, day)
  let total = days * 1440'i64 + int64(hour) * 60'i64 + int64(minute)
  (hour, dow, total)

proc mccRisk(mcc: int): float32 =
  case mcc
  of 5411: 0.15'f32
  of 5812: 0.30'f32
  of 5912: 0.20'f32
  of 5944: 0.45'f32
  of 7801: 0.80'f32
  of 7802: 0.75'f32
  of 7995: 0.85'f32
  of 4511: 0.35'f32
  of 5311: 0.25'f32
  of 5999: 0.50'f32
  else: 0.50'f32

proc clamp01(x: float32): float32 {.inline.} =
  if x < 0.0'f32: 0.0'f32
  elif x > 1.0'f32: 1.0'f32
  else: x

proc containsExact(s: string; lo, hi: int; needleLo, needleHi: int): bool =
  
  let needleLen = needleHi - needleLo
  var p = lo
  while p < hi:
    if s[p] == '"':
      let valStart = p + 1
      let valEnd = valStart + needleLen
      if valEnd <= hi and s[valEnd] == '"':
        var same = true
        var i = 0
        while i < needleLen:
          if s[valStart + i] != s[needleLo + i]:
            same = false
            break
          inc i
        if same:
          return true
        p = valEnd
      else:
        inc p
    else:
      inc p
  false

proc skipObject(s: string; p0: int): int =
  
  var p = p0
  if p >= s.len or s[p] != '{':
    return p
  inc p
  var depth = 1
  while p < s.len and depth > 0:
    let c = s[p]
    if c == '"':
      inc p
      while p < s.len and s[p] != '"': inc p
      if p < s.len: inc p
    elif c == '{':
      inc depth
      inc p
    elif c == '}':
      dec depth
      inc p
    else:
      inc p
  p

proc skipArray(s: string; p0: int): int =
  var p = p0
  if p >= s.len or s[p] != '[':
    return p
  inc p
  var depth = 1
  while p < s.len and depth > 0:
    let c = s[p]
    if c == '"':
      inc p
      while p < s.len and s[p] != '"': inc p
      if p < s.len: inc p
    elif c == '[':
      inc depth
      inc p
    elif c == ']':
      dec depth
      inc p
    else:
      inc p
  p

proc sectionEnd(s: string; openPos: int): int =
  var p = openPos
  while p < s.len and s[p] != '{':
    inc p
  skipObject(s, p)

proc buildVector(body: string; vec: var array[D, float32]) =
  let txPos = body.find("\"transaction\"")
  let customerPos = body.find("\"customer\"")
  let merchantPos = body.find("\"merchant\"")
  let terminalPos = body.find("\"terminal\"")
  let lastTxPos = body.find("\"last_transaction\"")

  if txPos < 0 or customerPos < 0 or merchantPos < 0 or terminalPos < 0:
    raise newException(ValueError, "missing section")

  let txEnd = sectionEnd(body, txPos)
  let customerEnd = sectionEnd(body, customerPos)
  let merchantEnd = sectionEnd(body, merchantPos)
  let terminalEnd = sectionEnd(body, terminalPos)

  let amount = parseFloat(body, "\"amount\"", txPos, txEnd)
  let installments = parseInt(body, "\"installments\"", txPos, txEnd)

  var reqAtLo, reqAtHi: int
  parseStringSpan(body, "\"requested_at\"", txPos, txEnd, reqAtLo, reqAtHi)

  let custAvg = parseFloat(body, "\"avg_amount\"", customerPos, customerEnd)
  let txCount24h = parseInt(body, "\"tx_count_24h\"", customerPos, customerEnd)

  
  let knownStart = valuePos(body, "\"known_merchants\"", customerPos, customerEnd)
  if knownStart < 0 or body[knownStart] != '[':
    raise newException(ValueError, "missing known_merchants")
  let knownEnd = skipArray(body, knownStart)

  var midLo, midHi: int
  parseStringSpan(body, "\"id\"", merchantPos, merchantEnd, midLo, midHi)

  var mccLo, mccHi: int
  parseStringSpan(body, "\"mcc\"", merchantPos, merchantEnd, mccLo, mccHi)
  let mcc = parseDigitsAt(body, mccLo, mccHi)

  let merchantAvg = parseFloat(body, "\"avg_amount\"", merchantPos, merchantEnd)

  let isOnline = parseBool(body, "\"is_online\"", terminalPos, terminalEnd)
  let cardPresent = parseBool(body, "\"card_present\"", terminalPos, terminalEnd)
  let kmFromHome = parseFloat(body, "\"km_from_home\"", terminalPos, terminalEnd)

  
  let (txHour, txDow, txMinutes) = parseTimestamp(body, reqAtLo)

  
  var hasLast = false
  var lastMinutes: int64 = 0
  var lastKm: float64 = 0.0
  if lastTxPos >= 0:
    let lastValPos = valuePos(body, "\"last_transaction\"", lastTxPos, body.len)
    if lastValPos >= 0 and body[lastValPos] == '{':
      let lastEnd = skipObject(body, lastValPos)
      var tsLo, tsHi: int
      parseStringSpan(body, "\"timestamp\"", lastValPos, lastEnd, tsLo, tsHi)
      let (_, _, lastTs) = parseTimestamp(body, tsLo)
      lastMinutes = lastTs
      lastKm = parseFloat(body, "\"km_from_current\"", lastValPos, lastEnd)
      hasLast = true

  let merchantKnown = containsExact(body, knownStart, knownEnd, midLo, midHi)

  
  vec[0] = clamp01(float32(amount) / MaxAmount)
  vec[1] = clamp01(float32(installments) / MaxInstallments)

  let avgF32 = float32(custAvg)
  if avgF32 > 0.0'f32:
    vec[2] = clamp01((float32(amount) / avgF32) / AmountVsAvgRatio)
  else:
    vec[2] = 1.0'f32

  vec[3] = float32(txHour) / 23.0'f32
  vec[4] = float32(txDow) / 6.0'f32

  if hasLast:
    let diffMin = float32(txMinutes - lastMinutes)
    vec[5] = clamp01(diffMin / MaxMinutes)
    vec[6] = clamp01(float32(lastKm) / MaxKm)
  else:
    vec[5] = -1.0'f32
    vec[6] = -1.0'f32

  vec[7] = clamp01(float32(kmFromHome) / MaxKm)
  vec[8] = clamp01(float32(txCount24h) / MaxTxCount24h)
  vec[9] = if isOnline: 1.0'f32 else: 0.0'f32
  vec[10] = if cardPresent: 1.0'f32 else: 0.0'f32
  vec[11] = if merchantKnown: 0.0'f32 else: 1.0'f32
  vec[12] = mccRisk(mcc)
  vec[13] = clamp01(float32(merchantAvg) / MaxMerchantAvgAmount)

const ResponseTable: array[6, string] = [
  "{\"approved\":true,\"fraud_score\":0.0}",
  "{\"approved\":true,\"fraud_score\":0.2}",
  "{\"approved\":true,\"fraud_score\":0.4}",
  "{\"approved\":false,\"fraud_score\":0.6}",
  "{\"approved\":false,\"fraud_score\":0.8}",
  "{\"approved\":false,\"fraud_score\":1.0}",
]

const FallbackBody = "{\"approved\":false,\"fraud_score\":1.0}"

proc responseFor(fraudCount: int): string {.inline.} =
  let idx = max(0, min(fraudCount, K))
  ResponseTable[idx]

proc scoreBody(body: string): string =
  try:
    var vec: array[D, float32]
    buildVector(body, vec)
    let count = vc_query(addr vec[0])
    responseFor(int(count))
  except CatchableError:
    
    FallbackBody

const
  TextHeaders = "Content-Type: text/plain\c\LCache-Control: no-store"
  JsonHeaders = "Content-Type: application/json\c\LCache-Control: no-store"

proc handle(req: Request): Future[void] {.gcsafe.} =
  let reqMethod = req.httpMethod()
  let path = req.path()
  if reqMethod.isSome and path.isSome:
    if reqMethod.get() == HttpPost and path.get() == "/fraud-score":
      let body = req.body()
      if body.isSome:
        req.send(Http200, scoreBody(body.get()), JsonHeaders)
      else:
        req.send(Http400, "bad request", TextHeaders)
      return nil
    if reqMethod.get() == HttpGet and path.get() == "/ready":
      req.send(Http200, "ok", TextHeaders)
      return nil

  req.send(Http404, "not found", TextHeaders)
  nil

when isMainModule:
  let portNumber = parseInt(getEnv("API_PORT", "8080"))
  let vecPath = getEnv("VECTORS_PATH", "/data/vectors.bin")
  let lblPath = getEnv("LABELS_PATH", "/data/labels.bin")
  let ivfPath = getEnv("IVF_PATH", "/data/ivf.bin")
  let workerCount = parseInt(getEnv("HTTP_THREADS", "2"))

  let rc = vc_init(vecPath.cstring, lblPath.cstring, ivfPath.cstring)
  if rc != 0:
    quit("vc_init failed (rc=" & $rc & ")", 1)

  echo "loaded ", vc_count(), " reference vectors"

  run(handle, initSettings(
    port = Port(portNumber),
    bindAddr = "0.0.0.0",
    numThreads = workerCount
  ))
