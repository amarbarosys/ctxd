"""Fake upstream for the S0 and S2 gates: /v1/messages and /v1/chat/completions (under any prefix) return a fixed
JSON that echoes the auth headers plus rate-limit headers, or, when the body has "stream":true, 5 SSE frames
200 ms apart (cut off after 2 when the request has x-cut). Under /sum/ it is the summarizer and answers with a
fixed summary. With FAKE_DIR set, each body is saved: FAKE_DIR/<x-test-name>.json, or sum-<n>.json."""
from std.ffi import external_call
from std.os import getenv
from posix import block_signals
from bento.http import Request, Response, Limits
from bento.server import Server, Handler
from json import Json


struct Fake(Handler):
    var sums: Int

    def __init__(out self):
        self.sums = 0

    def draining(self):
        pass

    def handle(self, req: Request, mut resp: Response) raises:
        var dir = getenv("FAKE_DIR")
        var name = req.header("x-test-name")
        if "/sum/" in req.path:
            var n = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=Int(Pointer(to=self.sums)))
            n[] += 1
            name = "sum-" + String(n[])
        if dir != "" and name != "":
            with open(dir + "/" + name + ".json", "w") as f:
                f.write_bytes(Span(req.body))
        resp.add("request-id", "req_fake1")
        resp.add("anthropic-ratelimit-requests-remaining", "99")
        resp.add("retry-after", "7")
        resp.add("x-ratelimit-limit", "5")
        if not (req.path.endswith("/v1/messages") or req.path.endswith("/v1/chat/completions")):
            resp = Response.text(404, "fake: no route\n")
        elif "/sum/" in req.path:
            if "/slow/" in req.path:
                _ = external_call["usleep", Int32](Int32(1000000))
            resp.add("content-type", "application/json")
            resp.body.extend('{"choices":[{"message":{"role":"assistant","content":"SUMMARY-FIXED"}}]}'.as_bytes())
        elif req.has("x-s3"):
            resp.add("content-type", "application/json")
            resp.body.extend(_s3(req).as_bytes())
        elif String(unsafe_from_utf8=Span(req.body)).find('"stream":true') >= 0:
            for i in range(5):
                resp.sse('{"i":' + String(i) + ',"pad":"' + String("x") * (i * 37) + '"}', "tick")
                _ = external_call["usleep", Int32](Int32(200000))
                if i == 1 and req.has("x-cut"):
                    _ = external_call["shutdown", Int32](resp.fd, Int32(2))
                    return
            resp.end_stream()
        else:
            resp.add("content-type", "application/json")
            resp.body.extend(('{"path":"' + req.path + '","key":"' + req.header("x-api-key") + '","auth":"' + req.header("authorization")
                + '","ver":"' + req.header("anthropic-version") + '","beta":"' + req.header("anthropic-beta") + '","n":' + String(len(req.body)) + "}").as_bytes())


def _s3(req: Request) -> String:
    """S3 gate: call the ctx tool named by x-s3 once, then answer FOUND if the probe came back in a tool result."""
    var body = String(unsafe_from_utf8=Span(req.body))
    var anth = req.path.endswith("/v1/messages")
    var mode = req.header("x-s3")
    var answered = '"toolu_s3"' in body or '"call_s3"' in body
    var text = String("checking")
    if answered:
        text = "FOUND" if "PROBE-7f3" in body else "MISSING"
    var calls = List[Tuple[String, String]]()
    if not answered:
        var arg = String('{"id":0}') if mode == "expand" else (String("{}") if mode == "compress" else String('{"query":"PROBE-7f3"}'))
        calls.append((String("ctx_search") if mode == "mixed" else ("ctx_" + mode if mode != "compress" else String("compress")), arg))
        if mode == "mixed":
            calls.append((String("read"), String('{"path":"/x"}')))
    if anth:
        var c = String('[{"type":"text","text":"' + text + '"}')
        for i in range(len(calls)):
            c += ',{"type":"tool_use","id":"toolu_s3' + (String("") if i == 0 else "_" + String(i)) + '","name":"' + calls[i][0] + '","input":' + calls[i][1] + "}"
        return ('{"id":"msg_s3","type":"message","role":"assistant","model":"fake","content":' + c + '],"stop_reason":"'
            + ("end_turn" if answered else "tool_use") + '","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}')
    var tc = String()
    for i in range(len(calls)):
        tc += (String(",") if i else String("")) + '{"id":"call_s3' + (String("") if i == 0 else "_" + String(i)) + '","type":"function","function":{"name":"' + calls[i][0] + '","arguments":' + Json.of(calls[i][1]).dumps() + "}}"
    var msg = ('{"role":"assistant","content":"' + text + '"}' if answered
        else '{"role":"assistant","content":null,"tool_calls":[' + tc + "]}")
    return ('{"id":"chatcmpl-s3","object":"chat.completion","created":1,"model":"fake","choices":[{"index":0,"message":' + msg
        + ',"finish_reason":"' + ("stop" if answered else "tool_calls") + '"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}')


def main() raises:
    block_signals([2, 15])
    var srv = Server(Fake(), "127.0.0.1", 0, Limits(16384, 64 << 20), 256)
    print("LISTEN", srv.port(), flush=True)
    srv.serve(4, True)
