"""libcurl through dlopen. One easy handle per in-flight request, parked after use so the upstream
connection stays alive; the write callback relays each network chunk to the client as it arrives."""
from std.ffi import OwnedDLHandle
from bento.http import Request, Response
from bento.sync import Mutex

comptime _WRITEDATA = 10001
comptime _URL = 10002
comptime _POSTFIELDS = 10015
comptime _HTTPHEADER = 10023
comptime _HEADERDATA = 10029
comptime _HEADERFN = 20079
comptime _TIMEOUT = 13
comptime _POST = 47
comptime _POSTSIZE = 60
comptime _NOSIGNAL = 99
comptime _WRITEFN = 20011
comptime _CODE = 2097154
comptime _CTYPE = 1048594
comptime _DROP = ["host", "content-length", "connection", "keep-alive", "te", "trailer", "transfer-encoding",
                  "upgrade", "expect", "accept-encoding", "proxy-connection", "proxy-authorization", "x-ctxd-session"]


struct Relay(Movable):
    var lib: Int
    var h: Int
    var resp: Int  # address of the client Response, or 0 when the body goes to `sink`
    var sink: Int  # address of a List[UInt8] that collects the body (fetch), or 0
    var begun: Bool
    var sse: Bool
    var heads: List[String]

    def __init__(out self, lib: Int, h: Int, resp: Int, sink: Int):
        self.lib = lib
        self.h = h
        self.resp = resp
        self.sink = sink
        self.begun = False
        self.sse = False
        self.heads = List[String]()


def _info(lib: Int, h: Int, what: Int) -> Int:
    var out = 0
    _ = Pointer[OwnedDLHandle, MutUntrackedOrigin](unsafe_from_address=lib)[].call["curl_easy_getinfo", Int32](
        h, Int32(what), Int(Pointer(to=out)))
    return out


def _c(mut s: String) -> Int:
    return Int(s.as_c_string_span().ptr())


def _on_head(data: Int, size: Int, n: Int, ud: Int) abi("C") -> Int:
    var r = Pointer[Relay, MutUntrackedOrigin](unsafe_from_address=ud)
    var line = String(StringSlice(unsafe_from_utf8=Span(
        unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=data), length=size * n)).strip())
    if line.startswith("HTTP/"):
        r[].heads.clear()
    elif line.byte_length() > 0:
        r[].heads.append(line)
    return size * n


def relay_heads(heads: List[String], mut resp: Response):
    """Upstream headers to the client, hop-by-hop and the ones the head writer sets itself dropped."""
    for line in heads:
        var at = line.find(":")
        var name = String(line[byte=:at]).lower()
        if at > 0 and name not in materialize[_DROP]() and name != "content-type":
            resp.add(name, String(line[byte = at + 1 :].strip()))


def _on_chunk(data: Int, size: Int, n: Int, ud: Int) abi("C") -> Int:
    var r = Pointer[Relay, MutUntrackedOrigin](unsafe_from_address=ud)
    if r[].sink != 0:
        Pointer[List[UInt8], MutUntrackedOrigin](unsafe_from_address=r[].sink)[].extend(Span(
            unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=data), length=size * n))
        return size * n
    var resp = Pointer[Response, MutUntrackedOrigin](unsafe_from_address=r[].resp)
    try:
        if not r[].begun:
            r[].begun = True
            var ct = _info(r[].lib, r[].h, _CTYPE)
            var kind = String("application/octet-stream")
            if ct != 0:
                kind = String(StringSlice(unsafe_from_utf8=Span(
                    unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=ct),
                    length=Pointer[OwnedDLHandle, MutUntrackedOrigin](unsafe_from_address=r[].lib)[].call["strlen", Int](ct))))
            r[].sse = kind.startswith("text/event-stream")
            relay_heads(r[].heads, resp[])
            resp[].begin_stream(kind, _info(r[].lib, r[].h, _CODE))
        resp[].write(Span(unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=data), length=size * n))
    except:
        return 0
    return size * n


