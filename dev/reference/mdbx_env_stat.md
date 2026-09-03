# Database statistics

Reports the shape of the main database: its page size, B-tree depth,
page counts, and how many records it holds.

## Usage

``` r
mdbx_env_stat(x, ...)

# S3 method for class 'mdbx_txn'
mdbx_env_stat(x, db = NULL, ...)
```

## Arguments

- x:

  An `mdbx_env` from
  [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_open.md),
  or an `mdbx_txn` from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md).

- ...:

  Unused, for extensibility.

- db:

  An `mdbx_dbi` object from
  [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_dbi_open.md)
  to report on instead of the main database, or `NULL` for the main one.
  Only available when `x` is a transaction, since a database is resolved
  within one.

## Value

A named list of numbers: `pagesize`, `depth`, `branch_pages`,
`leaf_pages`, `overflow_pages`, `entries` (the number of records), and
`mod_txnid` (the transaction that last modified the database). Counts
are `double` because 'libmdbx' reports them as 64-bit integers, which R
has no type for; every realistic value is exact.

## Details

Passing a transaction reports what that transaction sees, including
changes it has made but not committed. Passing the environment reports
the same thing whenever this thread holds a transaction, because the
environment form reuses it — so uncommitted changes are included, and an
abort takes the counts back down.

The two therefore agree in a single-threaded R session. They differ only
when a transaction holds a snapshot the environment has moved past,
which requires another process to have committed in the meantime.

Without `db`, the counts cover the **whole environment** — every named
database as well as the main one. Measured, since 'libmdbx' does not say
so: a main database of 4 keys plus a named database of 7 reports 11
entries. Pass `db` for one database's own B-tree.

## See also

[`mdbx_env_info()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_info.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

mdbx_with_write(env, function(txn) {
  mdbx_put(txn, "a", "1")

  # Counted before the commit.
  mdbx_env_stat(txn)$entries
})
#> [1] 1

mdbx_env_stat(env)$entries
#> [1] 1

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
