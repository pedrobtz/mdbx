## R CMD check results

0 errors | 0 warnings | 1 note

The note is "New submission".

## Resubmission

This is a resubmission, addressing the WARNING reported by the incoming
pretest on the Debian clang-23 leg:

    vendor/libmdbx/mdbx.h:417:9: warning: keyword is hidden by macro definition [-Wkeyword-macro]
    vendor/libmdbx/mdbx.h:420:9: warning: keyword is hidden by macro definition [-Wkeyword-macro]
    vendor/libmdbx/mdbx.h:423:9: warning: keyword is hidden by macro definition [-Wkeyword-macro]
    vendor/libmdbx/mdbx-internals.h:361:9: warning: keyword is hidden by macro definition [-Wkeyword-macro]

The bundled 'libmdbx' sources define `bool`, `true`, `false` and `nullptr` for
C compilers that do not provide them, behind `#ifndef bool` and
`!defined(nullptr)` guards. C23 promotes all four to keywords, and a keyword is
not a macro, so those guards remain true and the macros shadow the keywords.
Each guard now also tests `__STDC_VERSION__ < 202311L`, so the definitions
apply only where the compiler does not supply the keyword itself.

That is a change to the bundled sources, and it is behaviour-neutral:
`clang -S -O2` of `mdbx.c` against the patched and unpatched headers is
byte-identical under both `-std=gnu17`, where the macros survive, and
`-std=gnu23`, where they now give way to the keywords -- apart from the
`__TIME__` stamp 'libmdbx' embeds in its build string. It is recorded as a
fifth local patch and described in `inst/COPYRIGHTS`.

The two changes below were in the previous submission, which did not get past
the pretest, and are unchanged.

In response to the reviewer's comment:

* `\value` was missing from `man/mdbx_scan_max.Rd`. It is now documented:
  `mdbx_scan_max` is exported data rather than a function, and the tag states
  the class and length of the object (a length-one numeric vector), its value,
  and what that value governs -- the number of records above which `mdbx_keys()`
  and `mdbx_items()` refuse a scan that was given no `limit`.

  Every other exported function already carried `\value`. The two remaining
  topics without one, `?mdbx-concurrency` and `?mdbx-errors`, document concepts
  rather than objects: neither has a `\usage` section and neither is callable.

That submission also carried one bug fix, in `mdbx_dbi_drop()`. Emptying the
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
no system library, submodule, or CMake step. The bundled sources carry five
local patches: four route the library's panic and logging paths through R's
API so that an internal assertion cannot terminate the R session, remove
upstream's diagnostic-suppression pragmas, and avoid a false-positive
-Warray-bounds from Rtools' MinGW headers; the fifth is the C23 fix described
above. Both the bundling and the modifications are declared in
`inst/COPYRIGHTS`, which is the Apache-2.0 section 4(b) notice, and the
upstream `LICENSE` and `NOTICE` files ship alongside the sources. Copyright holders for the bundled code are listed
in `Authors@R`.