struct Curl(Movable):
    var lib: OwnedDLHandle
    var idle: List[Int]
    var mu: Mutex

    def __init__(out self) raises:
        self.lib = OwnedDLHandle("/usr/lib/libcurl.so.4")
        self.idle = List[Int]()
        self.mu = Mutex()

    def _opt(self, h: Int, opt: Int, v: Int):
        _ = self.lib.call["curl_easy_setopt", Int32](h, Int32(opt), v)

    def _take(self) -> Int:
        var idle = Pointer[List[Int], MutUntrackedOrigin](unsafe_from_address=Int(Pointer(to=self.idle)))
        self.mu.lock()
        var h = idle[].pop() if len(idle[]) > 0 else 0
        self.mu.unlock()
        return h if h != 0 else self.lib.call["curl_easy_init", Int]()

    def _park(self, h: Int):
        var idle = Pointer[List[Int], MutUntrackedOrigin](unsafe_from_address=Int(Pointer(to=self.idle)))
        self.mu.lock()
        idle[].append(h)
        self.mu.unlock()

    def _send(self, var url: String, lines: List[String], body: Span[UInt8, _], timeout: Int, mut relay: Relay) -> Int32:
        var list = 0
        for i in range(len(lines)):
            var line = lines[i]
            list = self.lib.call["curl_slist_append", Int](list, _c(line))
        var off = String("expect:")
        list = self.lib.call["curl_slist_append", Int](list, _c(off))
        self._opt(relay.h, _URL, _c(url))
        self._opt(relay.h, _NOSIGNAL, 1)
        self._opt(relay.h, _TIMEOUT, timeout)
        self._opt(relay.h, _POST, 1)
        self._opt(relay.h, _POSTFIELDS, Int(body.unsafe_ptr()))
        self._opt(relay.h, _POSTSIZE, len(body))
        self._opt(relay.h, _HTTPHEADER, list)
        self._opt(relay.h, _WRITEDATA, Int(Pointer(to=relay)))
        self._opt(relay.h, _HEADERDATA, Int(Pointer(to=relay)))
        _ = self.lib.call["curl_easy_setopt", Int32](relay.h, Int32(_WRITEFN), _on_chunk)
        _ = self.lib.call["curl_easy_setopt", Int32](relay.h, Int32(_HEADERFN), _on_head)
        var rc = self.lib.call["curl_easy_perform", Int32](relay.h)
        self.lib.call["curl_slist_free_all"](list)
        return rc

    def post(self, var url: String, req: Request, body: Span[UInt8, _], anthropic: Bool, mut resp: Response) raises:
        """Send `body` to url with req's headers (hop-by-hop dropped) and stream the answer into resp. A stream
        that breaks after it began ends with an SSE error frame in the client's format (Anthropic or OpenAI)."""
        var lines = lines_of(req)
        var relay = Relay(Int(Pointer(to=self.lib)), self._take(), Int(Pointer(to=resp)), 0)
        var rc = self._send(url, lines, body, 0, relay)
        if rc != 0:
            self.lib.call["curl_easy_cleanup"](relay.h)
            var why = "ctxd: upstream curl rc " + String(rc)
            if relay.sse:
                resp.sse(
                    '{"type":"error","error":{"type":"api_error","message":"' + why + '"}}' if anthropic
                    else '{"error":{"message":"' + why + '","type":"upstream_error","code":null}}',
                    "error",
                )
                resp.end_stream()
            elif relay.begun:
                raise Error(why)
            else:
                resp = Response.text(502, why + "\n")
            return
        var code = _info(Int(Pointer(to=self.lib)), relay.h, _CODE)
        self._park(relay.h)
        if relay.begun:
            resp.end_stream()
        else:
            relay_heads(relay.heads, resp)
            resp.status = code

    def fetch(self, var url: String, lines: List[String], body: Span[UInt8, _], timeout: Int) raises -> Tuple[Int, List[UInt8], List[String]]:
        """POST and collect the whole answer: (status, body, response header lines)."""
        var out = List[UInt8]()
        var relay = Relay(Int(Pointer(to=self.lib)), self._take(), 0, Int(Pointer(to=out)))
        var rc = self._send(url, lines, body, timeout, relay)
        if rc != 0:
            self.lib.call["curl_easy_cleanup"](relay.h)
            raise Error("curl rc " + String(rc))
        var code = _info(Int(Pointer(to=self.lib)), relay.h, _CODE)
        self._park(relay.h)
        return (code, out^, relay.heads.copy())


def lines_of(req: Request) -> List[String]:
    """req's headers as curl lines, hop-by-hop and content-length dropped."""
    var lines = List[String]()
    for i in range(len(req.names)):
        if req.names[i] not in materialize[_DROP]():
            lines.append(req.names[i] + ": " + req.values[i])
    return lines^
