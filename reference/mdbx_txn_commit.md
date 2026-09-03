# Commit a transaction

Makes the transaction's writes durable and visible to other readers, and
ends the transaction.

## Usage

``` r
mdbx_txn_commit(txn)
```

## Arguments

- txn:

  An `mdbx_txn` object, from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md).

## Value

`NULL`, invisibly.

## Details

Unlike
[`mdbx_txn_abort()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_abort.md),
this is not idempotent: committing an already-finished transaction is an
error, because the second call cannot do what it appears to. Note also
that a commit which cannot complete is turned into an abort by 'libmdbx'
— if this raises an error, the transaction has still ended, and its
writes are gone.

Some failures inside a transaction end it there and then. A rejected key
or value size
([`mdbx_put()`](https://pedrobtz.github.io/mdbx/reference/mdbx_put.md)
returning `MDBX_BAD_VALSIZE`) is just that one operation failing, and
the transaction carries on. A failure that exhausts the map
(`MDBX_MAP_FULL`) instead marks the transaction unusable: every later
operation fails with `MDBX_BAD_TXN`, and the commit reports that the
whole transaction was rolled back rather than committed.
[`mdbx_txn_state()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_state.md)
reads `"aborted"` in that case.

## See also

[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md),
[`mdbx_txn_abort()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_abort.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

txn <- mdbx_txn_begin(env, write = TRUE)
mdbx_txn_commit(txn)
mdbx_txn_state(txn)
#> [1] "committed"

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
