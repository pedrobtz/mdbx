# Open an MDBX environment

Opens, and by default creates, an MDBX environment at `path`. An
environment is the unit that holds the memory map, the lock, and the
databases within it; transactions and all data access happen against
one.

## Usage

``` r
mdbx_env_open(
  path,
  readonly = FALSE,
  create = TRUE,
  subdir = FALSE,
  max_dbs = 16L,
  map_size = NULL,
  max_readers = NULL,
  mode = "0664",
  flags = NULL
)
```

## Arguments

- path:

  Path to the environment. With `subdir = FALSE` (the default) this is
  the data file itself, and the lock file is the same path with `-lck`
  appended. With `subdir = TRUE` it is a directory, which libmdbx
  populates with `mdbx.dat` and `mdbx.lck`.

- readonly:

  If `TRUE`, open for reading only; no write transaction can be started,
  and the environment must already exist.

- create:

  If `FALSE`, require the environment to exist already rather than
  creating it. This is a best-effort check rather than an atomic one:
  libmdbx has no "open but never create" flag, so the existence test and
  the open are two steps, and another process deleting the database in
  between would leave a fresh one created here.

- subdir:

  Selects the on-disk layout described under `path`. It applies only
  when creating; opening an existing environment detects the layout.

- max_dbs:

  How many named databases to make room for. The default of 16 is this
  package's, not libmdbx's: libmdbx reserves none, which makes
  [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_open.md)
  fail with `MDBX_DBS_FULL` on an environment opened with default
  arguments. Unused slots cost nothing. Each name that

  Each name that
  [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_open.md)
  resolves occupies one slot. Raise this if you need more than 16, or
  pass `NULL` to take libmdbx's default of none — which leaves only the
  unnamed main database usable.

- map_size:

  Upper bound, in bytes, on the size the memory map may grow to, or
  `NULL` for the libmdbx default. Only the upper bound is set; the
  initial size and growth behaviour stay at their defaults.

- max_readers:

  Number of reader slots to make room for, or `NULL` for the libmdbx
  default. One slot is used per process holding a read transaction, so
  this is the ceiling on concurrent readers across all processes — see
  [mdbx-concurrency](https://pedrobtz.github.io/mdbx/reference/mdbx-concurrency.md).
  The default is derived from the lock file's page size (a few hundred,
  platform-dependent); raise it only if you expect more concurrent
  reader processes than that. It sizes the lock file, so it takes effect
  only for the first process to open the environment.

- mode:

  File permissions for a newly created database, as a string of octal
  digits or an [octmode](https://rdrr.io/r/base/octmode.html) object.
  The default `"0664"` is libmdbx's own, and is masked by the process
  `umask` as usual — so it typically lands as `0644`, readable by
  everyone. Pass `"0600"` for a database only its owner can read.
  Ignored when the database already exists.

- flags:

  A character vector of 'libmdbx' flag names, or `NULL` for none. These
  are the remaining `MDBX_*` environment flags, with the prefix dropped
  —
  [`mdbx_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_flags.md)
  lists them and explains what each does.

  The durability flags live here: `"NOMETASYNC"`, `"SAFE_NOSYNC"` and
  `"UTTERLY_NOSYNC"` each make commits cheaper by giving up some of what
  a crash cannot take away, and the last of the three can leave the
  database corrupt. The default — passing nothing — is fully durable.
  Read the Durability section of
  [`mdbx_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_flags.md)
  before using any of them.

## Value

An `mdbx_env` object.

## Details

The environment is closed when
[`mdbx_env_close()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_close.md)
is called on it, or when the object is garbage collected, whichever
happens first. Relying on garbage collection is safe but not timely;
close explicitly when the moment matters.

## See also

[`mdbx_env_close()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_close.md),
[`mdbx_env_is_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_is_open.md),
[`mdbx_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_flags.md),
[mdbx-concurrency](https://pedrobtz.github.io/mdbx/reference/mdbx-concurrency.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")

env <- mdbx_env_open(path)
env
#> <mdbx_env> /tmp/RtmpOrf7TD/file1c594e85f781.mdbx 
#>   access: read-write 
#>   layout: single file 
#>   status: open 

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
