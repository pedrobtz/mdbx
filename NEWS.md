# mdbx 0.1.0

* Initial version.

* `mdbx_env_open()` refuses a path this process already has open, naming the
  conflict, rather than passing on the lock file's own failure (`EAGAIN` on
  macOS). Different spellings of one environment -- a relative path against an
  absolute one, a symlinked directory, the data file of a `subdir = TRUE`
  layout -- are recognised as the same path (#2).

* `mdbx_dbi_open()` names the database it could not open, and says why
  `create = TRUE` needs a write transaction, instead of reporting libmdbx's
  `MDBX_NOTFOUND` and `EACCES` (#3).

* `?mdbx-concurrency` no longer claims that two environments opened on the same
  file in one session are independent; they never were.
