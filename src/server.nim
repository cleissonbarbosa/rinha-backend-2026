import std/[math, os, posix, strutils]

{.passC: "-D_GNU_SOURCE".}

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


proc vc_init(vecPath: cstring; lblPath: cstring; resPath: cstring; ivfPath: cstring): cint {.importc, gcsafe.}
proc vc_count(): csize_t {.importc, gcsafe.}
proc vc_query(query: ptr float32): cint {.importc, gcsafe.}


template isDigit(c: char): bool = c >= '0' and c <= '9'

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
  # Sections always appear in this fixed order in the rinha payload, so each
  # find can resume from the previous match — one linear scan instead of five.
  let txPos = body.find("\"transaction\"")
  if txPos < 0: raise newException(ValueError, "missing section")
  let customerPos = body.find("\"customer\"", txPos + 1)
  if customerPos < 0: raise newException(ValueError, "missing section")
  let merchantPos = body.find("\"merchant\"", customerPos + 1)
  if merchantPos < 0: raise newException(ValueError, "missing section")
  let terminalPos = body.find("\"terminal\"", merchantPos + 1)
  if terminalPos < 0: raise newException(ValueError, "missing section")
  let lastTxPos = body.find("\"last_transaction\"", terminalPos + 1)

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


# ============================================================================
# Custom epoll-based HTTP server.
#
# We bypass httpbeast entirely. The hot path is:
#   read request → locate body → buildVector → vc_query → write precomputed response.
# Each worker thread owns a dedicated listening socket (SO_REUSEPORT) and an
# epoll instance. Connections are kept in a fixed thread-local pool with
# edge-triggered events so the steady state runs without epoll_ctl mods.
# ============================================================================

const
  EPOLLIN_C: uint32 = 0x001'u32
  EPOLLOUT_C: uint32 = 0x004'u32
  EPOLLERR_C: uint32 = 0x008'u32
  EPOLLHUP_C: uint32 = 0x010'u32
  EPOLLRDHUP_C: uint32 = 0x2000'u32
  EPOLLET_C: uint32 = 0x80000000'u32
  EPOLL_CTL_ADD_C: cint = 1
  EPOLL_CLOEXEC_C: cint = 0o2000000.cint
  TCP_NODELAY_C: cint = 1
  TCP_DEFER_ACCEPT_C: cint = 9
  IPPROTO_TCP_C: cint = 6
  SO_REUSEADDR_C: cint = 2
  SO_REUSEPORT_C: cint = 15
  SOL_SOCKET_C: cint = 1
  SOCK_CLOEXEC_NIM: cint = 0o2000000.cint
  SOCK_NONBLOCK_NIM: cint = 0o4000.cint

type
  EpollData {.importc: "epoll_data_t", header: "<sys/epoll.h>", union.} = object
    `ptr`: pointer
    fd: cint
    u32: uint32
    u64: uint64
  EpollEvent {.importc: "struct epoll_event", header: "<sys/epoll.h>".} = object
    events: uint32
    data: EpollData

proc epoll_create1(flags: cint): cint {.importc, header: "<sys/epoll.h>".}
proc epoll_ctl(epfd: cint, op: cint, fd: cint, event: ptr EpollEvent): cint {.importc, header: "<sys/epoll.h>".}
proc epoll_wait(epfd: cint, events: ptr EpollEvent, maxevents: cint, timeout: cint): cint {.importc, header: "<sys/epoll.h>".}
proc accept4(sockfd: cint, addr1: ptr SockAddr, addrlen: ptr SockLen, flags: cint): cint {.importc, header: "<sys/socket.h>".}

type
  ConnState = enum
    csFree, csReadReq, csWriteResp

  Conn = object
    state: ConnState
    fd: cint
    reqUsed: int
    reqTotal: int
    respPos: int
    respLen: int
    respPtr: ptr UncheckedArray[char]
    reqBuf: array[2048, char]

const
  MaxConnPerWorker = 512
  MaxEpollEvents = 256

# ----------------------------------------------------------------------------
# Pre-computed full HTTP responses (status line + headers + body).
# ----------------------------------------------------------------------------

