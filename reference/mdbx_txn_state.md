# State of a transaction

What this reports is whether the transaction can still be used, not
whether its native handle happens to be allocated. Three of the five
answers exist because those differ: a transaction 'libmdbx' has marked
erroneous, one poisoned by an assertion failure, and one inherited
across a `fork()` are each refused by every operation, and reporting
them as `"active"` described only this package's own bookkeeping.

## Usage

``` r
mdbx_txn_state(txn)
```

## Arguments

- txn:

  An `mdbx_txn` object, from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md).

## Value

One of:

- `"active"`:

  Open and usable.

- `"committed"`:

  Ended by
  [`mdbx_txn_commit()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_commit.md);
  its writes are durable.

- `"aborted"`:

  Ended by
  [`mdbx_txn_abort()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_abort.md),
  by the garbage collector, or by its environment closing; its writes
  are gone.

- `"failed"`:

  Still open, but 'libmdbx' has marked it erroneous — `MDBX_MAP_FULL` is
  the usual cause. Every operation now fails with `MDBX_BAD_TXN` and
  committing reports a rollback, so the only thing left to do with it is
  end it.

- `"poisoned"`:

  Abandoned after a 'libmdbx' assertion failure, in this transaction or
  in the environment that owns it. Aborting it is still safe, and does
  not re-enter 'libmdbx'; afterwards it reads as `"aborted"` like any
  other ended transaction.

- `"invalid"`:

  The handle has been reclaimed, or was inherited across a `fork()` and
  belongs to another process — see
  [mdbx-concurrency](https://pedrobtz.github.io/mdbx/reference/mdbx-concurrency.md).

## See also

[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

txn <- mdbx_txn_begin(env)
mdbx_txn_state(txn)
#> [1] "active"
mdbx_txn_abort(txn)
mdbx_txn_state(txn)
#> [1] "aborted"

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
