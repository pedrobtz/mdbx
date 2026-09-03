# Roadmap to mdbx 0.1.0

Staged plan for the first usable release. [design.md](design.md) is the architecture; this file
is the order of work and the definition of done.

**0.1.0 delivers** a low-level, byte-oriented MDBX binding: vendored build, environment
open/close, read/write transactions, raw `get`/`put`/`del`, commit/abort, external-pointer
lifecycle safety, basic stat/info, and three-platform builds.

**0.1.0 explicitly does not deliver** cursors, named databases, batch operations, serialization
or codecs, character-key convenience, map resizing, or a high-level `mdbx()` object. Those are
0.2 and should not leak into these stages — see *Possible Second Phase* in design.md.

Stages are ordered by risk, not by API surface. Stage 1 is the one that can fail on a platform
you do not own, so it happens before any binding work.

---

## Stage 0 — Clear the scaffold — **DONE**

- [x] `DESCRIPTION`: real `Title`, `Description`, `Authors@R`, plus `URL` and `BugReports`.
- [x] `.Rbuildignore`: `^\.agents$`, `^AGENTS\.md$`, `^CLAUDE\.md$`.
- [x] `LICENSE` reduced to the DCF stub required by `License: MIT + file LICENSE`.
- [x] Deleted `src/code.cpp`; `cpp11::cpp_register()` then removed `src/cpp11.cpp` and
      `R/cpp11.R` on its own, since nothing carries `[[cpp11::register]]` any more.
- [x] Replaced `tests/testthat/test-mbdx.R` with `test-package.R` holding a load smoke test.
- [x] Removed stray build artifacts (`code.o`, `cpp11.o`, `mdbx.so`).

**Done:** `R CMD check` is 0 errors / 0 warnings / 0 notes.

### What Stage 0 had to remove, and Stage 1 must restore

Deleting the only native source left the package unable to carry its native scaffolding, so two
things came out of the tree and have to go back in Stage 1:

- `@useDynLib mdbx, .registration = TRUE` in `R/mdbx-package.R` — with no shared object to load,
  it fails the install outright. The line is still there, commented, with a note.
- `LinkingTo: cpp11` in `DESCRIPTION` — `R CMD check` NOTEs it as unused once `src/` is empty.

Also worth knowing: `testthat::test_check()` errors with *No test files found* on an empty
`tests/testthat/`, so the directory can never be left bare.

---

## Stage 1 — Vendored build — **substantially done**

- [x] Restored `LinkingTo: cpp11` and `@useDynLib`.
- [x] Pinned **v0.14.3**, the release at which upstream declared 0.14.x stable and bug-fix-only.
- [x] Recorded tag object, commit, amalgamation id, and SHA-256s in [vendoring.md](vendoring.md).
- [x] Vendored `mdbx.c`, `mdbx.h`, `mdbx-internals.h`, `LICENSE`, `NOTICE`, `COPYRIGHT`.
- [x] `src/Makevars` + `src/Makevars.win`.
- [x] `inst/COPYRIGHTS`.
- [x] `mdbx_version()` probe plus a test asserting it equals the pin.
- [x] Patched the vendored panic/logging paths and removed nine diagnostic suppressions, so
      `R CMD check --as-cran` is 0 errors / 0 warnings — see [vendoring.md](vendoring.md).
- [x] Initialize libmdbx at fatal-only logging before user code can fork, and contain panics below
      C++ with a poison callback that Stage 2 handles must implement.
- [x] **macOS and all three Linux legs green.**
- [x] **Windows leg green** — the significant warning from Rtools' own `psdk_inc/intrin-impl.h`
      (`-Warray-bounds`) is patched out at the source in `tools/patches/0004`. All five legs green.

Local macOS/arm64: builds and links with zero compiler warnings, and
`mdbx_version()` reports `v0.14.3-0-g251562b2`.

### What Stage 1 turned up

- **The amalgamation is three files, not two.** `mdbx.c` includes `mdbx-internals.h`. The design
  doc's two-file assumption would not have compiled.
- **There is no amalgamation archive to download.** Since end-2025 libmdbx ships *only*
  amalgamated, so the release tag's tree already is it; `make dist` just prints a notice.
- **`_WIN32_WINNT` is mandatory on Windows.** A non-DLL build `#error`s without it.
- **A `clean:` target in `Makevars` breaks the build** — it becomes make's default goal, so the
  build cleans and never compiles. Earlier advice to add one was wrong; `shlib-clean` already
  covers `OBJECTS`. What *is* needed is an `.Rbuildignore` entry, because `R CMD build` strips
  `src/*.o` but not objects in `src/` subdirectories.
- **`MDBX_BUILD_FLAGS` must be defined** or `mdbx.c` emits a `#warning`.
- Two `R CMD check` warnings could not be cleared by any build flag, so the vendored source is
  patched instead (see [vendoring.md](vendoring.md)). The vendor tree is therefore no longer pristine and
  the patches must be re-applied on every version bump.
- R's pragma check only matches `^\s*#pragma (GCC|clang) diagnostic ignored`, so MSVC
  `#pragma warning(disable: ...)` is irrelevant to it — only nine lines needed touching, not the
  45 pragmas a first count suggested.
- **Removing the nine diagnostic suppressions is safe on GCC.** That was the open risk in
  `tools/patches/0003`, verifiable only on clang locally; the green Linux legs settle it.
- **The Windows `-Warray-bounds` warning is fixed at the source, not with a flag.** It comes from
  Rtools' `psdk_inc/intrin-impl.h` when libmdbx includes the Windows intrinsics — a toolchain false
  positive, unrelated to libmdbx or the other patches. Suppressing it is worse than the warning:
  `-Wno-array-bounds` trades it for a "checking compilation flags used" WARNING, since Writing R
  Extensions treats `-Wno-*` as non-portable and warns that suppressing diagnostics hides real
  problems on untested platforms, and generating the flag from `configure.win` is called out as
  unsafe for the same reason. What works instead is narrowing the blast radius: the warning fires
  only at the two `NtCurrentTeb()` call sites in `mdbx.c`, so `tools/patches/0004` reads the same
  `NT_TIB::Self` slot with one inline asm load, under a `MinGW && GCC && !clang && x86_64` guard.
  No `cran-comments.md` exception needed.

## Stage 2 — Environment lifecycle

First real binding work. This stage sets the patterns every later stage copies.

- [x] `MDBX_env *` as an external pointer with an idempotent finalizer.
- [x] The error-translation helper — `mdbx_r::check(rc)` in `src/r_mdbx.h`, `cpp11::stop()`,
      preserving the MDBX code.
- [x] `mdbx_env_open(path, readonly, create, subdir, max_dbs, map_size)` and `mdbx_env_close(env)`, plus
      `mdbx_env_is_open(env)`.
- [x] S3 class over the external pointer, plus a `print()` method.
- [x] Tests: open, close, reopen, nonexistent path, double close, close-then-use, finalization
      under `gc()`.

**Done when:** an environment can be opened and closed repeatedly with no leak and no crash on
misuse, and the error helper produces readable conditions. — **Met.** 45 assertions in
`tests/testthat/test-env.R`; `R CMD check --as-cran` still 0 errors / 0 warnings (the two NOTEs
are "New submission" and a local HTML Tidy too old to run).

### What Stage 2 turned up

- **The R object model is settled: external pointer + S3, nothing more.** The `mdbx_env` object
  *is* the `EXTPTRSXP`, carrying `class` and the opening parameters (`path`, `readonly`,
  `subdir`) as attributes. No list wrapper, no environment, no R6. This answers the open question
  in design.md.
- **Those attributes must be attached in C, not R.** Setting an attribute on an external pointer
  from R can duplicate the SEXP, and `duplicate()` copies the address but *not* the finalizer,
  which is registered against the original SEXP. If only the copy stayed reachable, the original
  would be collected and would close the environment out from under it. So `new_env_sexp()` sets
  class and attributes while the object is still fresh, and R only ever reads them.
- **The finalizer cannot raise.** Closing is shared between `mdbx_env_close()` and the finalizer via
  a `propagate` flag: the explicit path turns a failure into an R condition, the GC path swallows
  it. `R_ClearExternalPtr()` happens *before* the close so a double finalize cannot reach freed
  memory.
- **A poisoned environment is never closed.** Re-entering libmdbx to close a handle whose
  invariants it has already rejected is how a contained panic would become a crash; the handle is
  detached and the env is left to the OS. This is the poison callback Stage 1 said Stage 2 owed.
