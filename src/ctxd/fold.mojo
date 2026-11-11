"""S2: fold policy on the request path.

A request whose estimate (bytes / 4) passes 0.8 W gets its oldest block outside the last K messages folded into
one placeholder user message, until the estimate is under 0.5 W. Placeholders are rebuilt from the store on every
request, so the bytes in front of the live tail stay identical between folds. Raises mean: forward unchanged."""
from std.time import perf_counter_ns
from json import Json, parse
from ctxd.curl import Curl
from ctxd.store import Store, session_dir
from bento.sync import Mutex
from std.pathlib import Path
from std.os import remove
from ctxd.tools import inject, force_path

comptime K = 6
comptime STRIPES = 64
comptime ASK = "Summarize this conversation excerpt (JSON messages, oldest first) for the assistant that continues it. Keep exact file paths, identifiers, numbers, decisions, errors and open tasks. No preamble."


struct Summarizer(Movable):
    var url: String
    var model: String
    var max_tokens: Int
    var key: String

    def __init__(out self, var url: String, var model: String, max_tokens: Int, var key: String):
        self.url = url^
        self.model = model^
        self.max_tokens = max_tokens
        self.key = key^


def _cut(m: String) -> Bool:
    """A fold may end in front of message m only if m carries no tool result (Anthropic block or OpenAI role)."""
    return '"type":"tool_result"' not in m and '"role":"tool"' not in m


def _cache_control(block: String) -> String:
    """The last cache_control object in the block ("" if none); they are flat objects."""
    var at = block.rfind('"cache_control":')
    if at < 0:
        return ""
    var lo = at + 16
    return String(block[byte=lo : lo + block[byte=lo:].find("}") + 1])


def _placeholder(st: Store, fid: Int) raises -> String:
    var rec = String(unsafe_from_utf8=st.summary(fid))
    var nl = rec.find("\n")
    var cc = String(rec[byte=:nl])
    var part = '{"type":"text","text":' + Json.of(String(rec[byte = nl + 1 :])).dumps()
    return '{"role":"user","content":[' + part + (',"cache_control":' + cc if cc != "" else "") + "}]}"


def _view(st: Store, mb: List[String]) raises -> List[String]:
    """The messages as sent: every stored fold in place of its range."""
    var out = List[String]()
    var pos = 0
    for f in range(st.fold_count()):
        for i in range(pos, Int(st.folds[4 * f])):
            out.append(mb[i])
        out.append(_placeholder(st, f))
        pos = Int(st.folds[4 * f + 1])
    for i in range(pos, len(mb)):
        out.append(mb[i])
    return out^


def _body(mut doc: Json, pieces: List[String], anthropic: Bool) raises -> List[UInt8]:
    doc.set("messages", parse("[" + ",".join(pieces) + "]"))
    inject(doc, anthropic)
    return List[UInt8](doc.dumps().as_bytes())


def _fnv(text: String) -> UInt64:
    var h: UInt64 = 14695981039346656037
    for c in text.as_bytes():
        h = (h ^ UInt64(c)) * 1099511628211
    return h


def _session(doc: Json, mb: List[String], roles: List[String], header: String) -> String:
    if header != "":
        return header
    var text = doc.get("system").dumps()
    for i in range(len(mb)):
        text += mb[i]
        if roles[i] == "user":
            break
    return "h" + String(_fnv(text))


def _summarize(curl: Curl, s: Summarizer, text: String) raises -> String:
    var req = Json.object()
    req.set("model", Json.of(s.model))
    req.set("max_tokens", Json.of(s.max_tokens))
    var ms = Json.array()
    for turn in [("system", String(ASK)), ("user", text)]:
        var m = Json.object()
        m.set("role", Json.of(String(turn[0])))
        m.set("content", Json.of(turn[1]))
        ms.push(m)
    req.set("messages", ms)
    var lines: List[String] = ["content-type: application/json"]
    if s.key != "":
        lines.append("authorization: Bearer " + s.key)
    var r = curl.fetch(s.url + "/v1/chat/completions", lines, req.dumps().as_bytes(), 120)
    if r[0] != 200:
        raise Error("summarizer http " + String(r[0]))
    var got = parse(Span(r[1])).get("choices").at(0).get("message").text("content")
    if got == "":
        raise Error("empty summary")
    return got


