#!/usr/bin/env python3
"""How much of a test suite states a property versus asserting one example?

    example-only : one input, one expected output, written by hand.
    table-driven : @Test(arguments:) — many inputs, still hand-enumerated.
    generative   : inputs produced in the test (seeded RNG, loops over ranges).
    invariant    : asserts a relationship (round-trip) rather than a literal.

The last three are what a deterministic-simulation platform consumes: a property it
can hunt a counterexample for. Antithesis was not handed SQLite's test cases — it was
handed assertions about data loss, and found a fifteen-year-old bug in fifteen minutes.

Two calibration rules, both learned by getting the number wrong first:

1.  **Strip multi-line string literals.** A linter's tests embed Swift source as
    fixtures, and those fixtures contain `@Test`. Counting them inflated this
    package's total from 2,968 to 3,068 against a known 2,993.

2.  **One regex across every package.** Adding `abs(` to the invariant pattern to
    catch float tolerance reported BusinessMath at 51.4% property-shaped against
    11.4% on identical criteria. `abs(a - b) < 1e-6` is an example with a tolerance,
    not an invariant.

Usage: measure-test-style.py [package-root]
"""
import re
import sys
import pathlib
import collections

TEST_ATTR = re.compile(r"(@Test\b(\([^)]*\))?|func\s+test[A-Z_]\w*)", re.S)
SEEDED = re.compile(r"Seeded|seed:\s*\d|RandomNumberGenerator")
LOOP = re.compile(r"for\s+\w+\s+in\s+(?:0\.\.[.<]\s*\d|stride\()")
ROUNDTRIP = re.compile(
    r"(decode|parse|round[Tt]rip|encode)\w*\(.*\)\s*==|==\s*(?:original|input|source)")


def strip_multiline_strings(text):
    """Remove \"\"\"...\"\"\" fixtures, which embed source that looks like tests."""
    out, i = [], 0
    while True:
        opening = text.find('"""', i)
        if opening < 0:
            out.append(text[i:])
            break
        out.append(text[i:opening])
        closing = text.find('"""', opening + 3)
        if closing < 0:
            break
        i = closing + 3
    return "".join(out)


def body_of(text, start):
    """Brace-matched body of the declaration following a match."""
    opening = text.find("{", start)
    if opening < 0:
        return ""
    depth, index = 0, opening
    while index < len(text):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening:index]
        index += 1
    return text[opening:]


def measure(root):
    counts = collections.Counter()
    tests_dir = root / "Tests"
    if not tests_dir.is_dir():
        print(f"{root}: no Tests/ directory — nothing examined")
        return
    for path in tests_dir.rglob("*.swift"):
        if any(part.startswith(".build") for part in path.parts):
            continue
        if "checkouts" in str(path) or ".claude" in path.parts:
            continue
        text = strip_multiline_strings(path.read_text(errors="replace"))
        for match in TEST_ATTR.finditer(text):
            counts["total"] += 1
            attribute = match.group(2) or ""
            body = body_of(text, match.end())
            table = "arguments:" in attribute
            generative = bool(SEEDED.search(body)) or bool(LOOP.search(body))
            invariant = bool(ROUNDTRIP.search(body))
            if table:
                counts["table"] += 1
            if generative:
                counts["generative"] += 1
            if invariant:
                counts["invariant"] += 1
            if not (table or generative or invariant):
                counts["example"] += 1

    total = max(counts["total"], 1)
    shaped = counts["table"] + counts["generative"] + counts["invariant"]
    print(f"=== {root.name} ===")
    print(f"tests                   : {counts['total']}")
    print(f"  example-only          : {counts['example']:5d} ({100*counts['example']/total:.1f}%)")
    print(f"  table-driven          : {counts['table']:5d} ({100*counts['table']/total:.1f}%)")
    print(f"  generative            : {counts['generative']:5d} ({100*counts['generative']/total:.1f}%)")
    print(f"  invariant             : {counts['invariant']:5d} ({100*counts['invariant']/total:.1f}%)")
    print(f"  PROPERTY-SHAPED       : {shaped:5d} ({100*shaped/total:.1f}%)")


if __name__ == "__main__":
    measure(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve())
