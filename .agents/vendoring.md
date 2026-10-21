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
- `-DMDBX_UNALIGNED_OK=0` — send every unaligned 16/32/64-bit access through libmdbx's byte-copy
  and split-word paths. Upstream picks 8 on x86-64 and 4 on arm64 and then dereferences
  misaligned `uint*_t` pointers directly, which is undefined behaviour and is what CRAN's
  clang-UBSAN and gcc-UBSAN flavors, and the M1-SAN macOS run, reported against 0.1.0 (`unaligned_peek_u16/u32/u64`,
  `unaligned_poke_u32/u64`, and `atomic_load64` via `fetch_txnid`). libmdbx already defaults to 0
  under a sanitizer, but only detects one through `__SANITIZE_UNDEFINED__` or `ENABLE_UBSAN`, and
  CRAN defines neither. At -O2 the byte copies compile back to single loads; the one behavioural
  difference is that a meta-page txnid is read and written as two 32-bit atomics rather than one
  64-bit, which is the path upstream already takes on every non-x86 target and which the
  `txnid_a`/`txnid_b` meta protocol exists to make safe. It stays on the command line rather than
  in a patch because it is an upstream configuration knob, not a code change.

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

The vendored sources are **not pristine**: nine patches route libmdbx's panic and logging paths
through R's API, remove nine diagnostic suppressions, sidestep a false-positive `-Warray-bounds`
from Rtools' MinGW headers, stop the pre-C23 `bool`/`nullptr` compatibility macros from
shadowing the C23 keywords, and replace three trailing-array struct hacks with forms a
bounds-checking sanitizer accepts, so that `R CMD check --as-cran` reports no warnings and libmdbx cannot
terminate the R session. Three more, added for 0.1.2, make a default-geometry open work under valgrind,
stop a commit writing uninitialised bytes to disk, and expose where an environment's page-number
lists start, so environments the package never closes are not reported as possibly lost. They must be re-applied whenever this pin moves.

**The authoritative record is [../tools/patches/](../tools/patches/)**, which lives in the source
repository only — `tools/` is excluded from the package build. This section keeps the narrative.
`tools/update-libmdbx.sh` re-vendors upstream and replays the series, which is verified to
reproduce the vendored tree byte-for-byte. `inst/COPYRIGHTS` describes the same changes in prose,
which is what travels in the tarball as the Apache-2.0 section 4(b) notice.

The upstream digests recorded above are the *pre-patch* values, and remain the thing to verify a
freshly downloaded amalgamation against. All three source files are now patched — `mdbx.h` joined
`mdbx.c` and `mdbx-internals.h` with patch 5 — so none of those three digests matches what is on
disk; `tools/patches/README.md` carries the post-patch values. `LICENSE`, `NOTICE` and `COPYRIGHT`
are still verbatim.

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

### Patch 5 — `bool`/`true`/`false`/`nullptr` yield to the C23 keywords

C23 promotes all four from library macros to keywords. libmdbx still defines them for the C build
behind `#ifndef bool` / `!defined(nullptr)`, and those guards stay true under C23 — a keyword is
not a macro — so clang reports `keyword is hidden by macro definition` (`-Wkeyword-macro`) four
times, which `R CMD check` counts as significant warnings. Each guard gained the missing
`__STDC_VERSION__ < 202311L` clause.

**Why no CI leg caught this.** `-Wkeyword-macro` is clang-only — GCC has no such diagnostic, which
rules out the Ubuntu and Windows legs — and it only fires in C23 mode. Apple clang 21 on the macOS
leg defaults to `__STDC_VERSION__ 201710L`. CRAN's Debian leg compiles C as `clang-23 -std=gnu23`,
explicitly, which is the one configuration that sees it.

That gap is now closed on both ends. `.github/workflows/R-CMD-check.yaml` runs
`R CMD check --as-cran` in the R-hub containers built to match the two r-devel Linux flavors —
`ubuntu-clang` for `r-devel-linux-x86_64-debian-clang`, `ubuntu-gcc16` for the GCC 16 one — and
fails on a WARNING. `tools/update-libmdbx.sh` lists a local gnu23 compile as a post-bump step,
which is the same check a few seconds sooner.

