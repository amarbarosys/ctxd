"""S3: ctx_expand / ctx_search / compress. Offered only to sessions that hold folds; ctxd runs these calls itself
(upstream asked without streaming, at most ROUNDS rounds) and answers the client with the final message, replayed as
SSE when the client asked to stream. A message that mixes ctx calls with client tools goes out without the ctx calls."""
from std.pathlib import Path
from json import Json, parse
from bento.http import Request, Response
from ctxd.curl import Curl, lines_of, relay_heads
from ctxd.store import Store, session_dir

comptime ROUNDS = 4
comptime CAP = 60000
comptime NAMES = ["ctx_expand", "ctx_search", "compress"]
comptime DESC = [
    "Return the original messages behind a [ctxd fold <id>] placeholder, byte for byte.",
    "Search the original messages of this session (folded ones included) for an exact substring.",
    "Ask ctxd to fold older history now instead of at the window threshold.",
]
comptime PROPS = [
    '{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}',
    '{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}',
    '{"type":"object","properties":{}}',
]


def inject(mut doc: Json, anthropic: Bool) raises:
    var tools = doc.get("tools") if doc.has("tools") else Json.array()
    if '"ctx_expand"' in tools.dumps():
        return
    for i in range(3):
        var t = Json.object()
        if anthropic:
            t.set("name", Json.of(String(materialize[NAMES]()[i])))
            t.set("description", Json.of(String(materialize[DESC]()[i])))
            t.set("input_schema", parse(materialize[PROPS]()[i]))
        else:
            var f = Json.object()
            f.set("name", Json.of(String(materialize[NAMES]()[i])))
            f.set("description", Json.of(String(materialize[DESC]()[i])))
            f.set("parameters", parse(materialize[PROPS]()[i]))
            t.set("type", Json.of(String("function")))
            t.set("function", f)
        tools.push(t)
    doc.set("tools", tools)


def force_path(sid: String) raises -> String:
    return session_dir(sid) + "/force"


def run(sid: String, name: String, args: Json) raises -> String:
    var st = Store(session_dir(sid))
    var out: String
    if name == "ctx_expand":
        var id = args.get("id").int()
        if id < 0 or id >= st.fold_count():
            return "no fold " + String(id) + " (this session has " + String(st.fold_count()) + ")"
        out = String(unsafe_from_utf8=st.expand(id))
    elif name == "ctx_search":
        out = String()
        var hits = st.search(args.text("query"))
        for i in range(min(len(hits), 20)):
            var m = String(unsafe_from_utf8=st.get(hits[i]))
            out += "msg " + String(hits[i]) + ": " + String(m[byte = : min(m.byte_length(), 400)]) + "\n"
        if out == "":
            out = "no match"
    else:
        Path(force_path(sid)).write_text("1")
        return "ok: older history folds on the next request"
    if out.byte_length() > CAP:
        out = String(out[byte=:CAP]) + "\n[ctxd: cut at " + String(CAP) + " bytes]"
    return out


def _calls(msg: Json, anthropic: Bool) -> Tuple[Int, Int]:
    """(ctx calls, other tool calls) in the assistant message."""
    var mine = 0
    var other = 0
    var list = msg.get("content") if anthropic else msg.get("tool_calls")
    for i in range(list.len()):
        var c = list.at(i)
        if anthropic and c.text("type") != "tool_use":
            continue
        var name = c.text("name") if anthropic else c.get("function").text("name")
        if name in materialize[NAMES]():
            mine += 1
        else:
            other += 1
    return (mine, other)


def _strip(mut msg: Json, anthropic: Bool):
    """Drop the ctx calls, keep everything else."""
    var key = String("content") if anthropic else String("tool_calls")
    var list = msg.get(key)
    var kept = Json.array()
    for i in range(list.len()):
        var c = list.at(i)
        var name = c.text("name") if anthropic else c.get("function").text("name")
        if name not in materialize[NAMES]():
            kept.push(c)
    msg.set(key, kept)


def _turn(sid: String, msg: Json, anthropic: Bool, mut doc: Json) raises:
    """Append the assistant message and the results of its ctx calls to the request."""
    var ms = doc.get("messages")
    var am = Json.object()
    am.set("role", Json.of(String("assistant")))
    if anthropic:
        am.set("content", msg.get("content"))
        ms.push(am)
        var res = Json.array()
        var c = msg.get("content")
        for i in range(c.len()):
            var b = c.at(i)
            if b.text("type") == "tool_use":
                var r = Json.object()
                r.set("type", Json.of(String("tool_result")))
                r.set("tool_use_id", Json.of(b.text("id")))
                r.set("content", Json.of(run(sid, b.text("name"), b.get("input"))))
                res.push(r)
        var um = Json.object()
        um.set("role", Json.of(String("user")))
        um.set("content", res)
        ms.push(um)
    else:
        am.set("content", msg.get("content"))
        am.set("tool_calls", msg.get("tool_calls"))
        ms.push(am)
        var c = msg.get("tool_calls")
        for i in range(c.len()):
            var f = c.at(i).get("function")
            var tm = Json.object()
            tm.set("role", Json.of(String("tool")))
            tm.set("tool_call_id", Json.of(c.at(i).text("id")))
            tm.set("content", Json.of(run(sid, f.text("name"), parse(f.text("arguments", "{}")))))
            ms.push(tm)
    doc.set("messages", ms)


