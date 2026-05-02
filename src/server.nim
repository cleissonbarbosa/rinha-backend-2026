import std/[asynchttpserver, asyncdispatch, math, os, strutils]

const
  KAmount = "\"amount\""
  KInstallments = "\"installments\""
  KAvgAmount = "\"avg_amount\""
  KTxCount24h = "\"tx_count_24h\""
  KKnownMerchants = "\"known_merchants\""
  KId = "\"id\""
  KMcc = "\"mcc\""
  KKmFromHome = "\"km_from_home\""

type
  TxPayload = object
    amount: float64
    installments: int
    customerAvgAmount: float64
    txCount24h: int
    merchantId: string
    merchantKnown: bool
    mccCode: int
    kmFromHome: float64

proc fraudScoreCore(
  amount: cdouble,
  installments: cint,
  customerAvgAmount: cdouble,
  txCount24h: cint,
  merchantKnown: cint,
  mccCode: cint,
  kmFromHome: cdouble
): cint {.importc: "fraud_score_core".}

proc digit(s: string; i: int): int {.inline.} =
  ord(s[i]) - ord('0')

proc valuePos(s, key: string; start: int): int =
  let keyPos = s.find(key, start)
  if keyPos < 0:
    raise newException(ValueError, "missing key")

  let colon = s.find(':', keyPos + key.len)
  if colon < 0:
    raise newException(ValueError, "missing colon")

  result = colon + 1
  while result < s.len and (s[result] == ' ' or s[result] == '\n' or s[result] == '\r' or s[result] == '\t'):
    inc result

proc parseFloatValue(s: string; p0: int): float64 =
  var p = p0
  var sign = 1.0
  if s[p] == '-':
    sign = -1.0
    inc p

  var value = 0.0
  while p < s.len and s[p] >= '0' and s[p] <= '9':
    value = value * 10.0 + float64(digit(s, p))
    inc p

  if p < s.len and s[p] == '.':
    inc p
    var scale = 0.1
    while p < s.len and s[p] >= '0' and s[p] <= '9':
      value += float64(digit(s, p)) * scale
      scale *= 0.1
      inc p

  if p < s.len and (s[p] == 'e' or s[p] == 'E'):
    inc p
    var expSign = 1
    if s[p] == '-':
      expSign = -1
      inc p
    elif s[p] == '+':
      inc p

    var exponent = 0
    while p < s.len and s[p] >= '0' and s[p] <= '9':
      exponent = exponent * 10 + digit(s, p)
      inc p
    value *= pow(10.0, float64(expSign * exponent))

  sign * value

proc parseFloatAfter(s, key: string; start: int): float64 {.inline.} =
  parseFloatValue(s, valuePos(s, key, start))

proc parseIntAfter(s, key: string; start: int): int =
  var p = valuePos(s, key, start)
  var sign = 1
  if s[p] == '-':
    sign = -1
    inc p

  var value = 0
  while p < s.len and s[p] >= '0' and s[p] <= '9':
    value = value * 10 + digit(s, p)
    inc p
  sign * value

proc parseStringAfter(s, key: string; start: int): string =
  var p = valuePos(s, key, start)
  if s[p] != '"':
    raise newException(ValueError, "string expected")
  inc p
  let q = s.find('"', p)
  if q < 0:
    raise newException(ValueError, "unterminated string")
  s.substr(p, q - 1)

proc parseCodeAfter(s, key: string; start: int): int =
  var p = valuePos(s, key, start)
  if s[p] == '"':
    inc p

  var value = 0
  while p < s.len and s[p] >= '0' and s[p] <= '9':
    value = value * 10 + digit(s, p)
    inc p
  value

proc containsQuotedValue(s: string; start, stop: int; needle: string): bool =
  var p = start
  while p < stop:
    if s[p] == '"':
      let valueStart = p + 1
      let valueStop = valueStart + needle.len
      if valueStop < stop and s[valueStop] == '"':
        var same = true
        var i = 0
        while i < needle.len:
          if s[valueStart + i] != needle[i]:
            same = false
            break
          inc i
        if same:
          return true
      p = valueStop
    else:
      inc p
  false

proc parsePayload(body: string): TxPayload =
  let txPos = body.find("\"transaction\"")
  let customerPos = body.find("\"customer\"")
  let merchantPos = body.find("\"merchant\"")
  let terminalPos = body.find("\"terminal\"")

  if txPos < 0 or customerPos < 0 or merchantPos < 0 or terminalPos < 0:
    raise newException(ValueError, "invalid payload")

  result.amount = parseFloatAfter(body, KAmount, txPos)
  result.installments = parseIntAfter(body, KInstallments, txPos)

  result.customerAvgAmount = parseFloatAfter(body, KAvgAmount, customerPos)
  result.txCount24h = parseIntAfter(body, KTxCount24h, customerPos)

  result.merchantId = parseStringAfter(body, KId, merchantPos)
  result.mccCode = parseCodeAfter(body, KMcc, merchantPos)

  let knownArrayStart = valuePos(body, KKnownMerchants, customerPos)
  let knownArrayEnd = body.find(']', knownArrayStart)
  if knownArrayEnd < 0:
    raise newException(ValueError, "invalid known merchants")
  result.merchantKnown = containsQuotedValue(body, knownArrayStart, knownArrayEnd, result.merchantId)

  result.kmFromHome = parseFloatAfter(body, KKmFromHome, terminalPos)

proc responseFor(scoreCode: int): string {.inline.} =
  case scoreCode
  of 0:
    "{\"approved\":true,\"fraud_score\":0.0}"
  of 10:
    "{\"approved\":false,\"fraud_score\":1.0}"
  of 8:
    "{\"approved\":false,\"fraud_score\":0.8}"
  else:
    "{\"approved\":false,\"fraud_score\":0.6}"

proc scoreBody(body: string): string =
  try:
    let payload = parsePayload(body)
    let scoreCode = fraudScoreCore(
      payload.amount,
      cint(payload.installments),
      payload.customerAvgAmount,
      cint(payload.txCount24h),
      if payload.merchantKnown: 1.cint else: 0.cint,
      cint(payload.mccCode),
      payload.kmFromHome
    )
    responseFor(int(scoreCode))
  except CatchableError:
    "{\"approved\":false,\"fraud_score\":1.0}"

proc handle(req: Request) {.async, gcsafe.} =
  if req.reqMethod == HttpGet and req.url.path == "/ready":
    let textHeaders = newHttpHeaders([
      ("Content-Type", "text/plain"),
      ("Cache-Control", "no-store")
    ])
    await req.respond(Http200, "ok", textHeaders)
  elif req.reqMethod == HttpPost and req.url.path == "/fraud-score":
    let jsonHeaders = newHttpHeaders([
      ("Content-Type", "application/json"),
      ("Cache-Control", "no-store")
    ])
    await req.respond(Http200, scoreBody(req.body), jsonHeaders)
  else:
    let textHeaders = newHttpHeaders([
      ("Content-Type", "text/plain"),
      ("Cache-Control", "no-store")
    ])
    await req.respond(Http404, "not found", textHeaders)

when isMainModule:
  let portNumber = parseInt(getEnv("API_PORT", "8080"))
  let server = newAsyncHttpServer()
  let callback = proc(req: Request): Future[void] {.closure, gcsafe.} =
    handle(req)
  waitFor server.serve(Port(portNumber), callback, address = "0.0.0.0")
