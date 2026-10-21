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
3.27.1 and the options from the memtests log, `--leak-check=full
--track-origins=yes`, with no suppressions. A preloaded `sysconf()` reported
256 GB of RAM, so that 'libmdbx' would size its reservation as it does on a
machine like CRAN's. That run gave the same examples ERROR, the same 4 test
failures (`[ FAIL 4 | WARN 0 | SKIP 6 | PASS 978 ]`), the same
uninitialised-byte reports and the same 5 definitely lost blocks.

With 0.1.2, in the same configuration, the examples and tests are OK
(`[ FAIL 0 | WARN 0 | SKIP 6 | PASS 988 ]`). There are no memory errors and
no definitely or indirectly lost blocks. 33 of the 37 processes valgrind
runs report `ERROR SUMMARY: 0 errors`, the main test process and the examples
among them.

The other 4 processes report 7 "possibly lost" records each. Each process is
an R session that the tests start. None of the 7 records was allocated by
this package: four come from R's `setenv()`, two from threads started by
'cli' and OpenBLAS, and one from glibc's dynamic loader.

0.1.2 also no longer leaves "possibly lost" blocks of its own. In 0.1.1,
'libmdbx' internal lists belonging to databases the package must not close
were reported that way: databases put into a failed state on purpose by the
tests, and databases inherited by forked child processes. The package now
records where those lists start, so valgrind can see they are still in use.
This needed one small read-only accessor added to the bundled sources. This
configuration is now part of the package's CI.

## R CMD check results

0 errors | 0 warnings | 1 note

* New submission / Package was archived on CRAN: this is the resubmission
  described above.

## Test environments

GitHub Actions: macOS, Windows and Ubuntu (R release), Windows (R-devel),
Ubuntu (R oldrel-1), and the R-hub `ubuntu-clang` and `ubuntu-gcc16` r-devel
containers. Also UBSan (clang and gcc), the `clang-asan` and `gcc-asan`
containers, LTO, gctorture, and the valgrind configuration above.