let RespFraud0 = "HTTP/1.1 200 OK\r\nContent-Length: 35\r\nContent-Type: application/json\r\n\r\n{\"approved\":true,\"fraud_score\":0.0}"
let RespFraud1 = "HTTP/1.1 200 OK\r\nContent-Length: 35\r\nContent-Type: application/json\r\n\r\n{\"approved\":true,\"fraud_score\":0.2}"
let RespFraud2 = "HTTP/1.1 200 OK\r\nContent-Length: 35\r\nContent-Type: application/json\r\n\r\n{\"approved\":true,\"fraud_score\":0.4}"
let RespFraud3 = "HTTP/1.1 200 OK\r\nContent-Length: 36\r\nContent-Type: application/json\r\n\r\n{\"approved\":false,\"fraud_score\":0.6}"
let RespFraud4 = "HTTP/1.1 200 OK\r\nContent-Length: 36\r\nContent-Type: application/json\r\n\r\n{\"approved\":false,\"fraud_score\":0.8}"
let RespFraud5 = "HTTP/1.1 200 OK\r\nContent-Length: 36\r\nContent-Type: application/json\r\n\r\n{\"approved\":false,\"fraud_score\":1.0}"
let RespReady  = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: text/plain\r\n\r\nok"
let RespBadReq = "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\nContent-Type: text/plain\r\n\r\nbad request"
let RespNotFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nContent-Type: text/plain\r\n\r\nnot found"

var fraudResp: array[6, ptr UncheckedArray[char]]
var fraudRespLen: array[6, int]
var readyRespPtr, badRespPtr, notFoundRespPtr: ptr UncheckedArray[char]
var readyRespLen, badRespLen, notFoundRespLen: int

proc initResponses() =
  fraudResp[0] = cast[ptr UncheckedArray[char]](unsafeAddr RespFraud0[0])
  fraudResp[1] = cast[ptr UncheckedArray[char]](unsafeAddr RespFraud1[0])
  fraudResp[2] = cast[ptr UncheckedArray[char]](unsafeAddr RespFraud2[0])
  fraudResp[3] = cast[ptr UncheckedArray[char]](unsafeAddr RespFraud3[0])
  fraudResp[4] = cast[ptr UncheckedArray[char]](unsafeAddr RespFraud4[0])
  fraudResp[5] = cast[ptr UncheckedArray[char]](unsafeAddr RespFraud5[0])
  fraudRespLen[0] = RespFraud0.len
  fraudRespLen[1] = RespFraud1.len
  fraudRespLen[2] = RespFraud2.len
  fraudRespLen[3] = RespFraud3.len
  fraudRespLen[4] = RespFraud4.len
  fraudRespLen[5] = RespFraud5.len
  readyRespPtr = cast[ptr UncheckedArray[char]](unsafeAddr RespReady[0])
  readyRespLen = RespReady.len
  badRespPtr = cast[ptr UncheckedArray[char]](unsafeAddr RespBadReq[0])
  badRespLen = RespBadReq.len
  notFoundRespPtr = cast[ptr UncheckedArray[char]](unsafeAddr RespNotFound[0])
  notFoundRespLen = RespNotFound.len

# ----------------------------------------------------------------------------
# Per-worker state (thread-local).
# ----------------------------------------------------------------------------

var pool {.threadvar.}: array[MaxConnPerWorker, Conn]
var freeStack {.threadvar.}: array[MaxConnPerWorker, int32]
var freeTop {.threadvar.}: int
var epfd {.threadvar.}: cint
var listenFd {.threadvar.}: cint
var bodyTmp {.threadvar.}: string

proc allocIdx(): int {.inline.} =
  if freeTop == 0: return -1
  dec freeTop
  result = int(freeStack[freeTop])

proc releaseIdx(idx: int) {.inline.} =
  freeStack[freeTop] = int32(idx)
  inc freeTop

proc setNonBlock(fd: cint) {.inline.} =
  let flags = fcntl(fd, F_GETFL, 0)
  if flags >= 0:
    discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

proc setIntOpt(fd: cint; level, opt: cint; val: cint) {.inline.} =
  var v = val
  discard setsockopt(SocketHandle(fd), level, opt, addr v, SockLen(sizeof(cint)))

proc epollAdd(fd: cint; events: uint32; key: uint64): bool {.inline.} =
  var ev: EpollEvent
  ev.events = events
  ev.data.u64 = key
  epoll_ctl(epfd, EPOLL_CTL_ADD_C, fd, addr ev) == 0

