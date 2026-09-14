# Project code review

## Findings

### High: alternate filesystem paths can deadlock the process

[`R/env.R:148`](R/env.R#L148) canonicalizes only the directory component of an
environment path. Hard links and final-component symlinks therefore bypass the
one-open registry. Opening a hard-linked alias while the original environment
was open blocked for more than 60 seconds; the same R process could not close
the incumbent environment while blocked. Existing paths should be identified by
filesystem identity, or at least fully resolved before the registry check.

### Medium: stale database handles can target a replacement environment

[`R/dbi.R:79`](R/dbi.R#L79) records only the path, and
[`R/dbi.R:202`](R/dbi.R#L202) uses that path as the ownership check. After an
environment was closed, deleted, and recreated at the same path, an old
`mdbx_dbi` silently accessed the same-named database in the replacement
environment. Add an opaque per-environment generation token to environments,
transactions, and DBI records.

### Medium: imported sequence counters can be silently rounded

[`src/r_mdbx.cpp:1811`](src/r_mdbx.cpp#L1811) converts the native `uint64_t`
sequence counter to `double` before checking its range, and reads return
immediately at line 1813. A database advanced beyond `2^53` by another binding
would therefore return an inaccurate counter. Check the native value before
conversion and reject values R cannot represent exactly (or expose an exact
64-bit representation).

### Low: deleting the main database contradicts the documented contract

The R documentation says the main database cannot be deleted, but
[`src/r_mdbx.cpp:1846`](src/r_mdbx.cpp#L1846) passes `delete = TRUE` through.
`mdbx_dbi_drop(txn, NULL, delete = TRUE)` succeeds and purges the main
database. Reject this combination explicitly or document that it behaves as
emptying the main database.

## Verification

- `devtools::test()`: 998 passing tests; 5 subprocess tests skipped outside an installed package.
- `devtools::check(args = "--as-cran")`: 0 errors, 0 warnings, 0 notes.

The handle authentication, parent retention, fork checks, panic containment,
transaction tracking, and defensive finalizers otherwise look well designed
and are extensively tested.
