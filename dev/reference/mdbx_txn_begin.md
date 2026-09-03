# Begin a transaction

Starts a transaction against an open environment. Everything read or
written happens inside one: reads see a consistent snapshot taken when
the transaction began, and writes become visible to others only on
commit.

## Usage

``` r
mdbx_txn_begin(env, write = FALSE, flags = NULL)
```

## Arguments

- env:

  An `mdbx_env` object, from
  [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_open.md).

- write:

  If `TRUE`, start a read-write transaction; the environment must not
  have been opened with `readonly = TRUE`.

- flags:

  A character vector of 'libmdbx' transaction flag names, or `NULL` for
  none. `"NOMETASYNC"` and `"NOSYNC"` relax durability for this one
  transaction, exactly as the environment flags of the same names do for
  every transaction — see the Durability section of
  [`mdbx_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_flags.md).
  `"TRY"` fails with `MDBX_BUSY` rather than waiting for another
  process's writer. All three apply to write transactions only.

## Value

An `mdbx_txn` object.

## Details

'libmdbx' binds a transaction to the thread that started it, so an
environment supports **one transaction at a time per thread** — and R is
single-threaded, so that means one at a time. Beginning a second while
one is open is an error, never a deadlock or a hang. Distinct
environments are independent, and concurrency comes from separate
processes: many readers and one writer may hold transactions on the same
environment simultaneously.

A transaction must be ended with
[`mdbx_txn_commit()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_commit.md)
or
[`mdbx_txn_abort()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_abort.md).
One abandoned to the garbage collector is aborted, but that is a
backstop rather than a plan: a live write transaction holds the writer
lock until it ends.
[`mdbx_with_read()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_with_write.md)
and
[`mdbx_with_write()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_with_write.md)
handle this for you.

## See also

[`mdbx_txn_commit()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_commit.md),
[`mdbx_txn_abort()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_abort.md),
[`mdbx_with_write()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_with_write.md),
[`mdbx_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_flags.md),
[mdbx-concurrency](https://pedrobtz.github.io/mdbx/dev/reference/mdbx-concurrency.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

txn <- mdbx_txn_begin(env)
txn
#> <mdbx_txn> /tmp/RtmpNTEo83/file1c601a0bb3f4.mdbx 
#>   mode:  read-only 
#>   state: active 
mdbx_txn_abort(txn)

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
