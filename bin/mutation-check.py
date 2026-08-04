#!/usr/bin/env python3
"""Run BootIt's mutation checks from a committed corpus, with three verdicts.

A mutation check answers "does this test actually bite?" by breaking the thing
the test guards and confirming the test goes red. The failure mode that makes it
worthless is silent: if the patch does not apply, or the mutated tree does not
compile, the suite runs green against *unmutated* or *unbuilt* code and the
harness reports SURVIVES — which reads as "this test does not bite" and sends
you off to write a test that already exists.

So there is no boolean here. Every mutation ends in one of four verdicts, and
only two of them are results:

  BITES         the mutation applied, compiled, and the tests went red.
  SURVIVES      the mutation applied, compiled, and the tests stayed green.
  NOT-APPLIED   the anchor text was missing or ambiguous. Not a result.
  NOT-COMPILED  the mutated tree did not build. Not a result.

The last two exit non-zero exactly like SURVIVES. A verdict you cannot believe
must never be quieter than one you can.

Why a committed corpus rather than a throwaway script: the mutations are the
evidence that this repo's tests bite, and they need re-running after any
refactor that moves the code they anchor on — the earlier result certified a
shape that no longer exists. That has happened here already. A corpus makes it
one command instead of a re-derivation.

Usage
  bin/mutation-check.py                 run every spec in mac/mutations/
  bin/mutation-check.py <name> [...]    run named specs
  bin/mutation-check.py --list          list the corpus
  bin/mutation-check.py --self-test     prove the harness's own refusals work

Spec format (mac/mutations/<name>.mut) — the old/new bodies are verbatim, so
leading whitespace is significant and must match the source exactly:

  filter: SomeTestClassNameOrRegex
  file: Sources/BootIt/Thing.swift
  --- old ---
  <text to find, exactly once>
  --- new ---
  <text to replace it with>
"""

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
PACKAGE = REPO / "mac"
CORPUS = PACKAGE / "mutations"

BITES, SURVIVES, NOT_APPLIED, NOT_COMPILED = "BITES", "SURVIVES", "NOT-APPLIED", "NOT-COMPILED"
BELIEVABLE_AND_GOOD = {BITES}


class SpecError(Exception):
    pass


def parse(path):
    """A spec is only useful if it is unambiguous, so parsing is strict."""
    text = path.read_text()
    if "\n--- old ---\n" not in text or "\n--- new ---\n" not in text:
        raise SpecError(f"{path.name}: needs both `--- old ---` and `--- new ---` markers")
    head, rest = text.split("\n--- old ---\n", 1)
    old, new = rest.split("\n--- new ---\n", 1)

    fields = {}
    for line in head.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            raise SpecError(f"{path.name}: header line is not `key: value`: {line!r}")
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip()

    for required in ("file", "filter"):
        if not fields.get(required):
            raise SpecError(f"{path.name}: missing `{required}:`")

    # A trailing newline before the next marker belongs to the format, not to
    # the text being matched.
    return {
        "name": path.stem,
        "file": fields["file"],
        "filter": fields["filter"],
        "old": old[:-1] if old.endswith("\n") else old,
        "new": new.rstrip("\n"),
    }


def run(cmd, cwd=PACKAGE):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def check(spec, verbose=False):
    """Apply, build, test, restore. Returns (verdict, detail)."""
    source = PACKAGE / spec["file"]
    if not source.exists():
        return NOT_APPLIED, f"{spec['file']} does not exist"

    original = source.read_text()
    occurrences = original.count(spec["old"])
    if occurrences == 0:
        return NOT_APPLIED, ("anchor text not found — the code it pinned has moved or changed, "
                             "so any verdict here would certify a shape that no longer exists")
    if occurrences > 1:
        return NOT_APPLIED, (f"anchor text appears {occurrences} times; it must be unique or the "
                             "mutation is not the one the spec describes")

    backup = pathlib.Path(tempfile.mkdtemp()) / source.name
    shutil.copy2(source, backup)
    try:
        source.write_text(original.replace(spec["old"], spec["new"], 1))

        built = run(["swift", "build"])
        if built.returncode != 0:
            detail = next((line for line in built.stderr.splitlines() if "error:" in line), "")
            return NOT_COMPILED, (detail.strip() or "swift build failed")

        tested = run(["swift", "test", "--filter", spec["filter"]])
        if verbose:
            sys.stderr.write(tested.stdout)
        # A filter that matches nothing runs zero tests and "passes". That is
        # the same unbelievable-green as a patch that did not apply.
        if "Executed 0 tests" in tested.stdout or not any(
                "Executed" in line for line in tested.stdout.splitlines()):
            return NOT_APPLIED, f"filter {spec['filter']!r} matched no tests"
        return (BITES, "the guarded test went red") if tested.returncode != 0 \
            else (SURVIVES, "the suite stayed green against mutated code")
    finally:
        shutil.copy2(backup, source)
        shutil.rmtree(backup.parent, ignore_errors=True)