**Behaviour-neutral, and verified so:** `clang -S -O2` of `mdbx.c` against the patched and
unpatched headers is byte-identical under both `-std=gnu17`, where the macros survive, and
`-std=gnu23`, where they are now dropped in favour of the keywords — modulo the `__TIME__` stamp
libmdbx embeds in its build string.

**Not fixed upstream.** libmdbx master carries the same code at the same lines as v0.14.3. Worth
sending upstream, and worth re-checking at the next version bump.

**Rejected alternatives:** `-Wno-keyword-macro` in `PKG_CFLAGS`, for the same reason it was
rejected in patch 4 — Writing R Extensions treats `-Wno-*` as non-portable, and it trades this
WARNING for a "checking compilation flags used" one. And `SystemRequirements: C17`, which would
pin the whole package back to a standard CRAN is actively moving off in order to avoid a
diagnostic about four lines.

### Patch 6 — trailing-array struct hacks become checkable

CRAN's gcc-UBSAN flavor (gcc 16, `-fsanitize=address,undefined,bounds-strict`) reported against
0.1.0:

    mdbx.c:30178:25: runtime error: index 1 out of bounds for type 'iovec [1]'

from `osal_ioring_add()`, on every commit that gathers more than one segment into a `pwritev()`.
Three structures are allocated larger than they declare and indexed past the declared bound:
`struct dpl` (`dp_t items[dpl_reserve_gap]`, the dirty-page list), `dml_t` (`da_t items[1]`, the
defrag map list) and `ior_item_t` (`struct iovec sgv[1]`, the write-ring gather list). clang treats
any trailing array as flexible and says nothing; `bounds-strict` checks the declared size.

A local harness at CRAN's flags reproduced the `iovec` reports at the same lines, and — by dirtying
more than 18 pages in one transaction — `index 18 out of bounds for type 'dp_t [18]'` at a dozen
more sites that the package's own tests never reach. That second finding is why this is fixed for
all three structures rather than only the one CRAN named: a real workload hits it.

`dpl` and `dml_t` become true C99 flexible array members. Their size helpers counted the header
with `sizeof()`, which included the declared array, so each gains a `*_header_size` macro adding it
back — every allocation is byte-for-byte what it was. `sgv` shares an anonymous union with `single`,
and a union cannot hold a flexible array member, so it is indexed through an `ior_sgv(item)`
accessor that goes via a pointer instead.

**Semantically neutral, not byte-identical.** With `__LINE__`/`__DATE__`/`__TIME__` pinned, gcc
-O2 emits an equivalent but different sequence in `osal_ioring_add` (a lost store-pair merge);
clang's diff is label and outlined-function renumbering.

**Why no CI leg caught this, or the alignment reports.** The sanitizer leg was a local copy of the
r-actions job with `-fno-sanitize=alignment` on `CFLAGS` — deliberately, to silence the misaligned
accesses now fixed by `-DMDBX_UNALIGNED_OK=0` — and it ran clang only, so `bounds-strict` never
ran at all. It now calls `pedrobtz/r-actions/.github/workflows/sanitizers.yml@v1` with
`asan: true`, which is clang UBSan with nothing relaxed plus the R-hub `clang-asan` and `gcc-asan`
containers, the latter being CRAN's gcc flavor.

**Rejected alternatives:** `-DMDBX_HAVE_PWRITEV=0`, which removes the `sgv` path by issuing one
`pwrite()` per contiguous run — an I/O behaviour change on every Linux and macOS install to silence
a check, which also does nothing for `dpl`. And `-fno-sanitize=bounds-strict`, which is CRAN's
setting rather than ours and would hide real out-of-bounds indexing.

### Patch 7 — a refused reservation is retried smaller, valgrind or not

