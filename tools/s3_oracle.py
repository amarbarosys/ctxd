"""S3 oracle: ctx tools run inside ctxd. A probe planted in message 0 is folded away; the fake upstream calls a
ctx tool and answers FOUND only if the probe's exact bytes came back in the tool result."""
import http.client, json, sys

port, fake_dir, ctxd_out = sys.argv[1:4]
W_SYSTEM = "You are a test assistant."


def die(step, why):
    print(f"FAIL {step}: {why}")
    sys.exit(1)


def filler(j):
    return f"[{j}] " + " ".join(f"w{(j * 7919 + k * 104729) % 9973}" for k in range(60 + (j * 53) % 170))


def history(fmt):
    msgs = [{"role": "user", "content": "start PROBE-7f3 " + filler(0)}]
    for j in range(1, 40):
        msgs.append({"role": "assistant" if j % 2 else "user", "content": filler(j)})
    msgs.append({"role": "user", "content": "go"})
    if fmt == "openai":
        msgs.insert(0, {"role": "system", "content": W_SYSTEM})
    return msgs


def post(fmt, body, headers):
    c = http.client.HTTPConnection("127.0.0.1", int(port), timeout=30)
    c.request("POST", "/v1/messages" if fmt == "anthropic" else "/v1/chat/completions", json.dumps(body), {"content-type": "application/json", **headers})
    r = c.getresponse()
    return r.status, r.read().decode()


def parse_sse(fmt, data):
    """(text, tool names) rebuilt from the stream, plus the event names in order."""
    text, tools, events = "", [], []
    for frame in [f for f in data.split("\n\n") if f]:
        ev = next((l[7:] for l in frame.split("\n") if l.startswith("event: ")), "")
        payload = "\n".join(l[6:] for l in frame.split("\n") if l.startswith("data: "))
        events.append(ev or payload[:6])
        if payload == "[DONE]":
            continue
        d = json.loads(payload)
        if fmt == "anthropic":
            if d["type"] == "content_block_start" and d["content_block"]["type"] == "tool_use":
                tools.append(d["content_block"]["name"])
            if d["type"] == "content_block_delta" and d["delta"]["type"] == "text_delta":
                text += d["delta"]["text"]
        else:
            delta = d["choices"][0]["delta"]
            text += delta.get("content") or ""
            tools += [t["function"]["name"] for t in delta.get("tool_calls") or []]
    return text, tools, events


def reply(fmt, raw):
    m = json.loads(raw)
    if fmt == "anthropic":
        return "".join(b.get("text", "") for b in m["content"]), [b["name"] for b in m["content"] if b["type"] == "tool_use"]
    msg = m["choices"][0]["message"]
    return msg.get("content") or "", [t["function"]["name"] for t in msg.get("tool_calls") or []]


def body(fmt, stream):
    b = {"model": "m", "max_tokens": 100, "messages": history(fmt), "stream": stream}
    if fmt == "anthropic":
        b["system"] = W_SYSTEM
    return b


for fmt in ("anthropic", "openai"):
    for mode in ("expand", "search", "mixed", "compress"):
        for stream in (False, True):
            sid = f"s3-{fmt}-{mode}-{int(stream)}"
            st, raw = post(fmt, body(fmt, stream), {"x-ctxd-session": sid, "x-test-name": sid + "-fold"})
            sent = open(f"{fake_dir}/{sid}-fold.json").read()
            if "PROBE-7f3" in sent or "[ctxd fold 0" not in sent:
                die("fold", f"{sid}: the probe was not folded away before the tool round")
            if '"ctx_expand"' not in sent:
                die("inject", f"{sid}: ctx tools not offered to a folded session")
            st, raw = post(fmt, body(fmt, stream), {"x-ctxd-session": sid, "x-s3": mode})
            if st != 200:
                die("status", f"{sid}: {st} {raw[:200]}")
            if stream:
                text, tools, events = parse_sse(fmt, raw)
                want = (["message_start", "content_block_start", "content_block_delta", "content_block_stop"] if fmt == "anthropic" else [])
                if events[: len(want)] != want or events[-1] != ("message_stop" if fmt == "anthropic" else "[DONE]"):
                    die("sse", f"{sid}: event order {events}")
            else:
                text, tools = reply(fmt, raw)
            if any(t.startswith("ctx_") or t == "compress" for t in tools):
                die("hidden", f"{sid}: a ctx call reached the client: {tools}")
            if mode in ("expand", "search") and (text != "FOUND" or tools):
                die("recall", f"{sid}: text {text!r} tools {tools}")
            if mode == "mixed" and tools != ["read"]:
                die("mixed", f"{sid}: client tools {tools}, want ['read']")
            if mode == "compress":
                before = open(ctxd_out).read().count(f"FOLD {sid} ")
                h = body(fmt, stream)
                post(fmt, h, {"x-ctxd-session": sid})
                if open(ctxd_out).read().count(f"FOLD {sid} ") != before + 1:
                    die("compress", f"{sid}: no forced fold on the request after compress")
            print(f"ok {sid}: text {text!r}, client tools {tools}")
print("ok s3: probe recalled through ctx_expand and ctx_search, ctx calls hidden, mixed calls stripped, compress forces a fold")