def self_test():
    """Prove the harness's refusals — and its SURVIVES — before trusting it.

    This is the gate for the lesson the harness exists to carry. Most of it
    checks the two verdicts that are *not* results, the ones that would
    otherwise be reported as SURVIVES and read as "this test does not bite".

    The last case checks the opposite direction, and it is the more dangerous
    one. A harness that can only ever report BITES is not a conservative
    harness — it certifies every guarded behaviour as tested, including the ones
    that are not, and there is no symptom. So it mutates real code that the
    chosen filter genuinely does not cover, and requires SURVIVES.

    It deliberately does not check BITES: that is proven every time the corpus
    runs, and asserting it here would mean carrying a second copy of a real
    mutation whose anchor could rot independently of the first.
    """
    print("MUTATION-HARNESS SELF-TEST")
    failures = 0

    target = "Sources/BootItKit/RunPlan.swift"

    # Checked first, and loudly, because its absence does not fail the cases
    # below — it makes three of them pass for the wrong reason. "Missing
    # anchor", "ambiguous anchor" and "filter matches no tests" all expect
    # NOT-APPLIED, and a file that is not there returns NOT-APPLIED too. So a
    # refactor that moves this file turns three assertions into one, silently,
    # and the self-test still prints PASS beside each of them.
    #
    # That happened: 2026-08-05 moved Sources/BootIt into Sources/BootItKit and
    # CI reported two failures where there were five degraded checks. The two
    # that failed were the two expecting something *other* than NOT-APPLIED —
    # which is to say the harness was caught by the only cases whose expected
    # verdict differed from the failure mode.
    if not (PACKAGE / target).exists():
        print(f"  FAIL  the self-test's own fixture is missing: {target}")
        print("        Three cases below expect NOT-APPLIED and a missing file returns")
        print("        NOT-APPLIED, so they would pass without testing anything. Point")
        print("        `target` at a real source file before believing any result here.")
        print()
        print("SELF-TEST FAIL — the harness cannot check itself, so it cannot be trusted.")
        return 1

    cases = [
        ("a missing anchor is refused, not reported as SURVIVES", NOT_APPLIED,
         {"file": target, "filter": "RunOutcome",
          "old": "this exact text is not in the source tree anywhere at all",
          "new": "x"}),
        ("an ambiguous anchor is refused", NOT_APPLIED,
         {"file": target, "filter": "RunOutcome", "old": "\n", "new": "\n"}),
        ("a filter matching no tests is refused", NOT_APPLIED,
         {"file": target, "filter": "NoSuchTestClassExistsHere",
          "old": "enum RunPlan {", "new": "enum RunPlan {"}),
        ("a file that is not there is refused", NOT_APPLIED,
         {"file": "Sources/BootItKit/NoSuchFile.swift", "filter": "RunOutcome",
          "old": "a", "new": "b"}),
        # The one that costs a build, and the whole point of the lesson: a
        # mutation that cannot compile must never be reported as a result.
        ("a mutated tree that does not compile is refused", NOT_COMPILED,
         {"file": target, "filter": "RunOutcome",
          "old": "enum RunPlan {", "new": "enum RunPlan { this is not swift ("}),
        # The other direction. Real code, really mutated, really compiled — but
        # under a filter whose tests do not exercise it. A harness that reported
        # BITES here would call every behaviour tested and never be caught.
        ("a mutation the filter does not cover reports SURVIVES", SURVIVES,
         {"file": target, "filter": "RunOutcome",
          "old": "        case .windows: return 0.55",
          "new": "        case .windows: return 0.11"}),
    ]

    for label, expected, spec in cases:
        spec["name"] = label
        verdict, detail = check(spec)
        ok = verdict == expected
        failures += 0 if ok else 1
        print(f"  {'PASS' if ok else 'FAIL'}  {label}")
        print(f"        expected {expected}, got {verdict} — {detail}")

    clean = run(["swift", "build"])
    if clean.returncode != 0:
        failures += 1
        print("  FAIL  the tree was not restored after the self-test")
    else:
        print("  PASS  the tree is restored and builds")

    print()
    if failures:
        print(f"SELF-TEST FAIL — {failures} refusal(s) did not work. Every verdict this harness "
              "reports is now suspect.")
    else:
        print("SELF-TEST PASS — an unappliable or uncompilable mutation is refused, not counted.")
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(add_help=True, description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("names", nargs="*", help="spec names to run (default: all)")
    parser.add_argument("--list", action="store_true", help="list the corpus and exit")
    parser.add_argument("--self-test", action="store_true", help="prove the harness's refusals")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    if not CORPUS.is_dir():
        print(f"no corpus at {CORPUS}", file=sys.stderr)
        return 1
    paths = sorted(CORPUS.glob("*.mut"))
    if args.names:
        wanted = set(args.names)
        paths = [p for p in paths if p.stem in wanted]
        missing = wanted - {p.stem for p in paths}
        if missing:
            print(f"no such spec(s): {', '.join(sorted(missing))}", file=sys.stderr)
            return 1
    if not paths:
        print(f"no specs in {CORPUS}", file=sys.stderr)
        return 1

    if args.list:
        for path in paths:
            spec = parse(path)
            print(f"  {spec['name']:44}  {spec['file']}  [{spec['filter']}]")
        return 0

    print(f"MUTATION CHECK — {len(paths)} mutation(s) from {CORPUS.relative_to(REPO)}\n")
    results = []
    for path in paths:
        try:
            spec = parse(path)
        except SpecError as error:
            print(f"  {NOT_APPLIED:13} {path.stem}\n                {error}")
            results.append((path.stem, NOT_APPLIED))
            continue
        verdict, detail = check(spec, verbose=args.verbose)
        print(f"  {verdict:13} {spec['name']}")
        print(f"                {detail}")
        results.append((spec["name"], verdict))

    bad = [(name, verdict) for name, verdict in results if verdict not in BELIEVABLE_AND_GOOD]
    print()
    if not bad:
        print(f"MUTATION CHECK PASS — all {len(results)} mutations bit, each on a tree "
              "proven to compile.")
        return 0
    print("MUTATION CHECK FAIL")
    for name, verdict in bad:
        why = ("the guarded behaviour is not actually tested"
               if verdict == SURVIVES else "the verdict is not believable")
        print(f"  {verdict:13} {name} — {why}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