def _ev(mut resp: Response, kind: String, data: String) raises:
    resp.sse('{"type":"' + kind + '"' + data + "}", kind)


def _replay_anthropic(top: Json, mut resp: Response) raises:
    var head = top.copy()
    head.set("content", Json.array())
    head.set("stop_reason", Json())
    _ev(resp, "message_start", ',"message":' + head.dumps())
    var c = top.get("content")
    for i in range(c.len()):
        var b = c.at(i)
        var t = b.text("type")
        var start = b.copy()
        var delta = String()
        if t == "text":
            start.set("text", Json.of(String("")))
            delta = '{"type":"text_delta","text":' + b.get("text").dumps() + "}"
        elif t == "tool_use":
            start.set("input", Json.object())
            delta = '{"type":"input_json_delta","partial_json":' + Json.of(b.get("input").dumps()).dumps() + "}"
        elif t == "thinking":
            start.set("thinking", Json.of(String("")))
            start.set("signature", Json.of(String("")))
            delta = '{"type":"thinking_delta","thinking":' + b.get("thinking").dumps() + "}"
        var at = ',"index":' + String(i)
        _ev(resp, "content_block_start", at + ',"content_block":' + start.dumps())
        if delta != "":
            _ev(resp, "content_block_delta", at + ',"delta":' + delta)
        if t == "thinking":
            _ev(resp, "content_block_delta", at + ',"delta":{"type":"signature_delta","signature":' + b.get("signature").dumps() + "}")
        _ev(resp, "content_block_stop", at)
    var d = Json.object()
    d.set("stop_reason", top.get("stop_reason"))
    d.set("stop_sequence", top.get("stop_sequence"))
    _ev(resp, "message_delta", ',"delta":' + d.dumps() + ',"usage":' + top.get("usage").dumps())
    _ev(resp, "message_stop", "")


def _replay_openai(top: Json, mut resp: Response) raises:
    var ch = top.copy()
    ch.set("object", Json.of(String("chat.completion.chunk")))
    var choice = top.get("choices").at(0)
    var delta = choice.get("message")
    var tc = delta.get("tool_calls")
    if tc.len() > 0:
        var idx = Json.array()
        for i in range(tc.len()):
            var c = tc.at(i)
            c.set("index", Json.of(i))
            idx.push(c)
        delta.set("tool_calls", idx)
    var one = Json.object()
    one.set("index", Json.of(0))
    one.set("delta", delta)
    one.set("finish_reason", Json())
    var arr = Json.array()
    arr.push(one)
    ch.set("choices", arr)
    resp.sse(ch.dumps())
    one.set("delta", Json.object())
    one.set("finish_reason", choice.get("finish_reason"))
    arr = Json.array()
    arr.push(one)
    ch.set("choices", arr)
    resp.sse(ch.dumps())
    resp.sse("[DONE]")


def answer(curl: Curl, url: String, req: Request, anthropic: Bool, body: Span[UInt8, _], sid: String, mut resp: Response) raises:
    var doc = parse(body)
    var stream = doc.get("stream").truthy()
    doc.set("stream", Json.of(False))
    var lines = lines_of(req)
    for round in range(ROUNDS + 1):
        var r = curl.fetch(url, lines, doc.dumps().as_bytes(), 0)
        if r[0] != 200:
            relay_heads(r[2], resp)
            resp.status = r[0]
            resp.add("content-type", "application/json")
            resp.body = r[1].copy()
            return
        var top = parse(Span(r[1]))
        var msg = top.copy() if anthropic else top.get("choices").at(0).get("message")
        var n = _calls(msg, anthropic)
        if n[0] > 0 and n[1] == 0 and round < ROUNDS:
            print("CTX-TOOL", sid, "round", round, "calls", n[0], flush=True)
            _turn(sid, msg, anthropic, doc)
            continue
        relay_heads(r[2], resp)
        if n[0] > 0:
            _strip(msg, anthropic)
            if anthropic:
                top = msg^
            else:
                var c = top.get("choices")
                var c0 = c.at(0)
                c0.set("message", msg)
                var arr = Json.array()
                arr.push(c0)
                top.set("choices", arr)
        if stream:
            resp.begin_stream("text/event-stream", 200)
            if anthropic:
                _replay_anthropic(top, resp)
            else:
                _replay_openai(top, resp)
            resp.end_stream()
        else:
            resp.status = 200
            resp.add("content-type", "application/json")
            resp.body = List[UInt8](top.dumps().as_bytes())
        return
