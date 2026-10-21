## Resubmission of an archived package

mdbx was archived on 2026-10-19 because the valgrind issues reported for 0.1.1
were not corrected in time:

https://cran-archive.R-project.org/web/checks/2026/2026-10-19_check_results_mdbx.html
https://www.stats.ox.ac.uk/pub/bdr/memtests/valgrind/mdbx/

This version, 0.1.2, fixes all three problems in that log. The first is in the
bundled 'libmdbx' sources. The second is also in 'libmdbx', where the
'--track-origins=yes' output pointed to its cause. The third is in the
package's own code. The other 13 check flavours were OK for 0.1.1.

* Examples ERROR and 4 test failures, `Invalid argument (mdbx error 22)` from
  `mdbx_env_open()`. 'libmdbx' reserves address space for the database's
  maximum size up front, and by default that maximum is about 1.6 times the
  machine's physical RAM. Valgrind cannot map a region that large, and
  answers with EINVAL. 'libmdbx' already has code to retry with a smaller
  reservation, but it only runs in builds compiled with valgrind's headers.
  It now runs in every build, as a local patch to the bundled sources,
  described in `inst/COPYRIGHTS`. Natively an oversized reservation fails
  with ENOMEM, not EINVAL, so nothing changes outside valgrind.

* `Syscall param pwritev(vector[1])` / `pwrite64(buf) points to
  uninitialised byte(s)`, traced to `pnl_alloc`. When 'libmdbx' writes a
  free-list record, it reserves room for up to three more entries than the
  record holds, and filled that slack by copying past the end of the list,
  from uninitialised heap memory. It now copies only the entries the record
  holds and zero-fills the rest. Readers use the count stored in the record,
  so the on-disk format is unchanged. This is also a local patch, described
  in `inst/COPYRIGHTS`.

* `41,389 bytes in 5 blocks are definitely lost` from `txn_alloc`. After a
  'libmdbx' assertion failure the package does not call back into the
  library to free that transaction, and the test suite triggers such failures
  on purpose. The package now keeps these pointers in a static list, so the
  memory stays reachable instead of lost.

I reproduced the log on GitHub Actions before fixing it, with valgrind
3.27.1, `--leak-check=full --track-origins=yes`, and no suppressions. A
preloaded `sysconf()` reported 256 GB of RAM, so that 'libmdbx' would size
its reservation as it does on a machine like CRAN's. That run gave the same
examples ERROR, the same 4 test failures (`[ FAIL 4 | WARN 0 | SKIP 6 |
PASS 978 ]`), the same uninitialised-byte reports and the same 5 definitely
lost blocks. With 0.1.2, in the same configuration, examples and tests are
OK (`[ FAIL 0 | WARN 0 | SKIP 6 | PASS 988 ]`), and every one of the 37
processes valgrind ran reports 0 errors and 0 bytes definitely or
indirectly lost. This configuration is now part of the package's CI.

Some "possibly lost" blocks from `pnl_alloc` remain in the test log, but not
in the examples. They belong to databases the package must not close:

* in the main test process, databases the tests deliberately put into a
  failed state, which are never passed back to 'libmdbx';
* in the child processes that `test-fork.R` starts with
  `parallel::mcparallel()`, databases inherited from the parent, which only
  the parent may close.

'libmdbx' holds these blocks through pointers into their middle rather than
to their start, so valgrind cannot tell they are still in use.

## R CMD check results

0 errors | 0 warnings | 1 note

* New submission / Package was archived on CRAN: this is the resubmission
  described above.

## Test environments

GitHub Actions: macOS, Windows and Ubuntu (R release), Windows (R-devel),
Ubuntu (R oldrel-1), and the R-hub `ubuntu-clang` and `ubuntu-gcc16` r-devel
containers. Also UBSan (clang and gcc), the `clang-asan` and `gcc-asan`
containers, LTO, gctorture, and the valgrind configuration above.
