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

* `mdbx_dbi_drop()` refuses to empty the main database while the environment
  holds any named database. A named database is a record in the main database,
  so 'libmdbx' purges every one of them along with it -- silent, irreversible,
  and the opposite of what "removes every record but keeps the database" leads
  a caller to expect. Drop them by name first, or delete the main database's
  keys individually.

* `mdbx_dbi_drop(db = NULL, delete = TRUE)` is now an error. The main database
  records the named ones and cannot be deleted; 'libmdbx' silently ignores the
  request and reports success, so the caller was told a deletion had happened
  when it had not.
