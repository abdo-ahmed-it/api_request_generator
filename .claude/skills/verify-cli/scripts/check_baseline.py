#!/usr/bin/env python3
"""Run `dart analyze` and report the delta against the known baseline.

`analysis_options.yaml` is just `include: package:lints/recommended.yaml`, and
19 lib-side violations plus 1 test warning stand unfixed. Reporting the raw
count hides a regression inside the furniture, so this compares issue-by-issue.

Exit 0 when nothing new appeared, 1 otherwise (also 1 if analyze itself fails).
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

# One entry per pre-existing issue: (file suffix, line, lint name).
# Line numbers are part of the key on purpose — an issue that moved is worth a
# look, and re-baselining is a deliberate act, not a silent one.
BASELINE: dict[tuple[str, int, str], int] = {
    ("test/core/server/api_web_server_relogin_test.dart", 42, "unused_element_parameter"): 1,
    ("lib/src/cli/ui/endpoint_selector.dart", 194, "unnecessary_brace_in_string_interps"): 1,
    ("lib/src/cli/ui/endpoint_selector.dart", 199, "unnecessary_brace_in_string_interps"): 1,
    ("lib/src/cli/ui/file_browser.dart", 69, "unnecessary_brace_in_string_interps"): 1,
    ("lib/src/core/json_to_dart/helpers.dart", 5, "non_constant_identifier_names"): 1,
    # PRIMITIVE_TYPES' five members are all declared on line 21.
    ("lib/src/core/json_to_dart/helpers.dart", 21, "constant_identifier_names"): 5,
    # Both halves of the `Type != String` comparison that never fires — a real bug.
    ("lib/src/core/json_to_dart/helpers.dart", 87, "unrelated_type_equality_checks"): 2,
    # HttpMethod's GET..DELETE, all on line 5. Intentional: the names are
    # compared against HTTP verb strings.
    ("lib/src/core/models/api_endpoint.dart", 5, "constant_identifier_names"): 5,
    ("lib/src/core/resolution/response_resolver.dart", 134, "empty_catches"): 1,
    ("lib/src/core/resolution/response_resolver.dart", 146, "empty_catches"): 1,
    ("lib/src/core/sources/openapi_source.dart", 522, "unintended_html_in_doc_comment"): 1,
}

# "  info - path/to/file.dart:12:34 - Message here. - lint_name"
LINE_RE = re.compile(
    r"^\s*(?P<sev>info|warning|error)\s+-\s+(?P<path>[^:]+):(?P<line>\d+):\d+\s+-\s+(?P<rest>.*)$"
)


def parse(output: str) -> list[tuple[str, int, str, str]]:
    """-> [(path, line, lint, severity)] for every diagnostic in the output."""
    found = []
    for raw in output.splitlines():
        m = LINE_RE.match(raw)
        if not m:
            continue
        rest = m.group("rest")
        # The lint name is the last ` - `-separated field.
        lint = rest.rsplit(" - ", 1)[-1].strip() if " - " in rest else rest.strip()
        found.append((m.group("path").strip(), int(m.group("line")), lint, m.group("sev")))
    return found


def expected_count(key: tuple[str, int, str]) -> int:
    return BASELINE.get(key, 0)


def main() -> int:
    # scripts/ -> verify-cli/ -> skills/ -> .claude/ -> repo root
    root = Path(__file__).resolve().parents[4]
    proc = subprocess.run(
        ["dart", "analyze"],
        cwd=root,
        capture_output=True,
        text=True,
    )
    output = proc.stdout + proc.stderr

    if proc.returncode not in (0, 1, 2):
        print(output)
        print(f"FAIL: `dart analyze` exited {proc.returncode}.")
        return 1

    found = parse(output)

    seen: dict[tuple[str, int, str], int] = {}
    for path, line, lint, _sev in found:
        seen[(path, line, lint)] = seen.get((path, line, lint), 0) + 1

    errors = [f for f in found if f[3] == "error"]

    sev_of = {(p, l, li): s for p, l, li, s in found}
    new: list[tuple[str, int, str, str, int]] = []
    for key, count in sorted(seen.items()):
        surplus = count - expected_count(key)
        if surplus > 0:
            new.append((*key, sev_of[key], surplus))

    gone = sorted(k for k, n in BASELINE.items() if seen.get(k, 0) < n)

    print(f"dart analyze: {len(found)} issue(s) reported, baseline is {sum(BASELINE.values())}.")

    if errors:
        print("\nERRORS (always a blocker):")
        for path, line, lint, _ in errors:
            print(f"  {path}:{line} - {lint}")

    if new:
        print("\nNEW since baseline — these are yours:")
        for path, line, lint, sev, surplus in new:
            extra = f"  (x{surplus})" if surplus > 1 else ""
            print(f"  {sev:<7} {path}:{line} - {lint}{extra}")

    if gone:
        print("\nBaseline issues no longer reported (fixed, or the line moved):")
        for path, line, lint in gone:
            print(f"  {path}:{line} - {lint}  (expected {BASELINE[(path, line, lint)]}, saw {seen.get((path, line, lint), 0)})")
        print("  If you fixed them, update BASELINE in this script.")

    if new or errors:
        print("\nFAIL: new analyzer issues.")
        return 1

    print("\nOK: no new analyzer issues.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
