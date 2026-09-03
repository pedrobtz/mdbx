# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

`mdbx` is an R binding to [libmdbx](https://libmdbx.dqdkfa.ru/), an embedded transactional
key-value store. **Stages 0-6 of the roadmap are done**: the vendored build is green on all five
CI legs, environments live in `src/r_mdbx.cpp` + `R/env.R`, transactions in `R/txn.R`, get/put/del
in `R/data.R`, stat/info in `R/stat.R`, key listing in `R/scan.R`, environment/transaction flags in
`src/r_flags.cpp` + `R/flags.R`, and the concurrency contract in `R/concurrency.R`. Stage 7
(release hardening) is next. `DESCRIPTION` is filled in; the license is MIT.

The exported API mirrors the C API: `mdbx_env_*`, `mdbx_txn_*`, and bare `mdbx_get`/`mdbx_put`/
`mdbx_del`. After adding a `[[cpp11::register]]` function, confirm `R/cpp11.R` actually gained the
wrapper — `devtools::document()` has been observed to skip `cpp11::cpp_register()`.

One rule worth knowing before touching the API: **an environment supports a single transaction at
a time**, because libmdbx binds transactions to their thread and R is single-threaded. Closing an
environment under a live transaction is a documented `SIGSEGV`, so `env_handle` keeps a registry
of live transactions and `mdbx_env_close()` refuses while it is non-empty.

The second rule: **handles do not survive `fork()`**. Both handle structs record the pid that
created them, and every entry point plus every finalizer refuses a handle reached from another
process. This is not belt-and-braces — before Stage 6 added it, any operation on an inherited
environment aborted the child, because `MDBX_ENV_CHECKPID` only notices once a call has already
dereferenced the mapping libmdbx drowned in its after-fork hook. Never add an entry point that
reaches `handle->env` without going through `env_from_sexp()` / `txn_from_sexp()`.

`.agents/` holds three documents, and nothing in them repeats what the code already says.
[.agents/roadmap.md](.agents/roadmap.md) is the staged plan through 0.1.0 with the per-stage
findings, the feature gap against `clibmdbx` ranked by cost, the *Open questions* table, and the
upstream reference links — start here, and respect what it defers to 0.2.
[.agents/design.md](.agents/design.md) records **why** each API question was answered the way it
was, including the four still open; read the relevant decision before revisiting one.
[.agents/vendoring.md](.agents/vendoring.md) covers the pin, the build flags and the patch series.

`AGENTS.md` is a symlink to this file. `.agents/`, `AGENTS.md`, `CLAUDE.md`, `tools/`, `docs/` and
`_pkgdown.yml` are all in `.Rbuildignore`, so none of them reach the tarball. `tools/` in
particular is maintainer-only: the patch series is described in prose in `inst/COPYRIGHTS`, which
is what actually ships as the Apache-2.0 section 4(b) notice.

## Commands

```sh
Rscript -e 'devtools::load_all()'                   # compile + load for interactive work
Rscript -e 'devtools::document()'                   # roxygen2 + cpp11::cpp_register()
Rscript -e 'devtools::test()'                       # run testthat suite
Rscript -e 'devtools::test(filter = "cursor")'      # single test file (tests/testthat/test-cursor.R)
Rscript -e 'testthat::test_file("tests/testthat/test-cursor.R")'
Rscript -e 'devtools::check()'                      # full R CMD check, what CI runs
R CMD INSTALL --preclean .                          # exercise src/Makevars directly
```

`devtools`, `roxygen2`, `testthat`, `pkgbuild`, and `rcmdcheck` are installed against R 4.6.
CI ([.github/workflows/R-CMD-check.yaml](.github/workflows/R-CMD-check.yaml)) runs `R CMD check`
on macOS, Windows, and Ubuntu (devel/release/oldrel-1).

Tests live in `tests/testthat/`: `test-env.R`, `test-txn.R`, `test-data.R`, `test-stat.R`,
`test-scan.R`, `test-flags.R`, `test-fork.R`, `test-process.R`, `test-native-safety.R`,
`test-package.R`, `test-version.R`. `test-process.R` needs the package *installed* (it spawns
`Rscript`), so it skips under `devtools::test()` and runs under `R CMD check`.

## Architecture

### Everything ships in one shared object

libmdbx is **vendored as the official amalgamation** into `src/vendor/libmdbx/` and compiled
into the package's own `mdbx.so`/`mdbx.dll`. The amalgamation is *three* files — `mdbx.c`
includes `mdbx-internals.h` alongside `mdbx.h`. There is no
submodule, no CMake, no system libmdbx, and no separately dlopen'd library. This is what makes
CRAN builds work: the tarball is self-contained and `R CMD SHLIB` is the only build system.

Expected `src/Makevars`:

```make
PKG_CPPFLAGS = -Ivendor/libmdbx -D__dll_export= -DMDBX_BUILD_FLAGS='"R-CMD-SHLIB"' \
               -DMDBX_ENV_CHECKPID=1 -DMDBX_TXN_CHECKOWNER=1
PKG_LIBS = -pthread
# cpp11.o is generated; mdbx.c compiles as C, the rest as C++. R only globs src/
# itself, so every object is listed -- keep this in sync when adding a source file.
OBJECTS = cpp11.o r_flags.o r_mdbx.o r_mdbx_hooks.o vendor/libmdbx/mdbx.o
```

and `src/Makevars.win` additionally needs `PKG_LIBS = -lntdll -ladvapi32 -luser32`.

Two non-obvious flags: `-D__dll_export=` (empty) stops libmdbx marking its symbols `dllexport`
on Windows, so the MDBX API does not leak out of the package DLL alongside the registered
routines. `MDBX_ENV_CHECKPID` / `MDBX_TXN_CHECKOWNER` make MDBX detect cross-process and
cross-thread misuse — important because `parallel::mclapply()`, `future`, and `callr` can carry
an open environment across a `fork()`.

Do **not** set `-O3`, `-flto`, or visibility flags in `Makevars`: CRAN forbids packages
overriding R's own optimization flags. Leave `CFLAGS` to R.

### cpp11 at the boundary, C underneath

The binding layer uses **cpp11** (not Rcpp, not hand-written C); the vendored `mdbx.c` stays
plain C. `mdbx.h` has `extern "C"` guards, and R links with the C++ driver automatically once a
`.cpp` is present, so the mix needs no extra configuration. `LinkingTo: cpp11` is already in
`DESCRIPTION`; First-party source is `src/r_mdbx.cpp` / `src/r_mdbx.h` (bindings, `mdbx_r::check()` error
translation), `src/r_flags.cpp` (the flag vocabulary, which owns the name-to-bit mapping so it
cannot drift from the vendored header), and `src/r_mdbx_hooks.cpp` / `.h` (the panic and logging
boundary the vendored source is patched to call).

Two reasons, both worth more as the batch APIs land. **Unwind safety:** `Rf_error()` longjmps
and skips destructors; cpp11 routes R API calls through `R_UnwindProtect` and wraps every entry
point in `BEGIN_CPP11`/`END_CPP11`, so the stack unwinds and the R jump resumes at the `.Call()`
boundary. **Protection bookkeeping:** `cpp11::sexp` and `writable::` types protect via a preserve
list, removing manual `PROTECT`/`UNPROTECT` counting from code that builds many vectors in a loop.

Keep C++ at the boundary only — conversion, result construction, error translation, lifetimes.
The MDBX-touching logic stays procedural against the C API.

**Registration is generated.** `cpp11::cpp_register()` (run by `devtools::load_all()` and
`document()`) scans `src/*.cpp` for `[[cpp11::register]]` and writes `src/cpp11.cpp` (call table
plus `R_init_mdbx`, which already emits `R_useDynamicSymbols(dll, FALSE)` and
`R_forceSymbols(dll, TRUE)`) and `R/cpp11.R` (internal `.Call()` wrappers). Never edit those two
by hand, and there is no `src/init.c`. Planned layout is `src/r_mdbx.cpp`, `src/r_mdbx.h`, the
two generated files, plus the vendor tree. `R/mdbx-package.R` already declares
`@useDynLib mdbx, .registration = TRUE`.

`cpp11::external_pointer<T, Deleter>` handles finalizers but constructs with a nil protected
field, so parent retention needs an explicit `R_SetExternalPtrProtected()`; its copy constructor
shallow-duplicates the pointer and would double-register a finalizer, so treat these handles as
move-only.

### Ownership is the hard part

`MDBX_env *`, `MDBX_txn *`, and `MDBX_cursor *` each become an R external pointer with a
finalizer. The native hierarchy is env → txn → cursor, and a child must never outlive its
parent. The child external pointer therefore **retains its parent** via the protected/tag
fields, so GC cannot free them in the wrong order. Finalizers must be idempotent and defensive.

Transactions end three ways (commit, abort, finalize); after commit/abort the external pointer
must be invalidated so later R calls fail cleanly instead of dereferencing freed memory. Cursors
track both explicit close and the owning transaction ending.

### Keep the native layer thin, but batch at the C level

The lowest-level API operates on `raw` vectors — MDBX stores bytes, and serialization policy is
deliberately kept out of the engine layer. Any encoding/serialization convenience belongs in a
higher R layer.

Per-call `.Call()` overhead dominates for millions of small operations, so batch entry points
(`mdbx_get_many`, `mdbx_put_many`, `mdbx_delete_many`) must loop **in C**, never as an R loop
around `.Call()`. This is the main performance lesson recorded from the reference bindings.

### Errors

A central `mdbx_check(rc)` helper translates MDBX status codes to R conditions via
`cpp11::stop()` (printf-style, throws rather than longjmping), preserving the original code. Not every non-`MDBX_SUCCESS` status is an error — "key not found" is expected to
surface as `NULL` rather than a condition.

## Reference bindings

Two Python bindings are used as prior art, and the design deliberately follows one of them:

- **`jyj117/mdbx-py` (`clibmdbx`) — the model to follow.** Vendored amalgamation pinned to a
  stable release with recorded SHA-256s, compiled into a single extension. Its macro set and
  Windows link libraries are the source of the `Makevars` above.
- **`wtdcode/mdbx-py` — explicitly rejected.** Git submodule + CMake producing a standalone
  shared library loaded via `ctypes`. Both halves are unusable in an R package: a submodule does
  not survive `R CMD build`, and CRAN builders will not run CMake.

## The vendor tree is patched

`src/vendor/libmdbx/` is **not** pristine. Four patches in `tools/patches/` route libmdbx's panic
and logging through R's API, drop nine `#pragma diagnostic ignored` lines, and sidestep a
false-positive `-Warray-bounds` from Rtools' MinGW headers. They are applied **by the maintainer
during a version bump**, never at build time — `tools/update-libmdbx.sh` re-vendors and replays
the series. Never hand-edit the vendored sources: add or change a patch, regenerate, and update
the post-patch digests in `tools/patches/README.md`. The *Local patches* section of
[.agents/vendoring.md](.agents/vendoring.md) carries the narrative — what each patch does, and
which alternatives were rejected.

## Licensing

libmdbx is Apache-2.0. Keep its `LICENSE`/`NOTICE` under `src/vendor/libmdbx/`, declare the
vendored code in `DESCRIPTION` and `inst/COPYRIGHTS`, and keep the vendor tree clearly separated
from first-party source. Pin a stable release (not master/RC), record the tag, amalgamation
commit, and checksums, and write down the update procedure.

## Scope

0.1.0 shipped: the vendored build, env open/close with flags and geometry, read/write
transactions, get/put/delete, named databases with per-database stat, listing, dropping and
sequences, ordered and resumable key/item scans, stat/info/limits, routine registration,
three-platform builds, and the lifecycle, fork and panic tests. **Cursors, batch entry points
(`mdbx_get_many()` and friends), duplicate keys (`DUPSORT`), and serialization are 0.2** — see the
*Feature gap against `clibmdbx`* section of [.agents/roadmap.md](.agents/roadmap.md), which ranks
them by implementation cost.

Storage is bytes; a missing key reads as `NULL`. Keys and values go in as a raw vector or a single
string stored as UTF-8, and come back decoded as text unless `as = "raw"` — settled in Stage 4,
following `clibmdbx`. Serialization of R objects is deliberately *not* the engine layer's job.
Durability was settled in Stage 5.6, also following `clibmdbx`: flags pass through by name
(`flags = c("SAFE_NOSYNC", ...)`) rather than through a curated enum, and nothing is relaxed by
default. Database handle representation was settled in Stage 8 — a name re-resolved per
transaction, never cached across one, because an aborted transaction poisons a `MDBX_dbi`.

Four questions remain open and should not be settled unilaterally: where serialization lives, how
much of the cursor API to expose, map resizing, and the on-disk layout beyond the `subdir`
default. [.agents/design.md](.agents/design.md) has the reasoning for each.
