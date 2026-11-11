"""Probe: a C write callback into Mojo fires once per network chunk, as the chunk arrives.
Usage: curl_probe URL. Prints one line per callback, then PROBE chunks=N first_ms=A last_ms=B."""
from std.ffi import OwnedDLHandle
from std.sys import argv
from std.time import perf_counter_ns

comptime CURLOPT_URL = 10002
comptime CURLOPT_WRITEDATA = 10001
comptime CURLOPT_WRITEFUNCTION = 20011


struct Seen(Movable):
    var t0: Int
    var first: Int
    var last: Int
    var chunks: Int
    var bytes: Int

    def __init__(out self):
        self.t0 = Int(perf_counter_ns())
        self.first = 0
        self.last = 0
        self.chunks = 0
        self.bytes = 0


def on_chunk(data: Int, size: Int, n: Int, ud: Int) abi("C") -> Int:
    var s = Pointer[Seen, MutUntrackedOrigin](unsafe_from_address=ud)
    var ms = (Int(perf_counter_ns()) - s[].t0) // 1000000
    if s[].chunks == 0:
        s[].first = ms
    s[].last = ms
    s[].chunks += 1
    s[].bytes += size * n
    print("chunk", s[].chunks, "bytes", size * n, "at_ms", ms)
    return size * n


def main() raises:
    var url = String(argv()[1])
    var seen = Seen()
    var lib = OwnedDLHandle("/usr/lib/libcurl.so.4")
    var h = lib.call["curl_easy_init", Int]()
    _ = lib.call["curl_easy_setopt", Int32](h, Int32(CURLOPT_URL), Int(url.unsafe_ptr()))
    _ = lib.call["curl_easy_setopt", Int32](h, Int32(CURLOPT_WRITEFUNCTION), on_chunk)
    _ = lib.call["curl_easy_setopt", Int32](h, Int32(CURLOPT_WRITEDATA), Int(Pointer(to=seen)))
    var rc = lib.call["curl_easy_perform", Int32](h)
    lib.call["curl_easy_cleanup"](h)
    if rc != 0:
        raise Error("curl rc ", rc)
    print("PROBE chunks=", seen.chunks, " first_ms=", seen.first, " last_ms=", seen.last, sep="")
