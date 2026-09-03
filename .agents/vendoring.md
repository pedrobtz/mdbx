# Vendored libmdbx

`src/vendor/libmdbx/` holds an unmodified copy of the libmdbx amalgamated source. It is compiled
directly into this package's shared object; there is no submodule, no CMake step, and no system
libmdbx involvement.

## Current pin

| | |
|---|---|
| Release | **v0.14.3** (stable, published 2026-08-09) |
| Tag object | `cf3e13938bf974260872e629713f6ecf30e62030` |
| Commit | `f7a3a9323cacacfa9dc6137ae7a7252a67744ff0` |
| Amalgamation | `v0.14.3-0-g251562b2` |
| Upstream | <https://github.com/erthink/libmdbx> at tag `v0.14.3` |

v0.14.3 is the release at which upstream declared the 0.14.x branch stable and bug-fix-only;
further development moved to 0.15.x.

### SHA-256 of vendored files

```
52d061dc77b1485da1ab7d9df336c750d021e3b1c7267db437bb6100cb3b001c  mdbx.c
1feb06b7f6f65ab3ad16df51cffbea977331d7426e6d72bdc07f4feac5a9cbb6  mdbx.h
f293f0e99eb77eebe7f7f4cfa76686e32b4a5fe09445e26b9531714e4d2ec854  mdbx-internals.h
0d542e0c8804e39aa7f37eb00da5a762149dc682d7829451287e11b938e94594  LICENSE
21f302c17332bb2481b210a0f80e0540e77701d8a9bb40a76a6cb1265f73ad13  NOTICE
e53a73bbd1f4862f53fb6f37c4d987b1d12a1886d22022a8bafc1a7a0471dbb6  COPYRIGHT
```

The `mdbx.c` and `mdbx.h` digests were confirmed against the values independently recorded by
`jyj117/mdbx-py`, as were the tag object and the amalgamation commit.

## Where the amalgamation comes from

**There is no separate amalgamation archive to download any more.** Since the end of 2025 libmdbx
is distributed *only* in amalgamated form, so the repository tree at a release tag already is the
amalgamation — `mdbx.c` opens with `This file is part of the libmdbx amalgamated source code`, and
`make dist` now merely prints a notice saying amalgamation is no longer required. GitHub releases
carry no assets, and the URLs under `libmdbx.dqdkfa.ru/release/` 404.

**The amalgamation is three files, not two:** `mdbx.c` includes `mdbx-internals.h`, so vendoring
only `mdbx.c` and `mdbx.h` will not compile.

## Update procedure

1. Confirm the candidate is a stable release — not `master`, not an RC, not a development
   snapshot. Check upstream's release notes for the branch's status.
2. Clone at the tag and record `git rev-parse <tag>` (tag object) and `git rev-parse <tag>^{commit}`.
3. Run `tools/update-libmdbx.sh <version>`, which vendors the six files and replays the patch
   series. Never hand-edit the vendored sources — change a patch instead.
4. Record fresh SHA-256 digests here.
5. Update the expected version in `tests/testthat/test-version.R`.
6. Rebuild and re-run the suite on all CI platforms.
7. Review upstream's changelog for changes to the on-disk format, durability semantics,
   environment/transaction options, and the C API.

## Build flags, and why each exists

Set in `src/Makevars` and `src/Makevars.win`:

- `-Ivendor/libmdbx` — the vendored headers.
- `-D__dll_export=` — `LIBMDBX_VERINFO_API` is unconditionally `__dll_export` unless
  `LIBMDBX_IMPORTS` is set, which would export `mdbx_version`/`mdbx_build` from the package's own
  shared object. Emptying the macro suppresses that. Note that `LIBMDBX_API` itself is already
  empty because *neither* `LIBMDBX_EXPORTS` nor `LIBMDBX_IMPORTS` is defined — which is exactly
  what a static build wants, so neither must ever be added.
- `-DMDBX_BUILD_FLAGS='"R-CMD-SHLIB"'` — without either this or `MDBX_BUILD_FLAGS_CONFIG`,
  `mdbx.c` emits `#warning "Build flags undefined"`. The value is only reported through
  `mdbx_build.flags`; it is deliberately space-free to survive make/shell quoting on all platforms.
