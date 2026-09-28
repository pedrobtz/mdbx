# libmdbx patch series

`src/vendor/libmdbx/` is vendored **patched**, not pristine. This directory is the
authoritative record of what was changed and why, and the machinery for re-applying it.

Patches are applied **by the maintainer during a version bump**, never at build time — an R
package cannot rely on `patch(1)` existing on a user's machine. `tools/update-libmdbx.sh`
re-vendors upstream and replays the series.

| Patch | Effect |
|---|---|
| `0001-panic-via-R-condition.patch` | `osal_panic()` returns to a package-owned guard, poisons the owner, then raises an R condition instead of terminating R |
| `0002-log-via-R-console.patch` | `debug_log_va()` writes through `REprintf()` instead of `stderr` |
| `0003-drop-diagnostic-suppressions.patch` | removes nine `#pragma GCC/clang diagnostic ignored` lines |
| `0004-mingw-teb-array-bounds.patch` | reads `NT_TIB::Self` directly instead of via `__readgsqword()`, so Rtools' MinGW headers stop tripping `-Warray-bounds` |
| `0005-c23-keyword-macros.patch` | defines `bool`/`true`/`false`/`nullptr` only before C23, where they are not yet keywords, so clang stops tripping `-Wkeyword-macro` |
| `0006-flexible-array-members.patch` | turns the `dpl`/`dml_t` trailing arrays into C99 flexible array members and indexes `ior_item_t::sgv` through a pointer, so gcc's `-fsanitize=bounds-strict` stops reporting libmdbx's struct hacks |

Each patch file carries its own rationale and caveats in its header. 0001 and 0002 depend on the
hook implementations in [../../src/r_mdbx_hooks.cpp](../../src/r_mdbx_hooks.cpp); 0003 and 0005
are behaviour-neutral and only affect which warnings are printed; 0004 changes generated code, but
only on MinGW GCC; 0006 is semantically neutral, keeps every allocation size, and changes generated
code only in instruction selection.

0006 is half of the fix for CRAN's UBSAN reports against 0.1.0. The other half is not a patch:
`-DMDBX_UNALIGNED_OK=0` in `src/Makevars`, which is an upstream configuration knob.

0005 is the only patch that touches `mdbx.h`. `LICENSE`, `NOTICE` and `COPYRIGHT` are untouched —
their upstream digests in `.agents/vendoring.md` still verify.

## Applying

From the package root, against a freshly vendored pristine tree:

```sh
for p in tools/patches/*.patch; do patch -p1 < "$p"; done
```

Order matters: 0001, 0002, 0004 and 0006 all edit `mdbx.c`, and each one's hunk offsets assume
its predecessors have already been applied. 0006 also edits `mdbx-internals.h`, after 0003 and
0005. 0005 is independent of the rest — it is the only one that
edits `mdbx.h`, and its `mdbx-internals.h` hunk does not overlap 0003's.

## Expected result

Applying the full series to pristine libmdbx v0.14.3 must yield exactly:

```
f131852a45f055c652d5b56a6b2b226a0375409d309690bae740359b112c9708  mdbx.c
1d2fc0eb6477a3ea6f5a0a17ca65aa874a3b9bd299167c5645f16f45aa133b96  mdbx.h
4e4bfcbe9e149fcb4a9dbd160c1660981ca5038a22bdd14d09689ee5a433e682  mdbx-internals.h
```

If a patch fails to apply after a version bump, re-do that edit by hand against the new source,
regenerate the patch, and update the digests above — do not force it.
