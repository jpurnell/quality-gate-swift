#!/usr/bin/env python3
"""How many tests reach outside the process, and would therefore not replay?

A deterministic-simulation platform controls the world a program sees. Anything a
test reaches directly — the real file system, a real subprocess, a real socket, the
real clock — is a channel the platform would have to intercept, or a test that
cannot be replayed at all.

Counts the *test* as impure if its body touches any of these without going through
an injected seam.
"""
import re, sys, pathlib, collections

root = pathlib.Path(sys.argv[1])
def strip_ml(t):
    out, i = [], 0
    while True:
        a = t.find('"""', i)
        if a < 0: out.append(t[i:]); break
        out.append(t[i:a]); b = t.find('"""', a + 3)
        if b < 0: break
        i = b + 3
    return "".join(out)

TEST = re.compile(r"(@Test\b(\([^)]*\))?|func\s+test[A-Z_]\w*)", re.S)
CHANNELS = {
    "filesystem": re.compile(r"FileManager\.default|NSTemporaryDirectory\(|"
                             r"\.write\(to:|String\(contentsOf|Data\(contentsOf|"
                             r"contentsOfFile:|FileHandle|\.createDirectory\("),
    "subprocess": re.compile(r"\bProcess\(|posix_spawn|\.launch\(|/usr/bin/env|"
                             r"executableURL"),
    "network":    re.compile(r"URLSession|URLRequest|\bSocket\b|NWConnection|"
                             r"dataTask|\.resume\(\)"),
    "clock":      re.compile(r"Date\(\)|\.now\b|ContinuousClock|DispatchTime\.now|"
                             r"CFAbsoluteTimeGetCurrent"),
}
def body_of(t, s):
    i = t.find("{", s)
    if i < 0: return ""
    d, j = 0, i
    while j < len(t):
        if t[j] == "{": d += 1
        elif t[j] == "}":
            d -= 1
            if d == 0: return t[i:j]
        j += 1
    return t[i:]

c = collections.Counter()
per_channel = collections.Counter()
for f in (root / "Tests").rglob("*.swift"):
    if any(p.startswith(".build") for p in f.parts): continue
    if "checkouts" in str(f) or ".claude" in f.parts: continue
    text = strip_ml(f.read_text(errors="replace"))
    for m in TEST.finditer(text):
        c["total"] += 1
        body = body_of(text, m.end())
        touched = [k for k, rx in CHANNELS.items() if rx.search(body)]
        for k in touched: per_channel[k] += 1
        if touched: c["impure"] += 1
        else: c["pure"] += 1
t = max(c["total"], 1)
print(f"=== {root.name} ===")
print(f"tests                    : {c['total']}")
print(f"  in-process (replayable): {c['pure']:5d} ({100*c['pure']/t:.1f}%)")
print(f"  reach outside          : {c['impure']:5d} ({100*c['impure']/t:.1f}%)")
for k in ["filesystem", "subprocess", "network", "clock"]:
    print(f"      {k:11s}: {per_channel[k]:5d} ({100*per_channel[k]/t:.1f}%)")