- `-DMDBX_ENV_CHECKPID=1`, `-DMDBX_TXN_CHECKOWNER=1` — detect cross-process and cross-thread
  misuse. `MDBX_TXN_CHECKOWNER` already defaults to 1, but `MDBX_ENV_CHECKPID` defaults to a
  platform-dependent AUTO, so setting it explicitly is meaningful.

Windows only, in `src/Makevars.win`:

- `-D_WIN32_WINNT=0x0A00` — **mandatory, not tuning.** A non-DLL libmdbx build fails with an
  explicit `#error` if this is unset, because it needs a target Windows version to handle
  thread-local storage destructors. 0x0A00 (Windows 10) is >= Vista, so
  `MDBX_MANUAL_MODULE_HANDLER` is 0 and no `DllMain` hook is needed.
- `-DWIN32_LEAN_AND_MEAN=1`, `-DNOMINMAX=1` — keep `<windows.h>` from polluting the translation unit.
- `PKG_LIBS = -lntdll -ladvapi32 -luser32`.

Optimisation, PIC, and ABI flags are left entirely to R, per CRAN policy.

**Cleaning is a `clean:` target in `Makevars`.** `R CMD build` runs
`make -f Makeconf -f share/make/clean.mk -f Makevars clean`, which removes `vendor/libmdbx/mdbx.o`
— build's own cleanup only globs `src/*.o` and would otherwise ship the vendored object in the
tarball ("checking if this is a source package" NOTE).

`all: $(SHLIB)` **must be the first rule.** `R CMD SHLIB` passes no goal and reads `Makevars`
before `shlib.mk` supplies its own `all`, so otherwise `clean` becomes make's default goal and the
build cleans instead of compiling, producing zero objects. `.PHONY: all clean` does not prevent
this on its own — a real `all` rule has to precede `clean`.

This is the layout used by `pedrobtz/agecrypt`. RSQLite solves the same problem differently, by
naming the vendored object in `PKG_LIBS` with a `$(SHLIB):` prerequisite and shipping `cleanup`
scripts; either works, but do not mix them.

## Local patches

The vendored sources are **not pristine**: four patches route libmdbx's panic and logging paths
through R's API, remove nine diagnostic suppressions, and sidestep a false-positive
`-Warray-bounds` from Rtools' MinGW headers, so that `R CMD check --as-cran` reports no warnings
and libmdbx cannot terminate the R session. They must be re-applied whenever this pin moves.

**The authoritative record is [../tools/patches/](../tools/patches/)**, which lives in the source
repository only — `tools/` is excluded from the package build. This section keeps the narrative.
`tools/update-libmdbx.sh` re-vendors upstream and replays the series, which is verified to
reproduce the vendored tree byte-for-byte. `inst/COPYRIGHTS` describes the same changes in prose,
which is what travels in the tarball as the Apache-2.0 section 4(b) notice.

The upstream digests recorded above are the *pre-patch* values, and remain the thing to verify a
freshly downloaded amalgamation against.

### Why patch at all

Without these, `R CMD check --as-cran` reports two WARNINGs that no build flag can clear:

- `checking compiled code` — `__assert_rtn` / `__assert_fail` and `stderr` referenced from
  `mdbx.o`.
- `checking pragmas in C/C++ headers and code` — `#pragma GCC|clang diagnostic ignored` lines,
  one of which (`-Wcast-function-type`) is on R's non-portable list.

`MDBX_DEBUG=-1` was evaluated and rejected: it only defines `LOG_ENABLED()` to 0, leaving the
`fprintf` compiled — the check's symbol scan is static — while disabling libmdbx's error reporting
"at all, including any critical cases".

### Patch 1 — `osal_panic()` raises an R condition

Upstream's panic path calls the platform assert handler then `abort()` (POSIX), or `FatalExit()`
(Windows). All of those kill the R session. It now calls `mdbx_r_panic()`, implemented in
[../src/r_mdbx_hooks.cpp](../src/r_mdbx_hooks.cpp).

