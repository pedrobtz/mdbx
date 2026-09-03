# Abort a transaction

Discards the transaction's writes and ends it. Aborting is idempotent:
doing it to an already-finished transaction does nothing, so it is safe
to register with [`on.exit()`](https://rdrr.io/r/base/on.exit.html)
alongside an explicit
[`mdbx_txn_commit()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_commit.md).

## Usage

``` r
mdbx_txn_abort(txn)
```

## Arguments

- txn:

  An `mdbx_txn` object, from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md).

## Value

`NULL`, invisibly.

## See also

[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md),
[`mdbx_txn_commit()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_commit.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

txn <- mdbx_txn_begin(env, write = TRUE)
mdbx_txn_abort(txn)
mdbx_txn_abort(txn) # already aborted; does nothing

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
