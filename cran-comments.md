## Update submission

This update fixes the issues reported for mdbx 0.1.0 under "Additional issues"
on the CRAN check page, clang-UBSAN and gcc-UBSAN. All of them are in the
bundled 'libmdbx' sources.

* Misaligned loads and stores (`mdbx.c:597`, `627`, `647`, `664`, `685`, `701`,
  and `224` via `fetch_txnid`). 'libmdbx' decides at compile time whether to
  dereference misaligned integer pointers directly, and enables that on x86-64
  and arm64. It is now built with `-DMDBX_UNALIGNED_OK=0`, the library's own
  switch for its byte-copy paths. This is set in `src/Makevars`.

* `index 1 out of bounds for type 'iovec [1]'` (`mdbx.c:30178` and nearby,
  gcc only). 'libmdbx' allocates some structures larger than they are declared
  and indexes past the declared trailing array, which `-fsanitize=bounds-strict`
  reports. The same pattern in two other structures, not reached by the
  package's tests, is fixed too. They are now C99 flexible array members, or
  are indexed through a pointer. Allocation sizes are unchanged. This is a new
  local patch to the bundled sources, and `inst/COPYRIGHTS` now describes it.

* The six `test-process.R` failures in both logs were a consequence of the
  first item. Those tests capture a child `Rscript`'s output, and the UBSAN
  diagnostics printed by the child ended up in that output. With the
  diagnostics gone, the tests pass.

I reproduced both reports locally at the flags in the memtests README.

* clang: `-fsanitize=undefined -fno-sanitize=function`, against the full test
  suite. 0.1.0 gives the same five sites and the same 6 failures / 982 passes
  as the clang-UBSAN log. 0.1.1 gives no UBSAN diagnostics and 988 passes.
* gcc 16: `-fsanitize=address,undefined,bounds-strict`, against a stand-alone
  driver of the bundled library. With 0.1.1 it gives no diagnostics.

The package's CI now runs UBSan with no checks disabled, plus the R-hub
`clang-asan` and `gcc-asan` containers.

## R CMD check results

0 errors | 0 warnings | 0 notes
