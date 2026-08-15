#!/usr/bin/env python3
"""Functions whose shape warrants a property test, and whether one exists.

A property earns its place when the input space is large AND an invariant can be
stated without restating the implementation. In a checker suite that is mostly
parsers, comparators, diffs and round-trips.

Reports by file:line so the work can be tackled in order of concentration.
"""
import re, sys, pathlib, collections

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()

def strip_ml(t):
    out, i = [], 0
    while True:
        a = t.find('"""', i)
        if a < 0: out.append(t[i:]); break
        out.append(t[i:a]); b = t.find('"""', a + 3)
        if b < 0: break
        i = b + 3
    return "".join(out)

FUNC = re.compile(r"^\s*(?:public |internal |private |fileprivate |package |static |final )*"
                  r"func\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(([^)]*)\)\s*(?:async\s+)?(?:throws\s+)?"
                  r"(?:->\s*([^{\n]+))?", re.M)

# Name-shaped candidates: the verb tells you an invariant exists.
PARSER   = re.compile(r"^(parse|decode|read|extract|scan|tokenize|split|lex)", re.I)
RENDER   = re.compile(r"^(render|encode|format|serial|describe|emit|write)", re.I)
COMPARE  = re.compile(r"^(compare|diff|matches?|equal|contains|overlaps|isSubset)", re.I)
ORDER    = re.compile(r"^(sort|order|rank|prioriti[sz]e|merge)", re.I)
BALANCE  = re.compile(r"(matching|balanced|closing|enclosing)", re.I)
NORMAL   = re.compile(r"^(normali[sz]e|canonical|sanitis|sanitiz|trim|clean)", re.I)

def classify(name, params, ret):
    ret = (ret or "").strip()
    takes_text = re.search(r":\s*(String|Substring|Data|\[String\])", params or "")
    if PARSER.match(name) and takes_text: return "parser"
    if COMPARE.match(name):               return "comparator"
    if ORDER.match(name):                 return "ordering"
    if BALANCE.search(name):              return "balance"
    if NORMAL.match(name) and takes_text: return "normaliser"
    # A renderer alone has no invariant — `emitDiagnostics` has no inverse. It is a
    # candidate only when the same module also parses, giving a round-trip to assert.
    if RENDER.match(name):                return "renderer?"
    return None

# Property-shaped test detection, same criteria as measure-test-style.py
SEEDED = re.compile(r"Seeded|seed:\s*\d|RandomNumberGenerator")
LOOP   = re.compile(r"for\s+\w+\s+in\s+(?:0\.\.[.<]\s*\d|stride\()")
ROUNDTRIP = re.compile(r"(decode|parse|round[Tt]rip|encode)\w*\(.*\)\s*==|==\s*(?:original|input|source)")

# --- gather candidate functions -------------------------------------------------
candidates = []
for f in (root / "Sources").rglob("*.swift"):
    if any(p.startswith(".build") for p in f.parts) or ".docc" in str(f): continue
    text = strip_ml(f.read_text(errors="replace"))
    module = None
    parts = f.relative_to(root).parts
    if len(parts) >= 2: module = parts[1]
    for m in FUNC.finditer(text):
        name, params, ret = m.group(1), m.group(2), m.group(3)
        kind = classify(name, params, ret)
        if not kind: continue
        line = text[:m.start()].count("\n") + 1
        candidates.append({"name": name, "kind": kind, "module": module,
                           "path": str(f.relative_to(root)), "line": line})

# --- which symbols already have a property-shaped test --------------------------
covered = set()
for f in (root / "Tests").rglob("*.swift"):
    if any(p.startswith(".build") for p in f.parts): continue
    text = strip_ml(f.read_text(errors="replace"))
    for m in re.finditer(r"(@Test\b(\([^)]*\))?|func\s+test[A-Z_]\w*)", text):
        attr = m.group(2) or ""
        i = text.find("{", m.end())
        if i < 0: continue
        depth, j = 0, i
        while j < len(text):
            if text[j] == "{": depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0: break
            j += 1
        body = text[i:j]
        is_property = ("arguments:" in attr) or SEEDED.search(body) or LOOP.search(body) or ROUNDTRIP.search(body)
        if not is_property: continue
        for sym in re.findall(r"\b([A-Za-z_]\w*)\s*\(", body):
            covered.add(sym)

# Keep a renderer only where the SAME FILE also parses. Module scope was too coarse:
# QualityGateCore contains parsers, so formatDuration, renderTable and two
# writeDiagnostic overloads were classified round-trip while having no inverse at all.
# A round-trip needs its two halves in the same type; same file is the usable proxy.
parser_files = {c["path"] for c in candidates if c["kind"] == "parser"}
candidates = [c for c in candidates
              if c["kind"] != "renderer?" or c["path"] in parser_files]
for c in candidates:
    if c["kind"] == "renderer?": c["kind"] = "round-trip"
# A property exercising `matchingParen` exercises `matching`, which it delegates to.
# Counting only directly-named symbols reports well-tested primitives as uncovered —
# false positives whose repair is writing a redundant test.
calls = collections.defaultdict(set)          # caller name -> names it calls
for f in (root / "Sources").rglob("*.swift"):
    if any(p.startswith(".build") for p in f.parts) or ".docc" in str(f): continue
    text = strip_ml(f.read_text(errors="replace"))
    for m in FUNC.finditer(text):
        caller = m.group(1)
        i = text.find("{", m.end())
        if i < 0: continue
        depth, j = 0, i
        while j < len(text):
            if text[j] == "{": depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0: break
            j += 1
        for callee in re.findall(r"\b([A-Za-z_]\w*)\s*\(", text[i:j]):
            if callee != caller: calls[caller].add(callee)

# Coverage extends exactly ONE level of delegation, and the depth is fixed rather
# than tunable. A thin wrapper's invariant is its delegate's invariant, so a property
# on `matchingParen` genuinely covers `matching`. Two levels is already claiming a
# property about code the test never mentions, and the count is violently sensitive to
# the choice: measured here at 76 / 35 / 23 / 16 uncovered for depths 1 / 2 / 3 / 6.
# A finding count that moves like that on a knob with no principled value is not a
# finding count.
frontier, seen = set(covered), set(covered)
for _ in range(1):
    nxt = set()
    for name in frontier:
        nxt |= calls.get(name, set()) - seen
    if not nxt: break
    seen |= nxt; frontier = nxt
covered = seen

uncovered = [c for c in candidates if c["name"] not in covered]
by_kind = collections.Counter(c["kind"] for c in uncovered)
by_module = collections.Counter(c["module"] for c in uncovered)

print(f"=== {root.name} — property-test candidates ===")
print(f"candidate functions        : {len(candidates)}")
print(f"  already have a property  : {len(candidates) - len(uncovered)}")
print(f"  NO property test         : {len(uncovered)}")
print()
print("by kind:")
for k, v in by_kind.most_common(): print(f"    {k:12s} {v}")
print()
print("most concentrated modules:")
for mod, v in by_module.most_common(10): print(f"    {mod:32s} {v}")
print()
print("sites (first 40, by module):")
for c in sorted(uncovered, key=lambda c: (c["module"] or "", c["path"], c["line"]))[:400]:
    print(f"    {c['path']}:{c['line']}  {c['kind']:11s} {c['name']}")
