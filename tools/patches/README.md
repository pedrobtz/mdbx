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

Each patch file carries its own rationale and caveats in its header. 0001 and 0002 depend on the
hook implementations in [../../src/r_mdbx_hooks.cpp](../../src/r_mdbx_hooks.cpp); 0003 and 0005
are behaviour-neutral and only affect which warnings are printed; 0004 changes generated code, but
only on MinGW GCC.

0005 is the only patch that touches `mdbx.h`. `LICENSE`, `NOTICE` and `COPYRIGHT` are untouched —
their upstream digests in `.agents/vendoring.md` still verify.

## Applying

From the package root, against a freshly vendored pristine tree:

```sh
for p in tools/patches/*.patch; do patch -p1 < "$p"; done
```

Order matters: 0001, 0002 and 0004 all edit `mdbx.c`, and each one's hunk offsets assume its
predecessors have already been applied. 0005 is independent of the rest — it is the only one that
edits `mdbx.h`, and its `mdbx-internals.h` hunk does not overlap 0003's.

## Expected result

Applying the full series to pristine libmdbx v0.14.3 must yield exactly:

```
492def30b368eda82cc0ec3502fe390d0742bbf7f4d8d37b65136ea4497d36e2  mdbx.c
1d2fc0eb6477a3ea6f5a0a17ca65aa874a3b9bd299167c5645f16f45aa133b96  mdbx.h
d50c2af7ef92ec77d17cb1370bdd40f8c4483f7643379f74d377c0f3017dd817  mdbx-internals.h
```

If a patch fails to apply after a version bump, re-do that edit by hand against the new source,
regenerate the patch, and update the digests above — do not force it.