- **One poison callback per context struct.** A single shared callback reading a common first
  member would work only by relying on standard-layout punning, and would silently corrupt the
  wrong field the first time a context grew a different shape.
- **`create = FALSE` has no MDBX flag behind it.** MDBX creates unless `MDBX_RDONLY`, so this is
  an R-level `file.exists()` check that exists to produce a better message than a bare `ENOENT`.
- **`mdbx_env_set_maxdbs()` is an inline wrapper** over `mdbx_env_set_option(MDBX_opt_max_db)`;
  there is no separate exported symbol.
- **Finalization is only testable with a counter.** `mdbx_env_live_count_()` is an internal hook
  that reports live handles, which is what lets the `gc()` tests assert reclamation rather than
  merely assert that nothing crashed.
- **Fork tests cannot run in every R session.** Positron refuses to fork (`parallel:::mcfork()`
  raises "Can't fork the R session"), so `skip_if_cannot_fork()` in
  `tests/testthat/helper-fork.R` gates them. It probes with one real fork rather than sniffing for
  a front-end, because no portable predicate exists. Stage 6's fork tests must use it too, and
  fork coverage therefore comes from `Rscript`/`R CMD check`/CI, not from an IDE session.
- **The after-fork test asserts a signature, not an empty stream.** libmdbx's `rthc_afterfork()`
  logs `drown %d rthc entries` at NOTICE, plus `drown env %p` per live environment; package load
  lowers the level to FATAL so none appear. Asserting the message stream is *empty* also asserted
  that no front-end writes to stderr while forking, which Positron does -- an unrelated failure.
  The test now greps for `drown|rthc` and carries a positive control so it cannot pass vacuously.
  Verified by `dyn.load()`ing the shared object without `.onLoad`, which prints
  `rthc_afterfork:36867 drown 0 rthc entries` and fails the assertion as intended.
- **`TRUE` is not portable in this package's C++.** `mdbx.h` includes `<windows.h>`, whose
  `windef.h` defines `TRUE`/`FALSE` as plain ints, shadowing R's `Rboolean` enumerators in every
  TU that includes `r_mdbx.h`. C++ will not convert implicitly, so
  `R_RegisterCFinalizerEx(p, f, TRUE)` builds everywhere except Windows; `Rboolean::TRUE` is no
  fix, because the macro expands inside the qualified name too. Use `mdbx_r::r_true` /
  `mdbx_r::r_false` from `r_mdbx.h`. Stage 3 registers more finalizers and will need them.
- **Only clang is available locally; four of the five CI legs are GCC.** Stage 2's first CI run
  failed on Windows for the `TRUE` collision, which no macOS build could have caught. Where a
  platform-specific hazard is suspected, reproduce it in a small translation unit rather than
  waiting on CI -- `#undef TRUE` / `#define TRUE 1` after including the header reproduces the
  Windows condition exactly. Ownership in `mdbx_env_open_()` is a `unique_ptr` for the same
  reason: the earlier `delete` + `check()` + fall-through was correct only because `check()`
  always throws there, which GCC 14's `-Wuse-after-free` cannot see.
- **Map geometry is deliberately one-dimensional for now.** `map_size` sets only the upper bound
  via `mdbx_env_set_geometry(-1, -1, size, -1, -1, -1)`; lower bound, growth step and shrink
  threshold stay at MDBX defaults. *Environment resizing* remains open.

---

## Stage 3 — Transactions and the ownership model

The correctness core of the package. Nothing here is about MDBX features; it is all about making
misuse impossible from R.

- [x] `MDBX_txn *` as an external pointer that **retains its environment** in the protected
      field, so GC cannot close the env under a live transaction.
- [x] Explicit state tracking: `active` / `committed` / `aborted`. Invalidate the pointer on
      commit and abort so later calls fail in R before reaching MDBX.
- [x] `mdbx_txn_begin(env, write =)`, `mdbx_txn_commit(txn)`, `mdbx_txn_abort(txn)`, plus `mdbx_txn_state()`.
- [x] `mdbx_with_read()` / `mdbx_with_write()` using `on.exit()` for guaranteed termination.
- [x] Tests: use-after-commit, use-after-abort, double commit, abandoning a transaction to GC,
      the one-transaction-per-thread rule, writer serialization.

**Done when:** every misuse path in the design's *Transactions* test list produces an R error,
and none of them can segfault. — **Met.** 61 assertions in `tests/testthat/test-txn.R`;
`R CMD check --as-cran` 0 errors / 0 warnings / 0 notes.

### What Stage 3 turned up

- **An environment supports one transaction at a time, per thread — so, in R, one at a time.**
  This is the headline finding and it was not anticipated: libmdbx binds a transaction to its
  thread, and reports the *same* rule four different ways depending on the pair — `MDBX_BAD_RSLOT`
  (read+read), `MDBX_TXN_OVERLAPPING` (either mixed pair), `MDBX_BUSY` (write+write). Verified by
  probing all four combinations. The binding checks the registry and reports it once, clearly.
  Distinct environments are independent (also verified). `MDBX_NOSTICKYTHREADS` is what lifts the
  restriction, and setting it would forfeit the `MDBX_TXN_CHECKOWNER` protection the project
  deliberately compiles in — so it is not set, and "concurrent readers" means *processes*.
- **Closing an environment under a live transaction is a documented SIGSEGV**, not an error code:
  `mdbx_env_close_ex()` says all transactions must be closed first and using one afterwards "is UB
  and would cause a `SIGSEGV`". So `env_handle` carries a registry of live transactions.
  `mdbx_env_close()` refuses while it is non-empty, rather than silently aborting the caller's work.
- **The registry is what makes finalizer order irrelevant.** R does not guarantee the order it
  runs two finalizers in, so an environment and its transaction becoming garbage in one cycle
  could see the env close first and the transaction's finalizer then abort freed memory. The env
  finalizer detaches its transactions before closing; whichever runs first cleans up, the other
  finds nothing. Covered by a test that drops both together.
- **A failed commit still ends the transaction.** `mdbx_txn_commit_ex()` documents that any result
  other than `MDBX_THREAD_MISMATCH` terminates it and invalidates the handle — a commit that
  cannot complete is aborted instead. So the handle is cleared on every result *except*
  `MDBX_THREAD_MISMATCH`, which is the one case where the transaction is still alive and ours.
  Getting this backwards would have been a use-after-free on an error path that tests rarely hit.
- **Commit and abort differ deliberately on idempotence.** Abort is a no-op on a finished
  transaction, so `on.exit(mdbx_txn_abort(txn))` composes with an explicit commit — which is exactly
  how `mdbx_with_write()` is written. Commit is not: committing twice is a logic error.

---

## Stage 4 — Raw get / put / delete

- [x] `MDBX_val` ↔ `raw` vector conversion. Copy on read; do not hand R a pointer into the map.
- [x] `mdbx_get(txn, key, default =)`, `mdbx_put(txn, key, value, overwrite =)`,
      `mdbx_del(txn, key)`.
- [x] **Missing-key semantics: `NULL`**, with a `default` argument. Settled — see design.md.
- [x] **Key encoding: raw, or a single string stored as UTF-8 bytes**, for keys and values both.
      Settled — see design.md. First implemented as raw-only following `clibmdbx`, then revised:
      `charToRaw()` at every call site is bad R in a way `b"key"` is not bad Python. Strings are
      run through `enc2utf8()` first, without which the same text would be a different key
      depending on the string's `Encoding()` flag.
- [x] Tests: roundtrip, missing key, overwrite vs. `MDBX_NOOVERWRITE`, zero-length value, large
      value, keys containing embedded NUL bytes, non-raw input rejected.

**Done when:** the design's *Core operations* test list passes. — **Met.** 44 assertions in
`tests/testthat/test-data.R`; `R CMD check --as-cran` 0 errors / 0 warnings / 0 notes.

### What Stage 4 turned up

- **The reference binding settled the return-value questions, but not the encoding one.**
  `clibmdbx`'s `put` "returns False for NOOVERWRITE/NODUPDATA conflicts and otherwise True" and its
  `delete` "returns whether a record existed" — the same "absence and conflict are data, not
  errors" policy adopted here. Its bytes-only rule was adopted and then reversed: what is
  ergonomically free in Python (`b"key"`) is not free in R (`charToRaw("key")`).
- **`charToRaw()` is the wrong conversion for a key.** It returns whatever bytes the string
  happens to carry, so the same text yields different bytes depending on its `Encoding()` flag —
  measured: `63 61 66 e9` versus `63 61 66 c3 a9` for `"café"`. Character keys go through
  `enc2utf8()` first so they mean the same bytes on every platform, and a test asserts a
  latin1-flagged string and its UTF-8 form find the same record.
