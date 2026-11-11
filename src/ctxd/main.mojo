"""The ctxd proxy: a localhost proxy with a fold policy. /v1/messages and /v1/chat/completions go to the upstreams named in
ctxd.toml (port, messages, chat; [window] messages, chat in tokens; [summarizer] url, model, max_tokens) or
CTXD_PORT / CTXD_UPSTREAM_MESSAGES / CTXD_UPSTREAM_CHAT / CTXD_WINDOW_MESSAGES / CTXD_WINDOW_CHAT. The
summarizer key is CTXD_SUMMARIZER_KEY. Without a [summarizer] url nothing is folded."""
from std.os import getenv
from std.pathlib import Path
from posix import block_signals
from bento.http import Request, Response, Limits
from bento.server import Server, Handler
from bento.sync import Mutex
from ctxd.curl import Curl
from ctxd.fold import Summarizer, rewrite, STRIPES
from ctxd.tools import answer


struct Proxy(Handler):
    var curl: Curl
    var locks: List[Mutex]
    var sum: Summarizer
    var messages: String
    var chat: String
    var win_messages: Int
    var win_chat: Int

    def __init__(out self, var messages: String, var chat: String, var sum: Summarizer, win_messages: Int, win_chat: Int) raises:
        self.curl = Curl()
        self.locks = List[Mutex]()
        for _ in range(STRIPES):
            self.locks.append(Mutex())
        self.sum = sum^
        self.messages = messages^
        self.chat = chat^
        self.win_messages = win_messages
        self.win_chat = win_chat

    def draining(self):
        pass

    def _go(self, url: String, window: Int, anthropic: Bool, req: Request, mut resp: Response) raises:
        var body = List[UInt8]()
        var sid = String()
        if self.sum.url != "":
            try:
                var r = rewrite(self.curl, self.sum, window, anthropic, req.header("x-ctxd-session"), req.body, self.locks)
                body = r[0].copy()
                sid = r[1]
            except e:
                print("FOLD-SKIP", e, flush=True)
        if sid != "":
            answer(self.curl, url, req, anthropic, Span(body), sid, resp)
        elif len(body) > 0:
            self.curl.post(url, req, Span(body), anthropic, resp)
        else:
            self.curl.post(url, req, Span(req.body), anthropic, resp)

    def handle(self, req: Request, mut resp: Response) raises:
        if req.method != "POST":
            resp = Response.text(405, "ctxd: POST only\n")
        elif req.path == "/v1/messages":
            self._go(self.messages + req.target, self.win_messages, True, req, resp)
        elif req.path.startswith("/v1/messages"):
            self.curl.post(self.messages + req.target, req, Span(req.body), True, resp)
        elif req.path == "/v1/chat/completions":
            self._go(self.chat + req.target, self.win_chat, False, req, resp)
        else:
            resp = Response.text(404, "ctxd: no route\n")


def _conf(key: String, env: String, default: String) raises -> String:
    var v = getenv(env)
    if v != "":
        return v
    var p = Path("ctxd.toml")
    if p.exists():
        var sec = String()
        for line in p.read_text().split("\n"):
            var t = String(line.strip())
            if t.startswith("["):
                sec = String(t.strip("[]")) + "."
            var kv = t.split("=")
            if len(kv) == 2 and sec + String(kv[0].strip()) == key:
                return String(kv[1].strip().strip('"'))
    return default


def main() raises:
    block_signals([2, 15])
    var port = Int(_conf("port", "CTXD_PORT", "8787"))
    var sum = Summarizer(
        _conf("summarizer.url", "CTXD_SUMMARIZER_URL", ""),
        _conf("summarizer.model", "CTXD_SUMMARIZER_MODEL", ""),
        Int(_conf("summarizer.max_tokens", "CTXD_SUMMARIZER_MAX_TOKENS", "1000")),
        getenv("CTXD_SUMMARIZER_KEY"),
    )
    var proxy = Proxy(
        _conf("messages", "CTXD_UPSTREAM_MESSAGES", "https://api.anthropic.com"),
        _conf("chat", "CTXD_UPSTREAM_CHAT", "https://openrouter.ai/api"),
        sum^,
        Int(_conf("window.messages", "CTXD_WINDOW_MESSAGES", "200000")),
        Int(_conf("window.chat", "CTXD_WINDOW_CHAT", "128000")),
    )
    var srv = Server(proxy^, "127.0.0.1", port, Limits(16384, 256 << 20), 1024)
    print("LISTEN", srv.port(), flush=True)
    srv.serve(4, True)