proc closeConn(idx: int) =
  var p = addr pool[idx]
  if p.state == csFree: return
  if p.fd >= 0:
    discard close(p.fd)
    p.fd = -1
  p.state = csFree
  p.reqUsed = 0
  p.reqTotal = 0
  p.respPos = 0
  p.respLen = 0
  releaseIdx(idx)

# ----------------------------------------------------------------------------
# HTTP request framing: locate end of headers and Content-Length.
# ----------------------------------------------------------------------------

proc findHeaderEnd(buf: ptr UncheckedArray[char]; used: int): int =
  if used < 4: return -1
  var i = 0
  let limit = used - 3
  while i < limit:
    if buf[i] == '\r' and buf[i+1] == '\n' and buf[i+2] == '\r' and buf[i+3] == '\n':
      return i + 4
    inc i
  -1

proc parseContentLength(buf: ptr UncheckedArray[char]; headerLen: int): int =
  if headerLen < 17: return 0
  let limit = headerLen - 16
  var i = 0
  while i < limit:
    let lineStart = i == 0 or (i >= 2 and buf[i-2] == '\r' and buf[i-1] == '\n')
    if not lineStart:
      inc i
      continue
    var match = true
    const tag = "content-length:"
    for k in 0..<15:
      var c = buf[i+k]
      if c >= 'A' and c <= 'Z':
        c = chr(ord(c) or 0x20)
      if c != tag[k]:
        match = false
        break
    if match:
      var p = i + 15
      while p < headerLen and (buf[p] == ' ' or buf[p] == '\t'):
        inc p
      var n = 0
      while p < headerLen and buf[p] >= '0' and buf[p] <= '9':
        n = n * 10 + (ord(buf[p]) - ord('0'))
        inc p
      return n
    inc i
  0

proc tryParseRequest(buf: ptr UncheckedArray[char]; used: int): int =
  let h = findHeaderEnd(buf, used)
  if h < 0: return -1
  h + parseContentLength(buf, h)

# ----------------------------------------------------------------------------
# Routing: minimal HTTP method+path inspection.
# ----------------------------------------------------------------------------

type Route = enum
  rtFraudScore, rtReady, rtUnknown

proc routeFor(buf: ptr UncheckedArray[char]; used: int): Route =
  # used >= header end; fast tags: "POST /fraud-score" or "GET /ready"
  if used >= 17 and buf[0] == 'P' and buf[1] == 'O' and buf[2] == 'S' and buf[3] == 'T' and
      buf[4] == ' ' and buf[5] == '/' and buf[6] == 'f' and buf[7] == 'r' and buf[8] == 'a' and
      buf[9] == 'u' and buf[10] == 'd' and buf[11] == '-' and buf[12] == 's' and buf[13] == 'c' and
      buf[14] == 'o' and buf[15] == 'r' and buf[16] == 'e':
    return rtFraudScore
  if used >= 10 and buf[0] == 'G' and buf[1] == 'E' and buf[2] == 'T' and
      buf[3] == ' ' and buf[4] == '/' and buf[5] == 'r' and buf[6] == 'e' and buf[7] == 'a' and
      buf[8] == 'd' and buf[9] == 'y':
    return rtReady
  rtUnknown

# ----------------------------------------------------------------------------
# Score computation: copy body bytes into a thread-local string and reuse the
# existing parser. The 600-byte memcpy is negligible compared with the parser
# cost and keeps buildVector unmodified.
# ----------------------------------------------------------------------------

proc scoreFromBody(buf: ptr UncheckedArray[char]; bodyStart, bodyEnd: int): int =
  let length = bodyEnd - bodyStart
  if length <= 0:
    return -1
  if bodyTmp.len < length:
    bodyTmp.setLen(length)
  bodyTmp.setLen(length)
  copyMem(addr bodyTmp[0], addr buf[bodyStart], length)
  try:
    var vec: array[D, float32]
    buildVector(bodyTmp, vec)
    let count = vc_query(addr vec[0])
    let idx = max(0, min(int(count), K))
    return idx
  except CatchableError:
    return K  # fallback: max fraud

# ----------------------------------------------------------------------------
# Connection drivers.
# ----------------------------------------------------------------------------