CRAN's valgrind check of 0.1.1 (valgrind 3.27.1, Fedora 44) failed every example and test that
opened an environment with the default geometry: `Invalid argument (mdbx error 22)` from
`mdbx_env_open()`. That got the package archived on 2026-10-19 (issue #30).

libmdbx's default upper bound is `reasonable_db_maxsize()`, about 1.6x physical RAM, and
`osal_mmap()` reserves all of it up front. Valgrind cannot map an arbitrarily large region and
answers an oversized `mmap()` with `EINVAL`. On a 16 GB GitHub runner the default asks for ~20 GB,
which valgrind maps, so the package's own valgrind leg was green; CRAN's machine has far more RAM.
The CI leg now reproduces this by preloading `tools/valgrind/fake-ram.c`, which makes `sysconf()`
report 256 GB.

Upstream already copes: on `EINVAL` it halves the reservation toward the current size and retries.
But only under `RUNNING_ON_ASAN || mdbx_running_on_Valgrind()`, and the latter is constant 0
without `ENABLE_MEMCHECK` and valgrind's headers, which neither this package nor CRAN sets. The
patch drops the condition. The retry is upstream's own code, live in its ASAN builds, and
`geo_in_bytes.upper` follows the reduced mapping there already. Natively an oversized
`MAP_NORESERVE` reservation fails with `ENOMEM`, so the branch is not reached.

**Rejected alternatives:** a package-level default `map_size`, which would change the default
geometry for every user to satisfy one checker (and map sizing is an open question in
`design.md`); and `-DENABLE_MEMCHECK`, tried for the CI leg and reverted — it needs
`<valgrind/memcheck.h>` at build time, multiplied the uninitialised-value reports, and divides the
assumed RAM by eight under valgrind.

### Patch 8 — GC records stop carrying uninitialised list slack

The same CRAN run reported `Syscall param pwritev(vector[1])` / `pwrite64(buf) points to
uninitialised byte(s)` on commit. CI had suppressed these as libmdbx writing page padding.
`--track-origins=yes`, which CRAN uses, shows otherwise: the bytes come from `pnl_alloc()`, not
from the page — `page_shadow_alloc()` zeroes every page it hands out.

`gc_store_retired()` reserves a GC record for `chunk_hi = left_before | 3` page numbers, up to three
more than it stores, then copies the whole reservation from the retired-pages list. The record's
count says `chunk`, and every reader goes by it, so the tail is never read — but it is whatever
follows the list in memory, and that is uninitialised `malloc()` slack. The patch copies
`gc_chunk_bytes(chunk)` and zeroes the rest. Record size and the bytes any reader sees are
unchanged; the copy also stops reading past the end of the list.

### Patch 9 — where an environment's page-number lists start

With 0.1.2's first three fixes, CRAN's valgrind options still left errors in every test process:
"possibly lost" records, which CRAN's default `--errors-for-leak-kinds=definite,possible` counts.
All of them were the two page-number lists `txn_basal_create()` allocates for an environment's
preallocated write transaction (`wr.repnl`, `wr.retired_pages`), in environments this package
never closes on purpose — panicked ones, and those a forked child inherits. `pnl_alloc()` returns
`malloc() + 4`, so nothing holds the start of either block, and valgrind cannot tell them from a
leak. 8 such records appeared in each of 27 forked children of `test-fork.R`.

The patch appends `mdbx_r_env_heap_roots()`, which returns `pnl - 1` for both lists. The package
calls it after each open and each write transaction, stores the result in `env_handle::heap_roots`,
and copies it into the abandoned-handle registry when it gives an environment up. It never
dereferences the values. The lists move only inside a write transaction, so they are current
whenever the environment is not mid-transaction — which covers a panic in the tests and a fork
taken between transactions. A stale value is harmless: at worst that record is reported again.

**Rejected alternatives:** valgrind's `--leak-check-heuristics`, none of which matches a 4-byte
interior offset and which CRAN does not set; and calling `gc()` before forking in the tests, which
removes only the environments that were garbage anyway, not the panicked ones every child inherits.

### Reproducing

`tools/patches/README.md` carries the expected post-patch checksums and the apply order.
`tools/update-libmdbx.sh` does the whole flow: clone at tag, print provenance, record upstream
checksums, vendor the six files, replay the series, print post-patch checksums.
