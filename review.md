# Project code review

All four findings were reproduced and fixed. What each one was, and what
answered it:

## Findings

### High: alternate filesystem paths can deadlock the process — **fixed**

[`R/env.R:148`](R/env.R#L148) canonicalized only the directory component of an
environment path. Hard links and final-component symlinks therefore bypassed
the one-open registry. Opening a hard-linked alias while the original
environment was open blocked for more than 60 seconds; the same R process could
not close the incumbent environment while blocked.

Reproduced: both aliases hung the session rather than erroring.

Environments are now identified by the data file's filesystem identity —
`(device, inode)` on POSIX, `(volume, file index)` on Windows — which subsumes
symlink resolution and catches hard links, neither of which any amount of
string canonicalization relates. A file that does not exist yet has no identity,
so the registry check falls back to the canonical spelling under a
distinguishable prefix and the environment is re-keyed once its open has created
the file. `env_key_for()` in `src/r_mdbx.cpp`; the reasoning is in
[.agents/design.md](.agents/design.md) under *Identifying an environment*.

### Medium: stale database handles can target a replacement environment — **fixed**

[`R/dbi.R:79`](R/dbi.R#L79) recorded only the path, and
[`R/dbi.R:202`](R/dbi.R#L202) used that path as the ownership check. After an
environment was closed, deleted, and recreated at the same path, an old
`mdbx_dbi` silently accessed the same-named database in the replacement
environment.

Reproduced: the stale handle read the replacement's value.

Environments now carry an opaque per-open token, copied to their transactions
and recorded in every `mdbx_dbi`, and that is what `db_name()` compares. The
path is kept alongside it only so a refusal can name it — and when the two paths
are equal, the refusal says the environment was closed and replaced rather than
naming one path twice.

### Medium: imported sequence counters can be silently rounded — **fixed**

[`src/r_mdbx.cpp:1811`](src/r_mdbx.cpp#L1811) converted the native `uint64_t`
sequence counter to `double` before checking its range, and reads returned
immediately at line 1813. A database advanced beyond `2^53` by another binding
would therefore return an inaccurate counter.

The bound is now checked against the native value, before the conversion that
would round it, on the read path as well as the increment path. A counter past
`2^53` raises rather than being reported as a number that merely looks like it.
Not reachable through this binding alone, which refuses to advance a counter
there, so it has no regression test: it guards against another binding sharing
the database.

### Low: deleting the main database contradicts the documented contract — **fixed**

The R documentation said the main database cannot be deleted, but
[`src/r_mdbx.cpp:1846`](src/r_mdbx.cpp#L1846) passed `delete = TRUE` through.
`mdbx_drop()` empties the table and then returns success without consulting
`del` for a core DBI, so the call succeeded and the caller was told a deletion
had happened.

Reproduced: the call succeeded and purged the main database.

`db = NULL` with `delete = TRUE` is now refused, before anything is emptied, so
the refusal costs the caller nothing and `delete = FALSE` remains the way to ask
for what libmdbx would have done either way.

## Verification

- `devtools::test()`: 1017 passing tests; 5 subprocess tests skipped outside an
  installed package.
- `devtools::check(args = "--as-cran")`: 0 errors, 0 warnings, 0 notes.

The handle authentication, parent retention, fork checks, panic containment,
transaction tracking, and defensive finalizers otherwise look well designed
and are extensively tested.
