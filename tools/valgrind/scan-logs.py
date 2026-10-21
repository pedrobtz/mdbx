#!/usr/bin/env python3
"""Scan R CMD check --use-valgrind output for findings that belong to mdbx.

Maintainer-only; tools/ is in .Rbuildignore. Used by the valgrind leg of
.github/workflows/native-checks.yaml.

CI runs valgrind with CRAN's own options, so every process's ERROR SUMMARY is
the line CRAN's log will show; this prints them all. It then fails on:

* any memory error valgrind reports (invalid access, uninitialised use, a
  syscall given uninitialised bytes, a bad free, valgrind failing to start);
* any definitely or indirectly lost block;
* any possibly lost block whose allocation stack passes through mdbx code.

A possibly lost block allocated entirely by R or glibc -- R's own setenv()
bookkeeping, a thread's TLS -- is listed but does not fail the leg: it is not
this package's to fix, and CRAN sees it for every package.

Usage: scan-logs.py FILE...
"""

import re
import sys

ERROR_LINE = re.compile(
    r"^valgrind: "
    r"|Invalid (read|write|free)"
    r"|Mismatched free"
    r"|uninitialised"
    r"|Conditional jump or move depends"
    r"|Syscall param"
    r"|Source and destination overlap"
    r"|fishy"
    r"|are definitely lost in loss record"
    r"|are indirectly lost in loss record"
    r"|(definitely|indirectly) lost: [1-9]"
)
POSSIBLY = re.compile(r"are possibly lost in loss record")
SUMMARY = re.compile(r"^==(\d+)== ERROR SUMMARY: (.*)")
OURS = re.compile(r"mdbx\.c|r_mdbx|r_flags|cpp11\.cpp|/mdbx/")


def stack(lines, i):
    """The frames that follow line i, up to valgrind's blank separator."""
    out = []
    for line in lines[i + 1:]:
        if re.match(r"^==\d+== *$", line):
            break
        out.append(line)
    return out


def main(paths):
    failures = []
    summaries = []
    ignored = []

    for path in paths:
        with open(path, errors="replace") as fh:
            lines = fh.read().splitlines()
        for i, line in enumerate(lines):
            m = SUMMARY.match(line)
            if m:
                summaries.append(m.group(2))
            if ERROR_LINE.search(line):
                failures.append((path, line, stack(lines, i)))
            elif POSSIBLY.search(line):
                frames = stack(lines, i)
                if any(OURS.search(f) for f in frames):
                    failures.append((path, line, frames))
                else:
                    ignored.append((path, line, frames))

    print("ERROR SUMMARY lines, as CRAN's log will show them:")
    for text in sorted(set(summaries)):
        print(f"  {summaries.count(text):4d} x {text}")

    if ignored:
        print("\npossibly lost outside this package (listed, not counted):")
        for path, line, frames in ignored:
            print(f"--- {path}\n{line}")
            print("\n".join(frames[:8]))

    if failures:
        print("\nfindings:")
        for path, line, frames in failures:
            print(f"--- {path}\n{line}")
            print("\n".join(frames[:30]))
        print("::error::valgrind reported a memory error or leak in mdbx")
        return 1

    print("\nvalgrind reported no errors or leaks in mdbx.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("No check output to scan.", file=sys.stderr)
        sys.exit(1)
    sys.exit(main(sys.argv[1:]))
