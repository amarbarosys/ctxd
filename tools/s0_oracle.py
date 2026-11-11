"""S0 oracle: byte-equality, streaming and latency of ctxd against the fake upstream.
Usage: s0_oracle.py CTXD_PORT UPSTREAM_PORT CTXD_PID"""
import http.client, re, statistics, sys, time

cport, uport, pid = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
HDR = {"x-api-key": "k-123", "anthropic-version": "2023-06-01", "anthropic-beta": "b1,b2",
       "authorization": "Bearer t-456", "content-type": "application/json"}
ROUTES = [("/v1/messages", "/v1/messages"), ("/v1/chat/completions", "/chatbase/v1/chat/completions")]


def fail(step, why):
    print(f"FAIL {step}: {why}")
    sys.exit(1)


def post(conn, path, body):
    conn.request("POST", path, body, HDR)
    r = conn.getresponse()
    return r, r.read()


def rss():
    return int(re.search(r"VmRSS:\s+(\d+)", open(f"/proc/{pid}/status").read()).group(1))


via, direct = http.client.HTTPConnection("127.0.0.1", cport), http.client.HTTPConnection("127.0.0.1", uport)
for ours, theirs in ROUTES:
    body = b'{"model":"m","messages":[{"role":"user","content":"hi"}]}' * 3
    a, ab = post(via, ours, body)
    b, bb = post(direct, theirs, body)
    if a.status != 200 or ab != bb or a.getheader("content-type") != b.getheader("content-type"):
        fail("json", f"{ours}: status {a.status}, via {ab!r} direct {bb!r}")
    for want in (b'"key":"k-123"', b'"ver":"2023-06-01"', b'"beta":"b1,b2"', b'"auth":"Bearer t-456"'):
        if want not in ab:
            fail("headers", f"{ours}: {want!r} missing in {ab!r}")
    print(f"ok json  {ours}: {len(ab)} bytes equal, headers forwarded")

a, ab = post(via, "/v1/messages", b'{"x":1}')
c, cb = post(via, "/nope", b"{}")
d = via.request("GET", "/v1/messages") or via.getresponse()
d.read()
if (c.status, d.status) != (404, 405):
    fail("routes", f"unknown path {c.status}, GET {d.status}")
print("ok routes: 404 unknown path, 405 GET")

sse = b'{"stream":true}'
b, bb = post(direct, "/v1/messages", sse)
t0 = time.perf_counter()
via.request("POST", "/v1/messages", sse, HDR)
r = via.getresponse()
first = r.readline()
t_first = time.perf_counter() - t0
rest = r.read()
t_all = time.perf_counter() - t0
got = first + rest
if r.status != 200 or got != bb:
    fail("sse", f"bytes differ: via {len(got)} direct {len(bb)}")
if not (t_first < 0.15 and t_all > 0.75):
    fail("stream", f"first line at {t_first*1000:.0f} ms, end at {t_all*1000:.0f} ms (upstream sends its last frame at ~800 ms)")
print(f"ok sse: {len(got)} bytes equal, first frame at {t_first*1000:.0f} ms, stream end at {t_all*1000:.0f} ms")

body = b'{"model":"m","messages":[]}'
for _ in range(20):
    post(via, "/v1/messages", body)
    post(direct, "/v1/messages", body)
tv, td = [], []
for _ in range(200):
    for conn, acc in ((via, tv), (direct, td)):
        t = time.perf_counter()
        post(conn, "/v1/messages", body)
        acc.append(time.perf_counter() - t)
pv, pd = statistics.median(tv) * 1e6, statistics.median(td) * 1e6
print(f"latency p50 over 200 requests: direct {pd:.0f} us, via ctxd {pv:.0f} us, added {pv-pd:.0f} us")
print(f"ctxd RSS: {rss()} KiB")
print("PASS s0")