proc driveWrite(idx: int) =
  var p = addr pool[idx]
  while p.respPos < p.respLen:
    let n = posix.send(SocketHandle(p.fd),
                       cast[pointer](addr p.respPtr[p.respPos]),
                       p.respLen - p.respPos, 0)
    if n > 0:
      p.respPos += n
    elif n == 0:
      closeConn(idx)
      return
    else:
      let e = errno
      if e == EAGAIN or e == EWOULDBLOCK:
        return
      if e == EINTR:
        continue
      closeConn(idx)
      return

  # Response fully written; ready for next request on the same connection.
  let leftover = p.reqUsed - p.reqTotal
  if leftover > 0:
    moveMem(addr p.reqBuf[0], addr p.reqBuf[p.reqTotal], leftover)
  p.reqUsed = leftover
  p.reqTotal = 0
  p.respPos = 0
  p.respLen = 0
  p.state = csReadReq

proc handleRequest(idx: int) =
  var p = addr pool[idx]
  let bufp = cast[ptr UncheckedArray[char]](addr p.reqBuf[0])
  let route = routeFor(bufp, p.reqUsed)
  case route
  of rtFraudScore:
    let h = findHeaderEnd(bufp, p.reqUsed)
    let bodyEnd = p.reqTotal
    let r = scoreFromBody(bufp, h, bodyEnd)
    p.respPtr = fraudResp[r]
    p.respLen = fraudRespLen[r]
  of rtReady:
    p.respPtr = readyRespPtr
    p.respLen = readyRespLen
  of rtUnknown:
    p.respPtr = notFoundRespPtr
    p.respLen = notFoundRespLen
  p.respPos = 0
  p.state = csWriteResp
  driveWrite(idx)

proc driveRead(idx: int) =
  var p = addr pool[idx]
  let bufp = cast[ptr UncheckedArray[char]](addr p.reqBuf[0])
  while p.reqUsed < p.reqBuf.len:
    let n = posix.recv(SocketHandle(p.fd),
                      cast[pointer](addr p.reqBuf[p.reqUsed]),
                      p.reqBuf.len - p.reqUsed, 0)
    if n > 0:
      p.reqUsed += n
    elif n == 0:
      closeConn(idx)
      return
    else:
      let e = errno
      if e == EAGAIN or e == EWOULDBLOCK:
        break
      if e == EINTR:
        continue
      closeConn(idx)
      return

  if p.reqTotal == 0:
    let total = tryParseRequest(bufp, p.reqUsed)
    if total > 0:
      if total > p.reqBuf.len:
        # Body too large for fixed buffer.
        p.respPtr = badRespPtr
        p.respLen = badRespLen
        p.respPos = 0
        p.state = csWriteResp
        driveWrite(idx)
        return
      p.reqTotal = total

  if p.reqTotal > 0 and p.reqUsed >= p.reqTotal:
    handleRequest(idx)

proc handleAccept() =
  while true:
    let cfd = accept4(listenFd, nil, nil, SOCK_NONBLOCK_NIM or SOCK_CLOEXEC_NIM)
    if cfd < 0:
      let e = errno
      if e == EAGAIN or e == EWOULDBLOCK or e == EINTR:
        return
      return
    let idx = allocIdx()
    if idx < 0:
      discard close(cfd)
      continue
    var p = addr pool[idx]
    p.fd = cfd
    p.state = csReadReq
    p.reqUsed = 0
    p.reqTotal = 0
    p.respPos = 0
    p.respLen = 0

    let key = (uint64(idx) shl 1) or 1'u64
    if not epollAdd(cfd, EPOLLIN_C or EPOLLOUT_C or EPOLLRDHUP_C or EPOLLET_C, key):
      discard close(cfd)
      p.fd = -1
      releaseIdx(idx)
      continue
    # Drain any data that already arrived (TCP_DEFER_ACCEPT-friendly).
    driveRead(idx)

proc handleEvent(idx: int; events: uint32) =
  var p = addr pool[idx]
  if p.state == csFree:
    return
  if (events and (EPOLLERR_C or EPOLLHUP_C)) != 0:
    closeConn(idx)
    return
  case p.state
  of csReadReq:
    if (events and EPOLLIN_C) != 0:
      driveRead(idx)
    elif (events and EPOLLRDHUP_C) != 0:
      closeConn(idx)
  of csWriteResp:
    if (events and EPOLLOUT_C) != 0:
      driveWrite(idx)
    elif (events and EPOLLRDHUP_C) != 0:
      closeConn(idx)
  of csFree:
    discard