Every package-initiated libmdbx operation must run through `mdbx_r_run_guarded()`. The guard sits
below the C++ entry point and invokes only a C-compatible callback. On panic, the hook records the
message in thread-local storage and jumps back to that guard; the guard invokes an optional poison
callback, returns the details to C++, and `cpp11::stop()` raises the R condition with normal C++
unwinding. The enclosing `while (1)` in `osal_panic()` is retained so the compiler still sees the
function as non-returning. A direct `Rf_error()` remains only as an emergency fallback for a panic
outside a guarded package call, such as failure during native-library initialization.

**Caveat, deliberately accepted:** jumping out of libmdbx may leave internal state or locks
untouched. A panic already means libmdbx has detected a violated invariant, so every handle
implements a poison callback, rejects all later operations, and makes its finalizer avoid
re-entering libmdbx. Every guarded call site passes one — `mdbx_env_stat()` and `mdbx_env_info()`
were the last two that did not, fixed in the post-stage-9 review pass.

### Patch 2 — `debug_log_va()` writes to the R console

The fallback used when no logger callback is installed wrote to `stderr` with
`fprintf`/`vfprintf`. It now calls `mdbx_r_log_va()`, which uses `REprintf()`/`REvprintf()` so
output goes through R's console rather than around it.

Package loading calls `mdbx_setup_debug()` and lowers the global log level from `NOTICE` to
`FATAL`. This prevents libmdbx's `pthread_atfork` child hook from invoking the R console after a
fork. The fallback remains available for a fatal diagnostic during an ordinary main-thread R
call. A Unix regression test forks after package loading and verifies that the hook is silent.

### Patch 3 — diagnostic suppressions removed

Nine `#pragma GCC|clang diagnostic ignored` lines were replaced with a marker comment. They were
suppressing `-Wattributes`, `-Wnested-anon-types`, `-Wconstant-logical-operand`,
`-Walignment-reduction-ignored`, `-Wpedantic`, and `-Wcast-function-type`.

Removing a suppression is only safe if the underlying warning does not actually fire. **Verified
on Apple clang 21 / macOS arm64: the build is warning-free without them.** GCC on Linux and the
Rtools toolchain on Windows are *not* yet verified — if CI surfaces a warning, re-add that single
pragma and record it here as a known exception rather than removing the diagnostic.

Note that MSVC-style `#pragma warning(disable: ...)` is untouched: R's check only matches
`^\s*#pragma (GCC|clang) diagnostic ignored`, so those are irrelevant to it and still protect the
Windows build.

**Rejected alternative:** rewriting the pragmas as `_Pragma("GCC diagnostic ignored ...")` would
keep the suppression while evading the check's line-anchored text scan. That circumvents the
check's intent rather than satisfying it, and is not done here.

### Patch 4 — `NT_TIB` read without `__readgsqword()`

Rtools45's MinGW-w64 11 writes `__readgsqword()` so that GCC models the GS-relative offset as an
ordinary address; GCC 14 then reports `NtCurrentTeb()` as an out-of-bounds access from inside
`psdk_inc/intrin-impl.h`, which `R CMD check` classifies as a significant warning on the Windows
leg. Nothing is genuinely out of bounds — it is a toolchain-header false positive, unrelated to
libmdbx or to the other three patches.

It fires only where `mdbx.c` touches `NtCurrentTeb()`, which is two SEH sites, so it is avoided at
the source: `osal_current_tib()` loads the same `NT_TIB::Self` slot with one inline asm
instruction. The guard is `__MINGW32__ && __GNUC__ && !__clang__ && __x86_64__`; everything else
still goes through `NtCurrentTeb()`. Newer MinGW-w64 headers define the intrinsic this way
themselves, so the patch becomes a no-op once Rtools ships them.

**Rejected alternative:** `PKG_CFLAGS = -Wno-array-bounds` in `src/Makevars.win`. It trades the
warning for a "checking compilation flags used" WARNING — Writing R Extensions treats `-Wno-*` as
non-portable and warns that suppressing diagnostics hides real problems on untested platforms —
and generating the flag from `configure.win` is called out as unsafe for the same reason. This is
the only patch in the series that changes generated code rather than just diagnostics, and it is
also the only one whose effect is confined to a single toolchain.

### Reproducing

`tools/patches/README.md` carries the expected post-patch checksums and the apply order.
`tools/update-libmdbx.sh` does the whole flow: clone at tag, print provenance, record upstream
checksums, vendor the six files, replay the series, print post-patch checksums.
