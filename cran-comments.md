## R CMD check results

0 errors | 0 warnings | 0 notes

## Resubmission

This is a resubmission. In response to the reviewer's comment:

* `\value` was missing from `man/mdbx_scan_max.Rd`. It is now documented:
  `mdbx_scan_max` is exported data rather than a function, and the tag states
  the class and length of the object (a length-one numeric vector), its value,
  and what that value governs -- the number of records above which `mdbx_keys()`
  and `mdbx_items()` refuse a scan that was given no `limit`.

  Every other exported function already carried `\value`. The two remaining
  topics without one, `?mdbx-concurrency` and `?mdbx-errors`, document concepts
  rather than objects: neither has a `\usage` section and neither is callable.

This submission also carries one bug fix, in `mdbx_dbi_drop()`. Emptying the
unnamed main database destroyed every named database in the environment,
silently and irreversibly, because 'libmdbx' stores each named database as a
record inside the main one and purges the whole tree. A caller following the
documentation ("removes every record but keeps the database") could lose data,
so the operation is now refused while any named database exists. The related
case of `delete = TRUE` on the main database, which 'libmdbx' accepts and
ignores while reporting success, is refused as well. Both are covered by new
tests.

## Notes for the reviewer

This is a new submission.

The package bundles the amalgamated sources of 'libmdbx' (Apache-2.0) under
`src/vendor/libmdbx/`, compiled into the package's own shared object. There is
no system library, submodule, or CMake step. The bundled sources carry four
local patches, which route the library's panic and logging paths through R's
API so that an internal assertion cannot terminate the R session. Both the
bundling and the modifications are declared in `inst/COPYRIGHTS`, which is the
Apache-2.0 section 4(b) notice, and the upstream `LICENSE` and `NOTICE` files
ship alongside the sources. Copyright holders for the bundled code are listed
in `Authors@R`.
