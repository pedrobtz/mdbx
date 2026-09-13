# Changelog

## mdbx 0.1.0

- Initial version.

- [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md)
  refuses a path this process already has open, naming the conflict,
  rather than passing on the lock file’s own failure (`EAGAIN` on
  macOS). Different spellings of one environment – a relative path
  against an absolute one, a symlinked directory, the data file of a
  `subdir = TRUE` layout – are recognised as the same path
  ([\#2](https://github.com/pedrobtz/mdbx/issues/2)).

- [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_open.md)
  names the database it could not open, and says why `create = TRUE`
  needs a write transaction, instead of reporting libmdbx’s
  `MDBX_NOTFOUND` and `EACCES`
  ([\#3](https://github.com/pedrobtz/mdbx/issues/3)).

- `?mdbx-concurrency` no longer claims that two environments opened on
  the same file in one session are independent; they never were.
