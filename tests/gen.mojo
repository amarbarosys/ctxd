"""Deterministic test messages: JSON, valid UTF-8, with multi-byte text."""


struct Rng(Movable):
    var s: UInt64

    def __init__(out self, seed: Int):
        self.s = UInt64(seed) * 2654435761 + 1

    def below(mut self, n: Int) -> Int:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Int(self.s >> 33) % n


def message(mut r: Rng, size: Int, tag: String) -> List[UInt8]:
    """`{"role":"user","content":"<tag> ..."}` of at least `size` bytes."""
    var pieces: List[String] = ["lorem ", "ipsum ", "é", "日本語 ", "😀", "tool_use ", "\\n", "dolor "]
    var s = String('{"role":"user","content":"') + tag + " "
    while s.byte_length() < size:
        s += pieces[r.below(len(pieces))]
    s += '"}'
    return List[UInt8](s.as_bytes())