proc createListener(port: uint16): cint =
  let sh = posix.socket(AF_INET, SOCK_STREAM or SOCK_NONBLOCK_NIM or SOCK_CLOEXEC_NIM, 0)
  if sh.cint < 0:
    raise newException(OSError, "socket failed")
  let fd = sh.cint
  setIntOpt(fd, SOL_SOCKET_C, SO_REUSEADDR_C, 1)
  setIntOpt(fd, SOL_SOCKET_C, SO_REUSEPORT_C, 1)
  setIntOpt(fd, IPPROTO_TCP_C, TCP_NODELAY_C, 1)
  setIntOpt(fd, IPPROTO_TCP_C, TCP_DEFER_ACCEPT_C, 1)

  var sa: Sockaddr_in
  sa.sin_family = TSa_Family(AF_INET)
  sa.sin_port = posix.htons(port)
  sa.sin_addr.s_addr = posix.htonl(INADDR_ANY)
  if posix.bindSocket(sh,
                      cast[ptr SockAddr](addr sa),
                      SockLen(sizeof(sa))) != 0:
    raise newException(OSError, "bind failed")
  if posix.listen(sh, 4096) != 0:
    raise newException(OSError, "listen failed")
  return fd

proc workerLoop(port: uint16) {.gcsafe.} =
  freeTop = 0
  for i in 0..<MaxConnPerWorker:
    pool[i].fd = -1
    pool[i].state = csFree
    freeStack[i] = int32(MaxConnPerWorker - 1 - i)
  freeTop = MaxConnPerWorker

  listenFd = createListener(port)
  epfd = epoll_create1(EPOLL_CLOEXEC_C)
  if epfd < 0:
    raise newException(OSError, "epoll_create1 failed")
  # Listener key uses bit 0 = 0; connection keys use bit 0 = 1.
  if not epollAdd(listenFd, EPOLLIN_C, 0'u64):
    raise newException(OSError, "epoll_ctl listener failed")

  var events: array[MaxEpollEvents, EpollEvent]
  while true:
    let n = epoll_wait(epfd, addr events[0], cint(MaxEpollEvents), -1)
    if n < 0:
      if errno == EINTR: continue
      raise newException(OSError, "epoll_wait failed")
    for i in 0..<n:
      let key = events[i].data.u64
      if key == 0'u64:
        handleAccept()
      else:
        let idx = int(key shr 1)
        handleEvent(idx, events[i].events)

# ----------------------------------------------------------------------------
# Main: spawn worker threads.
# ----------------------------------------------------------------------------

type
  WorkerArgs = object
    port: uint16

proc workerThreadEntry(arg: WorkerArgs) {.thread.} =
  workerLoop(arg.port)

when isMainModule:
  signal(SIGPIPE, SIG_IGN)
  initResponses()

  let portNumber = uint16(parseInt(getEnv("API_PORT", "8080")))
  let vecPath = getEnv("VECTORS_PATH", "/data/vectors.bin")
  let lblPath = getEnv("LABELS_PATH", "/data/labels.bin")
  let resPath = getEnv("RESIDUALS_PATH", "/data/residuals.bin")
  let ivfPath = getEnv("IVF_PATH", "/data/ivf.bin")
  let workerCount = parseInt(getEnv("HTTP_THREADS", "2"))

  let rc = vc_init(vecPath.cstring, lblPath.cstring, resPath.cstring, ivfPath.cstring)
  if rc != 0:
    quit("vc_init failed (rc=" & $rc & ")", 1)

  echo "loaded ", vc_count(), " reference vectors; workers=", workerCount

  if workerCount <= 1:
    workerLoop(portNumber)
  else:
    var threads = newSeq[Thread[WorkerArgs]](workerCount - 1)
    let args = WorkerArgs(port: portNumber)
    for i in 0..<workerCount - 1:
      createThread(threads[i], workerThreadEntry, args)
    workerLoop(portNumber)
    for i in 0..<workerCount - 1:
      joinThread(threads[i])
