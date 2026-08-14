#!/usr/bin/env python3
"""Count doc-comment fences that import a first-party module outside their target's closure.

Static measurement: such a fence compiles today only because -I exposes the whole
build directory. It is not enforcement and changes nothing.
"""
import json, re, sys, subprocess, pathlib, collections

root = pathlib.Path(sys.argv[1]).resolve()
dump = subprocess.run(["swift","package","dump-package"], cwd=root,
                      capture_output=True, text=True)
if dump.returncode != 0:
    print(f"dump-package failed for {root}"); sys.exit(1)
pkg = json.loads(dump.stdout)

targets = {}
for t in pkg["targets"]:
    deps = []
    for d in t.get("dependencies", []):
        if "byName" in d and d["byName"][0]: deps.append(d["byName"][0])
        elif "target" in d and d["target"][0]: deps.append(d["target"][0])
        elif "product" in d and d["product"][0]: deps.append(d["product"][0])
    targets[t["name"]] = {"deps": deps, "type": t.get("type"),
                          "path": t.get("path") or None}

first_party = set(targets)

def closure(name, seen=None):
    seen = seen or set()
    if name in seen: return seen
    seen.add(name)
    for d in targets.get(name, {}).get("deps", []):
        if d in targets: closure(d, seen)
    return seen

# --- doc-comment fence extraction (approximate; calibrated below) -------------
DOC_LINE = re.compile(r"^\s*///(.*)$")
def doc_fences(text):
    """Yield (start_line, language, body_lines) for fences inside /// runs."""
    lines = text.splitlines()
    runs, cur, start = [], [], None
    for i, line in enumerate(lines, 1):
        m = DOC_LINE.match(line)
        if m:
            if start is None: start = i
            cur.append(m.group(1))
        else:
            if cur: runs.append((start, cur)); cur, start = [], None
    if cur: runs.append((start, cur))
    for start, run in runs:
        inside, lang, body, open_at = False, "", [], start
        for off, l in enumerate(run):
            s = l.strip()
            if s.startswith("```"):
                if not inside:
                    inside, lang, body, open_at = True, s[3:].strip(), [], start + off
                else:
                    yield (open_at, lang, body); inside = False
            elif inside:
                body.append(l)

IMPORT = re.compile(r"^\s*(?:@[A-Za-z]+\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)")

def owning_target(path):
    rel = path.relative_to(root)
    parts = rel.parts
    if len(parts) >= 3 and parts[0] in ("Sources","Source","src"):
        return parts[1]
    return None

stats = collections.Counter()
offenders = []
inclosure = []
for f in root.rglob("*.swift"):
    if ".build" in f.parts or "Tests" in f.parts or ".pre-v2" in str(f): continue
    owner = owning_target(f)
    if owner is None or owner not in targets: continue
    try: text = f.read_text(errors="replace")
    except Exception: continue
    allowed = closure(owner)
    for line_no, lang, body in doc_fences(text):
        stats["fences_found"] += 1
        if lang not in ("swift", ""):
            stats["non_swift"] += 1; continue
        stats["swift_fences"] += 1
        imports = [IMPORT.match(b).group(1) for b in body if IMPORT.match(b)]
        if not imports:
            stats["no_imports"] += 1
        fp = [i for i in imports if i in first_party]
        own = [i for i in fp if i == owner]
        inside = [i for i in fp if i != owner and i in allowed]
        outside = [i for i in fp if i not in allowed]
        if imports and not fp: stats["external_only"] += 1
        if own: stats["imports_own_module"] += 1
        if inside:
            stats["imports_in_closure"] += 1
            inclosure.append((str(f.relative_to(root)), line_no, owner, inside))
        if outside:
            stats["over_supplied"] += 1
            offenders.append((str(f.relative_to(root)), line_no, owner, outside))

print(f"=== {root.name} ===")
print(f"  targets                : {len(targets)}")
print(f"  doc fences found       : {stats['fences_found']}  ({stats['swift_fences']} swift/untagged, {stats['non_swift']} other)")
print(f"  fences with no imports : {stats['no_imports']}")
print(f"  external imports only  : {stats['external_only']}")
print(f"  import their own module: {stats['imports_own_module']}")
print(f"  cross-module, IN closure: {stats['imports_in_closure']}")
print(f"  OVER-SUPPLIED fences   : {stats['over_supplied']}")
for path, line, owner, mods in inclosure[:6]:
    print(f"      in-closure  {path}:{line}  [{owner}] -> {', '.join(mods)}")
for path, line, owner, mods in offenders:
    print(f"      {path}:{line}  [{owner}] imports {', '.join(mods)}")