- **libmdbx exposes no constant for the main database.** There is no public `MAIN_DBI`, so the
  unnamed database has to come from `mdbx_dbi_open(txn, NULL, ...)`. It is opened lazily on the
  first data operation and cached on the *transaction*, not the environment: that scopes the
  handle's validity to exactly the transaction that opened it, and libmdbx documents that
  `mdbx_dbi_open()` may be called from any transaction, unlike LMDB.
- **Copying reads is mandatory, not cautious.** `mdbx_get()` documents that returned memory is
  owned by the database, is "valid only until a subsequent update operation, or the end of the
  transaction", and that writing through it "will silently accepted and likely will lead to DB
  and/or data corruption". A test overwrites a key in a later transaction and checks the earlier
  vector is intact.
- **MDBX's key limits are far looser than LMDB's**, and were measured rather than assumed: keys of
  0, 511, 2000 and 4000 bytes all work, as do 16 MiB values, and an empty key round-trips. The
  511-byte figure that LMDB experience suggests does not apply.
- **The exported API mirrors the C API.** Renamed after Stage 4: `mdbx_env_open` / `mdbx_env_close`
  / `mdbx_env_is_open` and `mdbx_txn_begin` / `mdbx_txn_commit` / `mdbx_txn_abort`, joining the
  `mdbx_txn_state` that already used the prefix. `mdbx_get` / `mdbx_put` / `mdbx_del` were already
  identical to C and did not move; `mdbx_with_read` / `mdbx_with_write` keep their names, having no
  C counterpart. Done while nothing is released, when it costs only a mechanical edit. Note that
  `src/` was deliberately excluded from the rename -- the same identifiers there are calls into
  libmdbx itself.
- **Naming settled: `mdbx_del()`**, matching the C API and the rest of the exported surface.
  design.md's *Public R API* sketch has been corrected to agree.

---

## Stage 5 — Stat and info

- [x] `mdbx_env_stat(x)` and `mdbx_env_info(x)` returning plain R lists, each taking an
      environment or a transaction. Named for the C mirror, not the `mdbx_stat` this list first
      said, since the underlying calls are `mdbx_env_stat_ex` / `mdbx_env_info_ex`.
- [x] Round out `mdbx_version()` with build metadata, under `$build`.

**Done when:** values are sane and documented; no new native machinery required. — **Met.** 39
assertions in `tests/testthat/test-stat.R`; `R CMD check --as-cran` 0 errors / 0 warnings /
0 notes.

### What Stage 5 turned up

- **The env-level statistics do not report "the last committed" state, whatever the docs say.**
  `mdbx_env_stat_ex()` documents a null transaction as giving "a snapshot from the last committed
  write transaction", but measured behaviour is looser: while the calling thread holds a live write
  transaction, the environment form reports *that* transaction's state, uncommitted writes
  included, and drops back on abort — 0 committed, 5 mid-transaction, 0 after abort. The
  documentation and tests describe what was measured, not the upstream sentence. In a
  single-threaded R session the environment and transaction forms therefore agree; they can only
  diverge across processes.
- **`devtools::document()` silently skipped `cpp11::cpp_register()`** after new `[[cpp11::register]]`
  functions were added, so the build succeeded while the R wrappers were missing and the failure
  only appeared at call time. Run `cpp11::cpp_register()` directly, or check `R/cpp11.R` actually
  gained the new names, after adding a native entry point.
- **`MDBX_envinfo` is mostly diagnostics.** Only a curated subset is exposed; meta-page signatures,
  boot ids, page-operation counters and sync timings are libmdbx's own instrumentation and would
  be a maintenance burden to keep meaningful.
- **64-bit counts come across as `double`.** R has no 64-bit integer type; doubles are exact below
  2^53, which no realistic page count or database size approaches.
- **Build metadata is a real self-check.** `mdbx_version()$build$options` shows `ENV_CHECKPID=1` and
  `TXN_CHECKOWNER=1`, so a test can assert the compile-time safety flags are genuinely in effect
  rather than merely written in `Makevars` — which is the Stage 6 question asked early. Note
  `$build$datetime` arrives wrapped in literal quote characters; that is libmdbx's own value and is
  passed through verbatim.

---

## Stage 5.5 — Key listing (pulled forward from 0.2)

`mdbx_keys()` and `mdbx_items()`, added on request. Formally 0.2 scope, but "list the keys" is a
baseline expectation of a key-value store and the gap was conspicuous.

- [x] `mdbx_keys(txn, limit =, as =)` and `mdbx_items(txn, limit =, as =)`.
- [x] Cursor walked in C, one boundary crossing per call.
- [x] Tests: ordering, limits, raw and character forms, uncommitted writes, deletions, validation.

### What this turned up

- **It does not prejudge the deferred cursor API.** The open 0.2 question is what a *cursor object*
  should look like in R; these open, walk and close a cursor entirely inside the guarded call, so
  no cursor is ever visible to R and the question stays open.
- **The guarded call may not touch the R API**, so the scan cannot build R vectors as it goes. Bytes
  are collected into `std::string` (from pointer and length, so embedded NULs survive) and turned
  into raw vectors afterwards. The loop is additionally wrapped in `try/catch`: a C++ exception
  escaping the guarded function would unwind past `mdbx_r_run_guarded()` and leave the panic guard
  chain unrestored, so `bad_alloc` becomes a flag the caller raises instead.
- **`limit = 0` is not `limit = NULL`.** The first sentinel used a non-positive value for "no
  limit", which silently turned a request for zero records into a request for all of them. A test
  caught it; negative now means unlimited, and zero means zero.
- **Batching in C is worth about 2x here, not the 34x that transactions were.** Measured at 20,000
  records: `mdbx_items()` 0.093 s against 0.208 s for `mdbx_keys()` plus a per-key `mdbx_get()`
  loop. Per-call overhead is real but is not the dominant cost for reads, unlike the fsync per
  commit that made write batching so much more valuable.