def _tail(mb: List[String], roles: List[String]) -> Int:
    """Start of the last K user turns (user messages that are not tool results)."""
    var turns = 0
    for i in range(len(mb) - 1, -1, -1):
        if roles[i] == "user" and _cut(mb[i]):
            turns += 1
            if turns == K:
                return i
    return 0


def rewrite(curl: Curl, s: Summarizer, window: Int, anthropic: Bool, header: String, body: Span[UInt8, _], locks: List[Mutex]) raises -> Tuple[List[UInt8], String]:
    """(the body to send upstream or empty when the original goes unchanged, the session id when it holds folds)."""
    var doc = parse(body)
    var msgs = doc.get("messages")
    var mb = List[String]()
    var roles = List[String]()
    var k = 1
    while k < Int(msgs.n[0].size):
        var m = msgs._sub(k)
        roles.append(m.text("role"))
        mb.append(m.dumps())
        k += Int(msgs.n[k].size)
    if len(mb) == 0:
        return (List[UInt8](), String())
    var sid = _session(doc, mb, roles, header)
    ref mu = locks[Int(_fnv(sid) % STRIPES)]
    mu.lock()
    try:
        var out = _fold(curl, s, window, anthropic, doc, mb, roles, sid, len(body))
        return (out^, sid if len(out) > 0 else String())
    finally:
        mu.unlock()


def _fold(curl: Curl, s: Summarizer, window: Int, anthropic: Bool, mut doc: Json, mb: List[String], roles: List[String], sid: String, raw: Int) raises -> List[UInt8]:
    var n = len(mb)
    var st = Store(session_dir(sid))
    var have = st.count()
    if have > n or (have > 0 and (String(unsafe_from_utf8=st.get(have - 1)) != mb[have - 1] or String(unsafe_from_utf8=st.get(0)) != mb[0])):
        raise Error("history of " + sid + " diverged from the store")
    for i in range(have, n):
        _ = st.append(mb[i].as_bytes())
    var cur = _body(doc, _view(st, mb), anthropic) if st.fold_count() > 0 else List[UInt8]()
    var size = len(cur) if st.fold_count() > 0 else raw
    var force = Path(force_path(sid))
    var forced = force.exists()
    if forced:
        remove(force)
    elif size * 5 <= window * 4 * 4:
        return cur^
    var a = Int(st.folds[4 * st.fold_count() - 3]) if st.fold_count() > 0 else 0
    while a == 0 and a < n and roles[a] == "system":
        a += 1
    var b = -1
    var gone = 0
    for e in range(a + 1, _tail(mb, roles) + 1):
        gone += mb[e - 1].byte_length() + 1
        if _cut(mb[e]):
            b = e
            if forced or (size - gone + s.max_tokens * 4 + 200) * 2 < window * 4:
                break
    if b < 0:
        raise Error("no fold point in " + sid + " before the last " + String(K))
    var t0 = perf_counter_ns()
    var block = String("\n").join(Span(mb)[a:b])
    var fid = st.fold_count()
    var head = "[ctxd fold " + String(fid) + ": msgs " + String(a) + "-" + String(b - 1) + "]\n"
    _ = st.fold(a, b, (_cache_control(block) + "\n" + head + _summarize(curl, s, block)).as_bytes())
    var out = _body(doc, _view(st, mb), anthropic)
    print("FOLD", sid, "id", fid, "msgs", a, "-", b - 1, "est", size // 4, "->", len(out) // 4, "us", (perf_counter_ns() - t0) // 1000, flush=True)
    return out^
