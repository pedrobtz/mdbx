# CLAUDE.md

<!-- markdownlint-disable-next-line MD013 -->
This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Shared conventions

The portfolio's shared rules are synced into `.claude/shared/` from
`pedrobtz/packages:claude/shared/`. Never edit them here. Where this file and
a shared file disagree, this file wins for this package.

@.claude/shared/workflow.md
@.claude/shared/r-package.md
@.claude/shared/ci.md
@.claude/shared/native-code.md
@.claude/shared/correctness.md
@.claude/shared/assurance.md

`AGENTS.md` is a symlink to this file, so other agents read the same text;
they do not follow the `@` imports above, which name the files to read.

## What this is

`mdbx` is an R binding to [libmdbx](https://libmdbx.dqdkfa.ru/), an embedded
transactional key-value store, vendored and compiled into the package. The
licence is MIT; libmdbx is Apache-2.0.

The exported API mirrors the C API: `mdbx_env_*`, `mdbx_txn_*`, `mdbx_dbi_*`
and bare `mdbx_get`/`mdbx_put`/`mdbx_del`. Storage is bytes; a missing key
reads as `NULL`. Keys and values go in as a raw vector or a single string
stored as UTF-8, and come back decoded as text unless `as = "raw"`, settled
in Stage 4, following `clibmdbx`. Serialization of R objects is deliberately
*not* the engine layer's job. Durability was settled in Stage 5.6, also
following `clibmdbx`: flags pass through by name
(`flags = c("SAFE_NOSYNC", ...)`) rather than through a curated enum, and
nothing is relaxed by default. Database handle representation was settled in
Stage 8: a name re-resolved per transaction, never cached across one,
because an aborted transaction poisons a `MDBX_dbi`.

0.1.0 shipped: the vendored build, env open/close with flags and geometry,
read/write transactions, get/put/delete, named databases with per-database
stat, listing, dropping and sequences, ordered and resumable key/item scans,
stat/info/limits, routine registration, three-platform builds, and the
lifecycle, fork and panic tests. **Cursors, batch entry points
(`mdbx_get_many()` and friends), duplicate keys (`DUPSORT`), and
serialization are 0.2**: see the *Feature gap against `clibmdbx`* section of
[.agents/roadmap.md](.agents/roadmap.md), which ranks them by implementation
cost.

Four questions remain open and should not be settled unilaterally: where
serialization lives, how much of the cursor API to expose, map resizing, and
the on-disk layout beyond the `subdir` default.
[.agents/design.md](.agents/design.md) has the reasoning for each.

`.agents/` holds four documents, and nothing in them repeats what the code
already says. [.agents/roadmap.md](.agents/roadmap.md) is the staged plan
through 0.1.0 with the per-stage findings, the feature gap against
`clibmdbx` ranked by cost, the *Open questions* table, and the upstream
reference links: start here, and respect what it defers to 0.2. Unlike the
shared convention, its headings carry status (`— **DONE**`).
[.agents/design.md](.agents/design.md) records **why** each API question was
answered the way it was, including the four still open; read the relevant
decision before revisiting one. [.agents/vendoring.md](.agents/vendoring.md)
covers the pin, the build flags and the patch series.
[.agents/formal-verification.md](.agents/formal-verification.md) is a
proposal to specify the lifecycle and transaction protocol as a Lean state
machine.

## Current state

**0.1.2 is on CRAN**, published on 23 October 2026 (crandb, verified
2026-11-11). Its history explains much of the build:

- 0.1.0 was accepted on 27 September 2026, at the third upload. CRAN's
  clang-UBSAN, gcc-UBSAN and M1-SAN checks then reported undefined behaviour
  in the bundled libmdbx.
- 0.1.1 was the fix, published on 28 September 2026.
- 0.1.1 was archived on 19 October 2026 for CRAN's valgrind reports (#30).
- 0.1.2 fixes those, in the bundled libmdbx (patches 0007–0009).

Every stage of the roadmap through Stage 7 (release hardening) is done,
Stage 8 (named databases, pulled into 0.1.0) included; Stage 9 is a
proposal. The default branch carries
`0.1.2.9000`, whose one change so far makes libmdbx compile on Windows arm64
(patch 0010).

Environments live in `src/r_mdbx.cpp` + `R/env.R`, transactions in
`R/txn.R`, get/put/del in `R/data.R`, named databases in `R/dbi.R`,
stat/info in `R/stat.R`, key listing in `R/scan.R`, environment/transaction
flags in `src/r_flags.cpp` + `R/flags.R`, the concurrency contract in
`R/concurrency.R`, and condition classes in `R/conditions.R`.

## Versions and dependents

The current version's parent issue is #33, `v0.1.3`. The `cran-release`
reminder #35 opens from 2026-12-04, six weeks after 0.1.2. 0.2 is the
release whose scope is the roadmap's *Feature gap* section, cursors first.

`dastash` imports `mdbx (>= 0.1.1)` from CRAN. A change to the R API or to
the on-disk behaviour reaches it.

## Commands

<!-- markdownlint-disable MD013 -->
```sh
Rscript -e 'devtools::document()'                     # roxygen2 + cpp11::cpp_register()
Rscript -e 'testthat::test_file("tests/testthat/test-txn.R")'
R CMD INSTALL --preclean .                            # exercise src/Makevars directly
tools/update-libmdbx.sh                               # re-vendor upstream, replay the patches
tools/interop-check.sh                                # round trip with clibmdbx; needs python3, network
```
<!-- markdownlint-enable MD013 -->

After adding a `[[cpp11::register]]` function, confirm `R/cpp11.R` actually
gained the wrapper: `devtools::document()` has been observed to skip
`cpp11::cpp_register()`.

`devtools`, `roxygen2`, `testthat`, `pkgbuild`, and `rcmdcheck` are installed
against R 4.6. `tools/interop-check.sh` is a maintainer script, not part of R
CMD check: run it when bumping the vendored libmdbx, alongside
`tools/update-libmdbx.sh`. It proves a database this package writes is
readable by an independently built libmdbx, and the reverse, which nothing
in the suite can catch.

## Architecture

### Everything ships in one shared object

libmdbx is **vendored as the official amalgamation** into
`src/vendor/libmdbx/` and compiled into the package's own
`mdbx.so`/`mdbx.dll`. The amalgamation is *three* files: `mdbx.c` includes
`mdbx-internals.h` alongside `mdbx.h`. There is no submodule, no CMake, no
system libmdbx, and no separately dlopen'd library. This is what makes CRAN
builds work: the tarball is self-contained and `R CMD SHLIB` is the only
build system.

`src/Makevars` sets `PKG_CPPFLAGS = -Ivendor/libmdbx -D__dll_export=
-DMDBX_BUILD_FLAGS='"R-CMD-SHLIB"' -DMDBX_ENV_CHECKPID=1
-DMDBX_TXN_CHECKOWNER=1 -DMDBX_UNALIGNED_OK=0` and `PKG_LIBS = -pthread`,
and lists every object by hand:
`cpp11.o r_flags.o r_mdbx.o r_mdbx_hooks.o vendor/libmdbx/mdbx.o`.
`src/Makevars.win` repeats it with `-D_WIN32_WINNT=0x0A00` (mandatory: a
non-DLL libmdbx build fails with an `#error` without it),
`-DWIN32_LEAN_AND_MEAN=1`, `-DNOMINMAX=1` and
`PKG_LIBS = -lntdll -ladvapi32 -luser32`. Both files explain every flag in
their comments.

The non-obvious flags:

- `-D__dll_export=` (empty) stops libmdbx marking its symbols `dllexport`
  on Windows, so the MDBX API does not leak out of the package DLL
  alongside the registered routines.
- `MDBX_ENV_CHECKPID` / `MDBX_TXN_CHECKOWNER` make MDBX detect
  cross-process and cross-thread misuse, important because
  `parallel::mclapply()`, `future`, and `callr` can carry an open
  environment across a `fork()`.
- `MDBX_UNALIGNED_OK=0` keeps libmdbx from dereferencing misaligned
  pointers, which CRAN's UBSAN flavors reported against 0.1.0.

### cpp11 at the boundary, C underneath

The binding layer uses **cpp11** (not Rcpp, not hand-written C); the
vendored `mdbx.c` stays plain C. `mdbx.h` has `extern "C"` guards, and R
links with the C++ driver automatically once a `.cpp` is present, so the mix
needs no extra configuration. First-party source is `src/r_mdbx.cpp` /
`src/r_mdbx.h` (bindings, `mdbx_r::check()` error translation),
`src/r_flags.cpp` (the flag vocabulary, which owns the name-to-bit mapping so
it cannot drift from the vendored header), and `src/r_mdbx_hooks.cpp` / `.h`
(the panic and logging boundary the vendored source is patched to call).

Two reasons, both worth more as the batch APIs land. **Unwind safety:**
`Rf_error()` longjmps and skips destructors; cpp11 routes R API calls
through `R_UnwindProtect` and wraps every entry point in
`BEGIN_CPP11`/`END_CPP11`, so the stack unwinds and the R jump resumes at the
`.Call()` boundary. **Protection bookkeeping:** `cpp11::sexp` and
`writable::` types protect via a preserve list, removing manual
`PROTECT`/`UNPROTECT` counting from code that builds many vectors in a loop.

Keep C++ at the boundary only: conversion, result construction, error
translation, lifetimes. The MDBX-touching logic stays procedural against the
C API.

**Registration is generated.** `cpp11::cpp_register()` (run by
`devtools::load_all()` and `document()`) scans `src/*.cpp` for
`[[cpp11::register]]` and writes `src/cpp11.cpp` (call table plus
`R_init_mdbx`, which already emits `R_useDynamicSymbols(dll, FALSE)` and
`R_forceSymbols(dll, TRUE)`) and `R/cpp11.R` (internal `.Call()` wrappers).
There is no `src/init.c`. `R/mdbx-package.R` declares
`@useDynLib mdbx, .registration = TRUE`.

`cpp11::external_pointer<T, Deleter>` handles finalizers but constructs with
a nil protected field, so parent retention needs an explicit
`R_SetExternalPtrProtected()`; its copy constructor shallow-duplicates the
pointer and would double-register a finalizer, so treat these handles as
move-only.

### Ownership is the hard part

`MDBX_env *`, `MDBX_txn *`, and `MDBX_cursor *` each become an R external
pointer with a finalizer. The native hierarchy is env → txn → cursor, and a
child must never outlive its parent. The child external pointer therefore
**retains its parent** via the protected/tag fields, so GC cannot free them
in the wrong order. Finalizers must be idempotent and defensive.

Transactions end three ways (commit, abort, finalize); after commit/abort
the external pointer must be invalidated so later R calls fail cleanly
instead of dereferencing freed memory. Cursors track both explicit close and
the owning transaction ending.

### Keep the native layer thin, but batch at the C level

The lowest-level API operates on `raw` vectors: MDBX stores bytes, and
serialization policy is deliberately kept out of the engine layer. Any
encoding/serialization convenience belongs in a higher R layer.

Per-call `.Call()` overhead dominates for millions of small operations, so
batch entry points (`mdbx_get_many`, `mdbx_put_many`, `mdbx_delete_many`)
must loop **in C**, never as an R loop around `.Call()`. This is the main
performance lesson recorded from the reference bindings.

### Errors

A central `mdbx_check(rc)` helper translates MDBX status codes to R
conditions via `cpp11::stop()` (printf-style, throws rather than
longjmping), preserving the original code. Not every non-`MDBX_SUCCESS`
status is an error: "key not found" is expected to surface as `NULL` rather
than a condition.

### Reference bindings

Two Python bindings are used as prior art, and the design deliberately
follows one of them:

- **`jyj117/mdbx-py` (`clibmdbx`): the model to follow.** Vendored
  amalgamation pinned to a stable release with recorded SHA-256s, compiled
  into a single extension. Its macro set and Windows link libraries are the
  source of the `Makevars` above.
- **`wtdcode/mdbx-py`: explicitly rejected.** Git submodule + CMake
  producing a standalone shared library loaded via `ctypes`. Both halves are
  unusable in an R package: a submodule does not survive `R CMD build`, and
  CRAN builders will not run CMake.

## Invariants that are easy to break

- **An environment supports a single transaction at a time**, because
  libmdbx binds transactions to their thread and R is single-threaded.
  Closing an environment under a live transaction is a documented `SIGSEGV`,
  so `env_handle` keeps a registry of live transactions and
  `mdbx_env_close()` refuses while it is non-empty.
- **Handles do not survive `fork()`.** Both handle structs record the pid
  that created them, and every entry point plus every finalizer refuses a
  handle reached from another process. This is not belt-and-braces: before
  Stage 6 added it, any operation on an inherited environment aborted the
  child, because `MDBX_ENV_CHECKPID` only notices once a call has already
  dereferenced the mapping libmdbx drowned in its after-fork hook. Never add
  an entry point that reaches `handle->env` without going through
  `env_from_sexp()` / `txn_from_sexp()`.
- **Never relax UBSan's alignment check in CI** to get past a misaligned
  access in libmdbx again. A local `-fno-sanitize=alignment` once hid
  exactly what CRAN then reported against 0.1.0; the fix belongs at the
  source (`MDBX_UNALIGNED_OK=0`, `tools/patches/0006`).
- **Do not set `-O3`, `-flto`, or visibility flags in `Makevars`**: CRAN
  forbids packages overriding R's own optimization flags. Leave `CFLAGS` to
  R. No `-Wno-*` either: Writing R Extensions treats it as non-portable, so
  a warning is fixed by a patch instead (0004).
- **`OBJECTS` is hand-listed** in both `Makevars` files, because R only
  globs `src/` itself: keep it in sync when adding a source file. **`all:`
  stays the first rule**, so the `clean` rule that removes the vendored
  object (which `R CMD build` would otherwise ship) cannot become make's
  default goal.
- **Never edit `src/cpp11.cpp` or `R/cpp11.R` by hand**; they are generated.
- **Never hand-edit the vendored sources.** Add or change a patch,
  regenerate, and update the post-patch digests (see Vendored native code).

## Testing

- `tests/testthat/` has one file per area (`test-env.R`, `test-txn.R`,
  `test-data.R`, `test-dbi.R`, `test-stat.R`, `test-scan.R`,
  `test-flags.R`, `test-limits.R`, `test-errors.R`, `test-version.R`,
  `test-package.R`), plus `test-fork.R`, `test-process.R`,
  `test-native-safety.R` and the three `test-state-machine*.R` files.
- `test-process.R` needs the package *installed* (it spawns `Rscript`), so
  it skips under `devtools::test()` and runs under `R CMD check`.
- **The generated sequences** in `test-state-machine*.R` run public API
  calls against both the package and a reference model and compare the whole
  observable state after every step. The model in `helper-state-model.R` is
  the oracle, written from the documentation; `helper-state-runner.R`
  generates and runs the sequences. They are `skip_on_cran()`, because the
  package's limits vary by page size and a sequence that walks into a
  boundary could fail on one CRAN machine alone.
- Helpers: `helper-env.R` (throwaway paths and environments),
  `helper-fork.R` (whether this session can `fork()`: not on Windows, nor
  under Positron), `helper-keys.R` (big-endian integer keys, because byte
  order is the only order libmdbx has), `helper-subprocess.R` (separate R
  processes, since concurrency in libmdbx is between processes).
- **The suite pins `map_size`** (`test_map_size`, 8 MiB, in
  `helper-env.R`). libmdbx's default reserves about 1.6x physical RAM of
  address space per environment, and under valgrind every open would
  negotiate that reservation down. The default geometry is still exercised,
  once, in `test-env.R`.

## Continuous integration

- `R-CMD-check.yaml` calls r-actions' `r-cmd-check.yml@v1`: the runners on
  macOS, Windows and Ubuntu (release/oldrel-1), plus a Windows R-devel row
  (CRAN's incoming pretest runs on Debian and Windows R-devel), and the
  containers matching CRAN's r-devel Linux flavours, `ubuntu-clang` (clang
  23, C built as `-std=gnu23`) and `ubuntu-gcc16`. The container half is the
  leg that would have caught the C23 keyword-macro warnings before CRAN did;
  no GitHub runner is that combination. Both halves fail on a WARNING.
  There is deliberately no R-devel
  Ubuntu row, because the containers are R-devel on Linux already. It
  passes `--compact-vignettes=gs+qpdf` to build. **It has no
  `paths-ignore`, deliberately:** `--as-cran` checks the URLs in
  `README.md`, which ships in the tarball.
- `native-checks.yaml` calls `sanitizers.yml` (UBSan on a runner plus the
  R-hub clang-asan and gcc-asan containers; gcc-asan's `bounds-strict` is
  the one that sees libmdbx's trailing-array struct hacks), `lto.yml`,
  `gctorture.yml`, `rchk.yml` (cpp11 through `github-packages`) and
  `cran-special.yml` (CRAN's rcnst, rlibro and vnu checks, full runs only).
  It skips prose with a `paths-ignore` list rather than the `changes.yml`
  gate (#37 tracks gating).
  - `shuffled-tests` (own) runs the suite shuffled under three seeds, with
    `NOT_CRAN` set explicitly so the state machine has one job it is
    guaranteed to run in.
  - `valgrind` (own, not r-actions' `valgrind.yml`) matches CRAN's valgrind
    check: valgrind 3.27.1 built from source (Ubuntu's 3.22 was green where
    CRAN's run of 0.1.1 was not), CRAN's options exactly, no suppression
    file, and `tools/valgrind/fake-ram.c` preloaded so `sysconf()` reports
    256 GB, the machine class whose default-geometry opens failed in #30.
    `tools/valgrind/scan-logs.py` prints the ERROR SUMMARY lines.
- `coverage.yaml` calls `coverage.yml`, pinned by commit (it commits the
  badge). `.covrignore` leaves out `src/vendor`, about 22k expressions
  against 1k of first-party source.
- `pkgdown.yaml` builds the site from `vignettes/articles/`.

## Vendored native code

- **Library:** libmdbx, Apache-2.0, pinned at **v0.14.3** (stable,
  published 2026-08-09), amalgamation `v0.14.3-0-g251562b2`, from
  <https://github.com/erthink/libmdbx>. The tag object, commit and SHA-256 of
  every vendored file are in [.agents/vendoring.md](.agents/vendoring.md),
  with the update procedure.
- **Licence files:** `LICENSE`, `NOTICE` and `COPYRIGHT` under
  `src/vendor/libmdbx/`. `inst/COPYRIGHTS` describes the patch series in
  prose and is what ships as the Apache-2.0 section 4(b) notice, because
  `tools/` is `.Rbuildignore`d and maintainer-only. `Authors@R` credits
  Leonid Yuriev, Howard Chu, Symas Corporation and Martin Hedenfalk.
- **Patches:** the tree is **not** pristine. Ten patches in
  `tools/patches/` route libmdbx's panic and logging through R's API, drop
  nine `#pragma diagnostic ignored` lines, sidestep a false-positive
  `-Warray-bounds` from Rtools' MinGW headers, keep the pre-C23
  `bool`/`nullptr` macros from shadowing the C23 keywords, turn three
  trailing-array struct hacks into forms gcc's `-fsanitize=bounds-strict`
  accepts, retry a refused `mmap()` reservation smaller (valgrind refuses
  libmdbx's RAM-scaled default), stop GC records carrying uninitialised
  bytes to disk, expose where an environment's page-number lists start, and
  let the SEH fault handler compile on Windows arm64.
- **They are applied by the maintainer during a version bump**, never at
  build time: `tools/update-libmdbx.sh` re-vendors and replays the series.
  [tools/patches/README.md](tools/patches/README.md) is the authoritative
  record and holds the post-patch digests; the *Local patches* section of
  [.agents/vendoring.md](.agents/vendoring.md) carries the narrative: what
  each patch does, and which alternatives were rejected.