- Keys are returned in **key order** (libmdbx's byte order), never insertion order.

---

## Stage 5.6 — Durability and environment flags

The last open design decision, answered as flag pass-through by name. See
*Durability options* in design.md for the full reasoning and the benchmark that sized it.

- [x] `flags =` on `mdbx_env_open()` and `mdbx_txn_begin()`, taking libmdbx's names without the
      `MDBX_` prefix.
- [x] `mdbx_flags()`, `mdbx_env_get_flags()`, `mdbx_env_set_flags()`, `mdbx_env_sync()`.
- [x] Vocabulary owned by `src/r_flags.cpp`, so bits come from the vendored header.
- [x] Tests: normalization, runtime changes, per-transaction flags, refusals, error messages.

### What this turned up

- **The knob matters far less than it looks.** `SAFE_NOSYNC` is 89x on 2000 single-write
  transactions but 1.1x on one transaction of 200000 writes — the cost is per *commit*, not per
  write, and transaction batching already recovers nearly all of it. The docs say so at every point
  the flags are described, rather than presenting them as a free speedup.
- **libmdbx normalizes the sync flags**, which upstream does not document. `SAFE_NOSYNC` reports
  `NOMETASYNC` too, `UTTERLY_NOSYNC` reports both, and clearing the stronger leaves the weaker set.
  Verified with a standalone C probe against the vendored amalgamation before it was documented.
- **`mdbx_env_get_flags()` returns an undocumented internal bit** (`0x02000000`) that matches no
  public flag. Reporting by table lookup rather than by decoding the whole word means it is ignored
  rather than surfaced as a mystery.
- **`MDBX_UTTERLY_NOSYNC` is a superset of `MDBX_SAFE_NOSYNC`**, so a naive bit report names one
  mode twice. Reporting checks the wider flag first and suppresses the narrower.
- **`mdbx_env_sync_ex()` returns `MDBX_RESULT_TRUE` (-1) on success**, meaning "nothing was
  pending". Passing that to `check()` would have turned a normal outcome into an error; it is the
  `FALSE` return of `mdbx_env_sync()` instead.
- **Flag changes are refused while a transaction is open.** libmdbx would answer `MDBX_BUSY`; the
  refusal names the transaction to end, and keeps the rule the rest of the package follows.

---

## Stage 6 — Process and thread safety

- [x] Confirm `MDBX_ENV_CHECKPID` / `MDBX_TXN_CHECKOWNER` actually fire, rather than assuming the
      compile flags are enough.
- [x] Test an environment inherited across `fork()` via `parallel::mclapply()` — the child must
      get a clean R error, not corruption.
- [x] Test separate-process readers and writer serialization.
- [x] Document the concurrency contract in the package docs, not just in design.md.

**Done when:** cross-process misuse is an error, and the behaviour is covered by tests rather
than by a claim.

### What this turned up

- **`MDBX_ENV_CHECKPID` was not enough, and the stage existed because of exactly this.** Before
  the fix, *every* operation on an environment inherited across `fork()` killed the child with
  "An irrecoverable exception occurred. R is aborting now" — `mdbx_env_stat()`, `mdbx_txn_begin()`
  either way, reads and writes alike. libmdbx's after-fork hook drowns the inherited environment,
  so CHECKPID only notices after a call has already dereferenced the dead mapping. The check has
  to happen *above* libmdbx.
- **The fix is the reference binding's:** `env_handle` and `txn_handle` record the process that
  created them, and `env_from_sexp()` / `txn_from_sexp()` refuse a handle reached from any other.
  `clibmdbx` does the same with `self->pid = current_pid()`, guarding its deallocator with it.
- **Finalizers needed the same guard, and it matters more than the entry points.** A forked child
  exiting would otherwise run `mdbx_env_close()` on the parent's environment, releasing a lock and
  reader slot it never held — silent damage rather than a crash. `close_handle()`, `detach_txns()`
  and `finalize_txn()` all check the pid now.
- **`mdbx_env_is_open()` returns `FALSE` in a child**, rather than erroring. It is the predicate
  `if (mdbx_env_is_open(env))` guards are written against, and an inherited environment is exactly
  as unusable there as a closed one.
- **`MDBX_TXN_CHECKOWNER` does fire**, proven rather than assumed: a `std::thread` test hook
  attempts `mdbx_txn_commit()` off the owning thread and gets `MDBX_THREAD_MISMATCH` (-30416). It
  is also the one result that does *not* end the transaction, so the owning thread commits it
  afterwards — which the test then does.
- **`flags = "TRY"` made writer serialization testable without a race.** A second process asking
  for the writer lock gets `MDBX_BUSY` immediately instead of blocking on a timeout, so the test
  is deterministic. Stage 5.6 paid for itself here.
- **Cross-process tests need a real subprocess, not a fork**, since an inherited environment is now
  refused by design. `helper-subprocess.R` spawns `Rscript` against the installed package, and
  skips when the package is only `load_all()`ed — an installed package has `Meta/package.rds` and a
  source directory does not, which is the discriminator. They run under `R CMD check` and CI.
- MVCC is confirmed end to end: a reader holds its snapshot while another process commits over it,
  and sees the new state only in a transaction begun afterwards.

---

## Stage 8 — Named databases (pulled into 0.1.0)

An environment can hold several independent key spaces; until now this package exposed only the
unnamed main one, so every key shared a single flat namespace. `max_dbs` was already an argument
with nothing to spend itself on.

- [x] `mdbx_dbi_open(txn, name, create =)` returning an `mdbx_dbi` object.
- [x] `db =` on `mdbx_get()`, `mdbx_put()`, `mdbx_del()`, `mdbx_keys()`, `mdbx_items()`, defaulting
      to the main database so existing code is unaffected.
- [x] `mdbx_dbi_drop(txn, db, delete =)`.
- [x] `mdbx_dbi_list(txn)`, via `mdbx_enumerate_tables()`.
- [x] Per-database statistics from `mdbx_env_stat(txn, db = )` via `mdbx_dbi_stat()`.
- [x] Tests: isolation between databases, the aborted-creation case, `MDBX_DBS_FULL`, and that a
      handle from one environment cannot be used in another.

**Done when:** the `clibmdbx` example in the design notes has a direct R equivalent, and no handle
can outlive its own validity.

### What this turned up

- **The design question answered itself once the semantics were measured.** A dbi from a
  transaction that aborts is poisoned, so no R object may hold one; but `mdbx_dbi_open()` is
  idempotent within a transaction, so re-resolving by name costs a lookup. The handle became a
  plain S3 record of a name — no external pointer, no finalizer, no `mdbx_dbi_close()`, and
  therefore none of the use-after-close hazard that made this an open question. See design.md.
- **Named databases appear as keys of the main database.** `mdbx_keys(txn)` on the main database
  lists them alongside real keys, because that is where libmdbx stores them. Pinned by a test so it
  is not later mistaken for a leak.
- **Handles carry the environment they were opened against.** Without that, using a handle from
  another environment would silently address a same-named database there rather than erroring —
  the one way name-based resolution could go wrong quietly.
- **`max_dbs` finally does something.** It had been an argument reserving capacity for a feature
  that did not exist; `max_dbs = 4` now yields `MDBX_DBS_FULL` on the fifth database, as tested.

- **`mdbx_env_stat()` without `db` counts the whole environment, not the main database.** Measured,
  because libmdbx does not document it either way: a main database of 4 keys plus a named database
  of 7 reports 11 entries. Invisible until Stage 8, since before it there was nothing else to
  count, and the existing tests would have passed under either reading. Now documented and pinned.
- **The enumeration callback is declared `noexcept`**, so an allocation failure inside it has to
  become a flag rather than an exception — the same shape the scan callback already needed, for the
  same reason.
- `mdbx_dbi_list()` reports what the *transaction* sees: a database created by a transaction that
  later aborts is listed inside it and gone afterwards, which the tests assert in both directions.

---

## Stage 7 — Release hardening

- [x] `R CMD check --as-cran` clean on all five CI legs, plus sanitizers, valgrind, LTO,
      gctorture and rchk. All green at `e80a18a`.
- [x] Run under ASan/UBSan and valgrind. Disable UBSan's alignment check — libmdbx deliberately
      uses unaligned x86 loads/stores. `.github/workflows/native-checks.yaml`.
- [x] Run `rchk` for protection errors — same workflow.
- [x] Interoperability spot-check: write with R, read with another MDBX implementation, and the
      reverse. `tools/interop-check.sh`.
- [x] Real `README.md` — done alongside Stage 4.
- [x] Package-level docs and `NEWS.md`.
- [x] Final licensing pass: upstream notices intact, `inst/COPYRIGHTS` accurate.

**Done when:** zero errors, warnings, and notes, and the vendored pin is reproducible from
`.agents/vendoring.md` alone.

### Native checks in CI

`.github/workflows/native-checks.yaml` runs sanitizers, valgrind, LTO, gctorture and rchk. Four of
the five call the reusable workflows in `pedrobtz/r-actions@v1` directly; sanitizers is a local copy,
for two reasons that the reusable workflow cannot express (it declares `workflow_call` with no
`inputs`):

- **UBSan alignment has to be off for the vendored code.** Confirmed rather than assumed: one site,
  `unaligned_poke_u32` at `mdbx.c:647`, a plain `*(uint32_t *)ptr = v` that libmdbx gates on its own
  compile-time `MDBX_UNALIGNED_OK`. `-fno-sanitize=alignment` goes in `CFLAGS` only — and
  `vendor/libmdbx/mdbx.c` is the only C file in the package, so that relaxes exactly the
  amalgamation and leaves all four first-party C++ sources fully checked. Verified locally: the flag
  lands on that file alone, and the suite then runs 372/372 with zero UBSan diagnostics.
- **`halt_on_error=1` in `UBSAN_OPTIONS`.** UBSan's default is to print and continue, so `R CMD
  check` would pass with sanitizer errors buried in the test log; ASan aborts by default and UBSan
  does not. Without this the leg cannot fail.

Both would fold back into a plain `uses:` if `r-actions/sanitizers.yml` gained `extra_cflags` and
`ubsan_options` inputs.

**gctorture is the slow leg.** The full suite under `gctorture2(step = 20)` takes about 13 minutes
on an M-series Mac; `r-actions/gctorture.yml` allows 60, and GitHub runners are perhaps 2-3x slower,
so it should fit without much margin. Worth watching rather than pre-optimising.

### What the first CI run turned up

Sanitizers, rchk and LTO passed first time. The other two did not, and both failures were worth
having:

- **gctorture: `The decor, tibble, vctrs package(s) are required`.** `testthat::test_local()` calls
  `pkgload::load_all()`, which re-runs `cpp11::cpp_register()` for a package with `src/` — and that
  needs cpp11's registration dependencies, which the reusable workflow does not install. Fixed
  without touching the workflow: `setup-r-dependencies` installs `Config/Needs/<needs>` from
  DESCRIPTION and the workflow already passes `needs: check`, so `Config/Needs/check` in DESCRIPTION
  is enough. It also failed at 3 minutes, so the 13-minute timeout worry above was misplaced — it
  never reached the suite.
- **valgrind: 31 errors, every one `mdbx_env_open()` returning EINVAL.** Not a bug in the package.
  libmdbx's default geometry reserves **~13 GB of address space per environment** — free in
  ordinary use, since it is virtual and almost none is resident, but valgrind shadows every mapping.
  A suite opening dozens of environments exhausts what valgrind can track and `mmap` starts
  failing; 282 tests passed before it gave out. The suite now pins `map_size` through a shared
  `helper-env.R`, which also removed five identical copies of `local_env()`. One test in
  `test-env.R` still exercises the default geometry, so that path stays covered.

The second point generalises beyond this repo's CI: **CRAN runs valgrind**, so a package whose test
suite cannot survive it is a submission problem regardless of whether we watch the leg ourselves.

**Both fixes are confirmed by a later run**, which also caught a third problem. gctorture reached
the suite and took 28m of its 60m budget, so the `Config/Needs/check` fix worked and the timeout
worry was unfounded. valgrind failed in 4m21s rather than grinding out 31 errors over 17m, so the
`map_size` pin worked too. What failed instead was a **page-size assumption in a test of mine**:
`test-limits.R` hardcoded a 4000-byte key as "under the limit at every page size", which holds on
macOS (16 KB pages, ceiling 8166) and not on Linux (4 KB pages, ceiling under 2000). It now derives
the key length from `mdbx_env_stat()$pagesize`; a quarter of a page has two-fold headroom, verified
by checking that half a page is refused.

The irony is on the record two paragraphs above, where this stage's notes say tests "assert `>=`
and 'some size that is definitely too large' rather than constants that would break on a 4 KB
page". Writing that down did not stop the constant going in. A local suite that only ever runs on
one page size cannot catch this class; CI on a second platform is what did.

**`mdbx_limits()` was built as the answer to it**, being the cheapest item on the feature list and
the one that removes the whole class of bug. libmdbx computes these itself, so the tests stopped
guessing: the large-key test now writes a key of exactly `mdbx_limits(env)$keysize_max`, and the
oversized-key test uses that plus one instead of a number picked to be safely huge. The published
figures make the portability trap explicit -- 2022 bytes at a 4 KB page, 8166 at 16 KB, 32742 at
64 KB -- and a test asserts the first two, so the difference is now a fact the suite states rather
than one CI discovers.

### Narrowing casts, and the limit of sanitizer coverage

An external review of the native layer found three double-to-integer casts fed unchecked values —
`max_dbs` and `map_size` in `mdbx_env_open_()`, and `limit` in `mdbx_scan_()`. All three reproduce
under UBSan from ordinary calls (`mdbx_env_open(path, max_dbs = 1e20)`, `mdbx_keys(txn, limit =
1e20)`): one extra zero is enough. Out-of-range double-to-integer conversion is undefined
behaviour, so the outcome is whatever the compiler picks.

The subtlest of the three was the *existing* guard: `map_size > (double) PTRDIFF_MAX` looks correct
but is not, because `PTRDIFF_MAX` (2^63 - 1) has no exact double representation and rounds **up**
to 2^63 — so the comparison admits exactly 2^63 into a cast that tops out at 2^63 - 1. Everything
is now bounded at 2^53, the largest integer a double holds exactly, which sidesteps the rounding
question entirely and is far below every destination type's range.

**The lesson worth keeping is why CI missed it.** The sanitizers leg was green throughout: UBSan is
a runtime tool and only sees code the tests execute, and no test had ever passed an out-of-range
number. A green sanitizer run means "no UB on the paths the suite covers", not "no UB". The fix
therefore includes tests at those boundaries — without them the leg would stay blind to a
regression here.

### Closing out the review, and what wider tests then found

`max_readers`, `mode` and `mdbx_env_reader_check()` are all implemented. Chasing coverage
afterwards turned up a defect none of the review's three findings covered:

- **`mdbx_txn_commit()` reported `MDBX_RESULT_TRUE` as "error -1".** `mdbx_txn_commit_ex()`
  documents that result as "transaction was aborted since it should be aborted due to previous
  errors" -- a real failure for the caller, but a *result* rather than an error code, so
  `mdbx_strerror()` renders it as the meaningless `error -1 (mdbx error -1)`. The same trap as
  `mdbx_env_sync_ex()`, which was handled, and `mdbx_reader_check()`, which is handled now. It
  raises a sentence in English instead.
- **Two failure modes inside a transaction, not one.** An oversized key (`MDBX_BAD_VALSIZE`) fails
  that one operation and the transaction carries on -- writes either side of it still commit. A
  value that exhausts the map (`MDBX_MAP_FULL`) instead marks the transaction unusable: every later
  operation fails with `MDBX_BAD_TXN` and the commit rolls the whole thing back. Both are now
  tested and the distinction is documented on `?mdbx_txn_commit`.
- **Measured limits, so tests do not hardcode them:** the key ceiling is derived from the page size
  (8166 bytes at 16 KB), and `max_readers = 1000` yields 1004 because libmdbx rounds up to fill the
  lock page. Tests assert `>=` and "some size that is definitely too large" rather than constants
  that would break on a 4 KB page.

Coverage of `R/` is now 100% on every file except `.onLoad`, which runs before covr can instrument
it; its effect is asserted separately in `test-native-safety.R`. The suite is 420 assertions under
UBSan with `halt_on_error=1`, clean.

### Four lifecycle and contract defects, from a second review

All four reproduced before being fixed, and all four now have regression tests.

- **`create = FALSE` created a database anyway, in any existing empty directory.** The guard used
  `file.exists(path)`, which is true of a bare directory; libmdbx then detects the directory layout
  and creates `mdbx.dat`/`mdbx.lck` inside it. An environment now counts as existing only if
  `mdbx.dat` is there (`env_exists()` in `R/env.R`).
- **`mdbx_env_stat(env)` failed outright while this thread held a *read* transaction**, with
  `MDBX_BAD_RSLOT`: given a null transaction libmdbx opens an internal read transaction, which
  collides with the caller's. The environment form now reuses the live transaction. This also
  corrects documentation written at Stage 5 that claimed the two forms agree -- it had only ever
  been checked with a *write* transaction, where it happened to be true.
- **A directory environment reopened with the default `subdir = FALSE` printed as "single file".**
  The attribute recorded the argument, not the layout libmdbx detected. It is now read back from
  `mdbx_env_get_flags()` after the open.
- **A finished transaction kept its environment alive**, pinning the memory map and file
  descriptors for as long as the caller held the object. `finish_txn()` now clears the external
  pointer's protected field. That change is only safe alongside nulling `txn_handle::owner` in
  `mark_finished()`: `unregister_txn()` dereferences `owner` from `finalize_txn()`, and the
  protected field was the only thing that had been keeping it from dangling.

### Superseded review findings

- **No way to raise the reader-slot ceiling.** Nothing calls `mdbx_env_set_maxreaders()` or sets
  `MDBX_opt_max_readers`, so it cannot be tuned; `clibmdbx` takes it as a constructor argument.
  Note the review's severity estimate was wrong: it cited `DEFAULT_READERS 61`, but that is only
  the pre-open placeholder at mdbx.c:7523. Line 27427 recomputes the ceiling as
  `(lck_file_size - sizeof(lck_t)) / sizeof(reader_slot_t)`, capped at `MDBX_READERS_LIMIT`
  (32767) — measured at **492** here with a 16 KB page, and page-size dependent, so roughly a
  quarter of that on a 4 KB Linux page. 492 concurrent reader processes is not a limit R workloads
  will meet by accident. The more practical gap is `mdbx_reader_check()`, which reclaims slots left
  by crashed processes and is also unexposed.
- **File mode is hardcoded** to 0664 at mdbx.c's `mdbx_env_open()` call site, so with the usual
  umask 022 a database lands 0644 — world-readable, with no way to ask for 0600. `clibmdbx` takes
  `mode` as an argument. Verified by measurement.

Both are now fixed: `mdbx_env_open(max_readers =, mode =)` and `mdbx_env_reader_check()`. `mode`
takes octal digits as a string or an `octmode`, refusing a bare number since `600` is not `0600`.

### Interoperability

`tools/interop-check.sh` writes a database with this package and reads it with `clibmdbx` — the
Python binding the design follows, carrying its own vendored libmdbx built by a different compiler
with different flags — then does the reverse. A maintainer script like `tools/update-libmdbx.sh`,
run at a version bump, not part of `R CMD check`.

Result at libmdbx v0.14.3 / clibmdbx 1.0.3: **byte-identical in both directions**, across 15 records
chosen to be awkward — multibyte UTF-8 keys and values, a key with an embedded NUL, an empty value,
a 100 KB value, and keys inserted in the reverse of their sort order. Key order is byte order on
both sides and the two agree. Both negative controls (corrupt one expected value in each direction)
fail with exit status 1, so the check is not vacuous.

Two things it does *not* establish, worth stating so the next person does not over-read it:

- **It is not a cross-version format check.** Both sides vendor libmdbx 0.14.3, so this proves the
  two builds agree, not that the on-disk format is stable across releases. Testing that would mean
  building the upstream `mdbx_dump`/`mdbx_load` tools from a *different* release and round-tripping
  through them; worth doing the next time the pin moves rather than now, when there is nothing to
  compare against.
- **The `subdir` defaults differ between bindings.** This package defaults to `subdir = FALSE` (the
  path is the data file); `clibmdbx` defaults to `subdir=True`. A database written by one is opened
  by the other only if the layout is stated explicitly. Not a bug in either, but the first thing to
  check when a cross-binding open fails with ENOENT.

### Licensing

Checked against *Writing R Extensions* §1.1.1-1.1.2 and the upstream notices, not from memory. Four
things were wrong, none of which `R CMD check` can detect -- they are the sort a CRAN reviewer
catches by reading:

- **`Authors@R` named only the R author.** WRE is explicit: "if you wrote an R wrapper for the work
  of others included in the `src` directory, you are not the sole (and maybe not even the main)
  author". It now carries `cph` entries for Leonid Yuriev (libmdbx), Howard Chu and Symas Corp.
  (LMDB), and Martin Hedenfalk (btree.c) — four copyright holders besides the maintainer.
- **`inst/COPYRIGHTS` credited Oracle, which holds no copyright in this code.** "Oracle" appears
  nowhere in the vendored tree. It also dated Howard Chu's copyright to 2015 where upstream says
  2011-2015, and omitted Martin Hedenfalk (2009, 2010) entirely. Corrected against
  `src/vendor/libmdbx/COPYRIGHT`, which is the authority.
- **The ancestry is not all Apache-2.0.** libmdbx is distributed under Apache-2.0, but the
  LMDB-derived code came under the OpenLDAP Public License and Hedenfalk's btree.c under an
  ISC-style licence. `inst/COPYRIGHTS` said only `SPDX-License-Identifier: Apache-2.0`; it now
  summarises the chain and points at the full texts.
- **Three different copyright holders were named** across `LICENSE` ("Pedro Z"), `LICENSE.md`
  ("mdbx authors") and `DESCRIPTION` ("Pedro Baltazar"). All now say Pedro Baltazar. `inst/COPYRIGHTS`
  also referenced `LICENSE.md`, which is `.Rbuildignore`d and therefore absent from the tarball.

Added `Copyright: file inst/COPYRIGHTS` to DESCRIPTION, which WRE names as the convention when the
copyright holders are not the authors. `License: MIT + file LICENSE` is kept and is still canonical:
the MIT terms cover this package's own code, and Apache-2.0 §4 is satisfied for the vendored code by
retaining LICENSE, NOTICE and COPYRIGHT and by declaring them in `inst/COPYRIGHTS`, which spells
out each change rather than deferring to the patch series.

**The pin was re-verified against upstream** rather than trusted: `git ls-remote` gives tag object
`cf3e1393` and commit `f7a3a932` for v0.14.3, both matching `.agents/vendoring.md`. The third
identifier there, `v0.14.3-0-g251562b2`, is the amalgamation string upstream bakes into the sources
and is not the tag commit — worth knowing before mistaking it for a mismatch.

---

## Stage 9 (proposed) — what a diskcache-style package needs

Scope driven by an intended downstream: an R equivalent of Python's `diskcache`, backed by mdbx
instead of SQLite. Derived from `diskcache/core.py`'s actual SQL rather than its prose, since what
matters is the *access patterns* the store has to support — and on the explicit basis that matching
SQLite's full power is a non-goal.

### What diskcache asks of its store

Its ordered access is `ORDER BY expire_time LIMIT ?`, `ORDER BY rowid LIMIT ?`,
`ORDER BY key ... LIMIT 1`, a `key BETWEEN ? AND ?` range, a resume-from-position
(`key = ? AND raw > ? OR key > ?`), and a batch delete (`rowid IN (...)`). Its three eviction
policies — least-recently-stored, -used, -frequently-used — are each an ordered secondary index
walked from one end.

### Most of it already works

`add()` is `mdbx_put(overwrite = FALSE)`; `pop()` and `incr()`/`decr()` are a get and a put inside
one `mdbx_with_write()`; `__len__` is `mdbx_env_stat()$entries`; `volume()` is
`mdbx_env_info()$file_size`; `transact()` is the `with_*` helpers; trading durability for speed is
`flags`. Named databases (Stage 8) are what make the design possible at all — one for values, one
for the expiry index, one per eviction index, one for tags.

**And crucially, `ORDER BY <index> LIMIT n` needs nothing new.** Measured: with keys encoded
big-endian so byte order matches numeric order, `mdbx_items(limit = 3)` on an expiry index returns
exactly the three soonest to expire, because libmdbx iterates in key order from the start. Expiry
culling and all three eviction policies are therefore already expressible. This is the finding that
shrank the stage: the first proposal here assumed range scans were a blocker, and they are not.

### What was actually missing, and is now in

- [x] **`reverse`** on `mdbx_keys()`/`mdbx_items()`. Without it the largest key costs reading every
      key, so `peekitem(last = TRUE)` and a Deque's right-hand end were O(n).
- [x] **`start`** on the same. Seeks to the first key at or after it going forwards, or the last at
      or before it going backwards — so iteration resumes in chunks instead of materialising a
      whole cache. The backward case has to step back when the seek overshoots, which is tested in
      both directions and past both ends.
- [x] **`mdbx_dbi_sequence()`.** diskcache's `rowid` is a monotonically increasing store order,
      which is exactly a database sequence. Reserving returns the value *before* the increment, so
      two transactions can never be handed the same number, and an increment rolls back with its
      transaction.
- [x] **`keys_as` on `mdbx_items()`.** Found while measuring the above rather than by reading the
      SQL: an index has *binary* keys (an encoded timestamp) and *text* values, but a single `as`
      governed both, forcing the whole thing to be read raw and decoded in R.

**Byte order is the only order there is.** Timestamps and counters have to be encoded big-endian
and fixed-width or an index does not sort, and every ordered scan above is then meaningless. That
is inherent to libmdbx rather than something this package can paper over, and the tests say so at
the point where they build an index.

### The design, written down

`vignettes/articles/cache.Rmd` is a draft design plus a working simplified implementation, built
against the real diskcache schema (one table, six indexes) and the polars-diskcache pattern of
keeping the payload in a file and the pointer in the store. It runs in the pkgdown build, so the
design cannot rot silently.

What the mapping turned out to be: a table plus `CREATE INDEX` becomes **one named database per
index, keyed by the thing being sorted on** — `expiry` keyed `<8-byte time><key>`, `accessed`
likewise. The timestamp is in the key because `ORDER BY` has nowhere else to live, and the record's
key is appended because index entries must be unique and because expiry then needs no second lookup
to learn what to delete. `rowid` is `mdbx_dbi_sequence()`.

Most of SQLite goes unused: no schema, no planner, no SQL, no joins. What is genuinely harder is
that **every ordering decision moves into the key encoding**. SQLite knows `expire_time` is a
number; libmdbx knows only bytes. Big-endian IEEE-754 doubles sort correctly by byte order for
non-negative values — verified — and `Inf` lands after every real deadline, so "never expires"
needs no special case. Get that encoding wrong and every ordered scan returns nonsense quietly.

### Deferred to 0.2, and why none of it blocks the cache

| Deferred | Why it is not needed |
| --- | --- |
| **Cursor objects** | Every ordered access diskcache makes is `limit`, `start` or `reverse`, all of which the existing single-crossing scan already does. A cursor object would add an external-pointer type whose lifetime is bound to its transaction — the env-to-txn ownership problem again, one level down — for no capability the cache uses. |
| **A `stop` bound** | Emulated by fetching a chunk and checking where it ran past the mark. Culling is chunked anyway. |
| **Batch operations** | `WHERE rowid IN (...)` becomes a loop of `mdbx_del()` inside one transaction, so only per-call overhead is at stake. Measured earlier: scan batching was worth about 2x, against the 34x that transaction batching was worth — and the transaction is already shared. |
| **DUPSORT** | A tag index is composite `tag\0key` keys plus a prefix scan, which `start` now provides. |
| **`env.copy()`, `replace`, `rename`, options, geometry** | Useful, none of them load-bearing for a cache. |

The general principle: 0.1.0 ships what the downstream cannot be built without, and defers what
would only make it faster or tidier. Each deferred item is additive — none of them would change an
API that ships now.

---

## Feature gap against `clibmdbx`

Produced by a mechanical comparison of `clibmdbx`'s type stub (`src/clibmdbx/__init__.pyi`,
70 methods) against this package's exports at `2f2f846` (26). Nothing here is committed to a
release; the point is that the list exists in one place, so scope decisions are made rather than
made by omission.

### Data model and iteration

| Feature | `clibmdbx` | Notes |
|---|---|---|
| **Cursors** | the whole `Cursor` class, 18 methods | The largest single gap. Already deferred to 0.2; `mdbx_keys()`/`mdbx_items()` were written not to prejudge its shape. |
| **Range and prefix scans** | `cursor.items(start=, stop=)` | Comes with cursors. Until then, reading one key prefix costs a full scan and an R-side filter — the practical cost of having no cursor. |
| **`MDBX_DUPSORT`, and database flags generally** | `open_db(flags=)`, plus `get_both`, `next_dup`, `prev_nodup`, `count` | **Untracked until now.** `mdbx_dbi_open()` passes only `MDBX_CREATE` or defaults, so multiple values per key — and `MDBX_INTEGERKEY`, `MDBX_REVERSEKEY`, `MDBX_DUPFIXED` — are unreachable. This is a whole libmdbx data model, and it was never considered rather than deliberately cut. Of everything in this table it is the one most worth an explicit decision. |

### Performance

| Feature | `clibmdbx` | Notes |
|---|---|---|
| **Batch operations** | `get_many`, `put_many`, `delete_many` | Deferred to 0.2. Worth noting the irony: looping in C rather than around `.Call()` is recorded in CLAUDE.md as "the main performance lesson recorded from the reference bindings", and the lesson is written down while the feature is not built. |
| Read-transaction reuse | `txn.reset()`, `txn.renew()` | Lets a reader release its snapshot and take a new one without giving up and re-acquiring a reader slot. |

### Environment management

| Feature | `clibmdbx` | Notes |
|---|---|---|
| **Hot backup** | `env.copy(path, flags)` | Copies a live environment, optionally compacting. design.md mentions "database copy/backup operations" once, in a list, and nothing tracks it. Small to build and the kind of thing an embedded store is expected to have. |
| Map resizing | `env.set_geometry()` | Already an open question ("Map resizing policy"). Only `map_size`, the upper bound, is exposed. |
| Options | `env.get_option()`, `env.set_option()` | Would subsume the deferred auto-sync thresholds (`MDBX_opt_sync_bytes`, `MDBX_opt_sync_period`). |
| Removing an environment | `delete_environment(path)` | Deletes data and lock files together, which `unlink()` does not do safely. |
| ~~Reported limits~~ | `limits()` | **Done** — see below. |

### Database operations

| Feature | `clibmdbx` | Notes |
|---|---|---|
| Atomic replace | `txn.replace()` | Get-and-set in one operation, returning the previous value. |
| Per-database counter | `db.sequence()` | An atomic counter attached to a database; the usual way to mint ids. |
| Rename | `db.rename()` | |
| Database flags | `db.flags()` | Reports how a database was created — needed once `open_db(flags=)` exists. |

### Transactions

| Feature | `clibmdbx` | Notes |
|---|---|---|
| Nested transactions | `env.begin(parent=)` | Explicitly out of scope for 0.1.0 in design.md; libmdbx supports them. |
| Commit latencies | `txn.commit_ex()` | Returns timing for each commit stage. Diagnostic. |
| Transaction introspection | `txn.id`, `txn.flags`, `txn.info()` | |
| Long-read handling | `txn.park()`, `txn.unpark()`, `txn.break_()`, `txn.refresh()` | For readers held long enough to hold back page reuse. |

### Ergonomics

| Feature | `clibmdbx` | Notes |
|---|---|---|
| **Environment-level `get`** | `env.get(key, db=, default=)` | **Reopened.** Declined after Stage 4 because it hides the transaction and cannot compose with one already open; a one-off read still has to spell out `mdbx_with_read()`. To be decided alongside the rest rather than left as a closed question. |
| Indexing sugar | `txn[key]`, `key in txn` | R equivalents would be `[` and `%in%` methods on `mdbx_txn`. |

### Diagnostics and tuning

`env.defrag()`, `env.warmup()`, `txn.canary()`, `txn.gc_info()`,
`env.orphaned_write_transactions`, `env.reap_orphaned_transactions()`, `diagnostics()`,
`readahead_reasonable()`. Niche, and none of them blocks ordinary use.

### Ranked by implementation cost

Estimated against this codebase rather than in the abstract: what matters is how much of the
existing machinery a feature can reuse. Every API named here was confirmed present in the vendored
`mdbx.h`.

**Tier 1 — an afternoon each, no new concepts.** One guarded context, one entry point, an R
wrapper, tests. Each follows a pattern already in the tree.

| Feature | Why it is cheap |
|---|---|
| ~~`limits()`~~ | **Done.** `mdbx_limits()`, taking an environment, a transaction, a page size, or nothing. Pure computation, so no panic guard — an unusable page size is reported as -1 rather than asserted. |
| `delete_environment(path)` | `mdbx_env_delete()` takes a path, not a handle. |
| `db.sequence()` | One context over `ensure_dbi()`. |
| `db.rename()` | The same, plus cache invalidation — `mdbx_dbi_drop_()` already shows the shape. |
| `db.flags()` | One context plus a name table; `src/r_flags.cpp` is the template. |
| `txn.id`, `txn.info()` | Struct to named list; `info_list()` is the template. |
| `env.copy()` | One context. Slow to run, trivial to write. |

**Tier 2 — about a day each.** Mechanical, but larger or gated on a decision.

- `get_option()` / `set_option()` — 52 enum members. Vocabulary work in the `r_flags.cpp` shape, but
  a lot of it, each with its own units and validation. Subsumes the deferred sync thresholds.
- `txn.replace()` — raw in *and* raw out.
- **Database flags on `mdbx_dbi_open()`** (`INTEGERKEY`, `REVERSEKEY`) — argument threading plus
  vocabulary. A prerequisite for DUPSORT.
- `env.set_geometry()`, `env.get(key)`, `[` / `%in%` sugar — the code is trivial in all three; the
  cost is the open design decision, not the implementation.

**Tier 3 — several days.**

- **Batch operations.** `mdbx_scan_()` proves the shape, but inputs have to be marshalled out of R
  *before* the guarded frame and results built after, across three functions with three shapes.
- **`txn.reset()` / `txn.renew()`.** A tiny API needing disproportionate care: it adds a fourth
  transaction state to `txn_from_sexp()`, the live-transaction registry and the finalizers — which
  is exactly where this package's defects have concentrated.

**Tier 4 — the large ones.**

- **Cursors.** 33 C functions, and a new external-pointer type whose lifetime is bound to its
  transaction: a registry on `txn_handle`, invalidation when the transaction ends, finalizer
  ordering. It is the env-to-txn ownership problem solved once already, to be solved again one
  level down. Range and prefix scans fall out of it for free.
- **DUPSORT.** The largest, and the only item that changes *existing* semantics rather than adding
  surface. Does `mdbx_get()` return one value or several? How does `mdbx_items()` represent a
  repeated key? `mdbx_del()` already deletes every value for a key — `del_call()` says so in a
  comment. It is also unusable without `get_both`/`next_dup`/`count`, so it depends on cursors and
  on Tier 2's database flags.
- **Nested transactions.** A modest API with the worst risk-to-value ratio here: it breaks the
  one-transaction-per-environment invariant that `mdbx_env_close()`'s refusal,
  `mdbx_txn_begin()`'s refusal and the live-transaction registry are all built on.

**Dependencies, which constrain any ordering:** DUPSORT needs cursors *and* database flags; range
and prefix scans need cursors; `get_option`/`set_option` absorbs the deferred auto-sync thresholds.

**Value per unit effort, which is not the same ordering.** `limits()`, `env.copy()` and
`db.sequence()` are Tier 1 features people reach for. Batch operations are the best return in the
table — Tier 3 effort for the performance lesson CLAUDE.md already records as the most important
one taken from the reference bindings, and currently the one gap between writing that lesson down
and acting on it.

### Deliberately not ours

`Database.close()` is absent by design, not by omission: never closing a DBI handle is precisely
what makes the Stage 8 handle representation safe (see design.md). `env.close(dont_sync=)` is
likewise skipped — upstream's own documentation calls it a footgun rather than a latency
optimisation.

---

## Open questions, and where they get answered

| Question | Status |
|---|---|
| R object model | **Settled, Stage 2** — external pointer + S3, class and attributes attached natively |
| On-disk layout | **Settled, Stage 2** — `subdir = FALSE` default, so the path is the data file |
| Missing-key semantics | **Settled, Stage 4** — `NULL`, with a `default` argument |
| Character-key encoding | **Settled, Stage 4** — raw, or a single string stored as UTF-8 bytes |
| Value decoding on read | **Settled after Stage 4** — `as = c("character", "raw")`, decoding by default |
| Exported naming | **Settled after Stage 4** — mirrors the C API (`mdbx_env_*`, `mdbx_txn_*`, `mdbx_del`) |
| Method syntax (`txn$get()`) | **Declined** — sugar duplicating every function; see design.md |
| Environment-level data ops (`mdbx_get(env, key)`) | **Reopened** — declined after Stage 4 (hides the transaction, cannot compose with one already open); back on the list under *Feature gap* below, to be decided with the rest |
| Durability / environment flags | **Settled, Stage 5.6** — flag pass-through by name (`flags = c("SAFE_NOSYNC", ...)`), following `clibmdbx`; a curated `durability =` enum was rejected. Durable by default. |
| Auto-sync thresholds (`opt_sync_bytes`/`opt_sync_period`) | deferred to 0.2 — `mdbx_env_sync()` covers the manual case |
| Serialization ownership | deferred to 0.2 |
| Cursor API shape | deferred to 0.2 — `mdbx_keys()`/`mdbx_items()` deliberately do not prejudge it |
| Named database handle representation | **Settled, Stage 8** — a lightweight R object holding the name; the `MDBX_dbi` is resolved per transaction, never cached across one, and never closed. See design.md. |
| Map resizing policy | deferred to 0.2 — only `map_size` (the geometry upper bound) is exposed |

## Risks

- **Windows build** is the likeliest failure and the hardest to debug remotely. Stage 1 exists to
  surface it while the package is still one function.
- **Symbol leakage** on Windows if `-D__dll_export=` does not take effect. Verify, do not assume.
- **Tarball size** from the amalgamation against CRAN's 5 MB guidance.
- **Fork semantics** may differ across platforms; treat Stage 6 findings as design input, not
  just test results.

## Post-stage-9 review pass

An external review of the package raised eight findings. All were reproduced before being
acted on; the ranking below is by what a user actually hits, not by the review's own severity
labels.

- [x] **Documentation drift.** `README.md` and `?mdbx_env_open` both still said named databases
  were unimplemented, four stages after they shipped. `?mdbx_env_get_flags` claimed
  `UTTERLY_NOSYNC` also reports `SAFE_NOSYNC`; the code deliberately suppresses it and the test
  asserts the suppression, so only the prose was wrong.
- [x] **`mdbx_limits()` cast undefined behaviour.** `mdbx_limits(Inf)` reached
  `static_cast<intptr_t>` unchecked. Fixed in R and again beside the cast. The same pass added
  `max_native_integer()`: the existing 2^53 guards do not protect an `intptr_t` or a `size_t` on
  a 32-bit build, where both stop at 2^31 - 1.
- [x] **`start` bypassed the unbounded-scan guard.** The rationale in the code — "a scan with a
  start is bounded by construction" — is false: a start key positions the cursor and bounds one
  end only. `mdbx_keys(txn, start = raw(0))` returned an entire database with the guard mocked to
  1. The guard now applies whenever `limit` is `NULL`, and counts the database actually being
  scanned rather than always the main one.
- [x] **Fractional arguments truncated silently.** `limit = 1.9` returned one record,
  `increment = 0.5` did nothing, `mdbx_limits(4096.5)` answered for 4096. All refused now.
- [x] **Sequences lost uniqueness above 2^53.** The counter is `uint64_t` natively but reaches R
  as a double, so two successive `increment = 1` calls past 2^53 both returned 9007199254740992.
  It now reads first, refuses if the reservation would cross 2^53, and leaves the counter
  untouched when it refuses. `MDBX_RESULT_TRUE` — libmdbx's own overflow status, and the only one
  of its four uses that was unhandled — no longer surfaces as "mdbx error -1".
- [x] **`mdbx_env_stat()`/`mdbx_env_info()` did not poison on panic.** Two of twenty-two guard
  sites passed a null poison callback, so an assertion there became an R error while leaving the
  handle usable and its finalizer free to re-enter libmdbx. `mdbx_test_panic_stat_()` injects a
  panic through the real contexts and callbacks.
- [x] **Handles were authenticated by class alone.** Both handle types are `EXTPTRSXP`, so
  `class(txn) <- "mdbx_env"` was enough to have a `txn_handle` dereferenced as an `env_handle`.
  Every handle now carries a private external-pointer tag, which R has no way to set. Writing the
  test found a second instance: `mdbx_env_close_()` and `mdbx_env_is_open_()` did their own shape
  check rather than going through `env_from_sexp()`, and read a garbage transaction count from a
  forged pointer. Both now share `is_env_sexp()`.
- [x] **`max_dbs` defaulted to none.** libmdbx reserves no dbi slots by default, so
  `mdbx_dbi_open()` failed with `MDBX_DBS_FULL` on an environment opened with default arguments.
  The default is now 16; `NULL` still opts out.
- [x] `cran-comments.md` written, and `create = FALSE` documented as the best-effort check it is
  — libmdbx has no "open but never create" flag, so the test and the open cannot be one step.
- [x] The cache article deleted blob files inside the write transaction, so a rollback left
  metadata pointing at a file that was gone. Called out explicitly: orphans are recoverable,
  dangling references are not.

### Declined

- `mode = "0600"` as the default. `0664` is libmdbx's own and parity is worth more than a guess
  about sensitivity; the argument exists for anyone who wants otherwise.
- `as = "raw"` as `mdbx_get()`'s default. A breaking change, and the text default is what keeps
  the examples readable.
- Interrupt checks inside the scan loop. Real, but the loop runs below the panic boundary where
  `R_CheckUserInterrupt()` cannot longjmp from; it needs chunking across the guard. Deferred.
- The review's branch-policy point. Push CI watches `main`/`master` and the work is on `develop`,
  but pull-request runs cover it and PR #1 is open.

### The website, settled

`_pkgdown.yml` carries `development: mode: auto`, which reads the version number: a three-component
version with the third at 9000 or above builds to `/dev/`, anything else to the site root. The
pkgdown workflow deploys from `main` and `develop`, and its `clean: false` is what lets the two
sites coexist on `gh-pages` rather than overwrite each other. `dev_mode_auto()` is the authority —
note that a *four*-component `0.0.0.9000` resolves to `unreleased`, which builds to the root, not
to `/dev/`.

`DESCRIPTION` lists the site in `URL:` only now that it resolves. That field is what CRAN's
incoming check reads, and it was deliberately left out while the site was a 404.

**`devtools::check()` does not check URLs.** It reported 0/0/0 with three dead links in
`DESCRIPTION` and `README.md`; `urlchecker::url_check(".")` found all three. Use it before any
submission.

## Reference links

Upstream:

- <https://libmdbx.dqdkfa.ru/doxygen/group__c__api.html> — the C API reference
- <https://github.com/erthink/libmdbx> — upstream repository (see [vendoring.md](vendoring.md)
  for the pinned tag and digests)
- <https://github.com/Mithril-mine/libmdbx> — mirror

`jyj117/mdbx-py` (`clibmdbx`), the binding this package's design follows:

- <https://github.com/jyj117/mdbx-py>
- <https://github.com/jyj117/mdbx-py/blob/main/VENDORING.md> — the model for
  [vendoring.md](vendoring.md)
- <https://github.com/jyj117/mdbx-py/blob/main/docs/API.md>
- <https://github.com/jyj117/mdbx-py/blob/main/docs/API_COVERAGE.md> — the basis for the feature
  gap recorded above
- <https://github.com/jyj117/mdbx-py/blob/main/docs/BUILDING.md>

`wtdcode/mdbx-py`, the architecture explicitly rejected — submodule plus CMake producing a
standalone library loaded by `ctypes`, neither half of which survives `R CMD build`:

- <https://github.com/wtdcode/mdbx-py>
- <https://github.com/wtdcode/mdbx-py/blob/master/mdbx/mdbx.py>

Other bindings, unexamined:

- <https://github.com/ikonopistsev/mdbxmou> — C++
