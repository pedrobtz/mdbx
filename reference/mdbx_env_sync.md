# Flush an environment to disk

Writes and flushes any data a relaxed durability mode has left
outstanding. With the default durability there is never anything to
flush, because
[`mdbx_txn_commit()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_commit.md)
has already done it.

## Usage

``` r
mdbx_env_sync(env, force = TRUE, nonblock = FALSE)
```

## Arguments

- env:

  An `mdbx_env` object, from
  [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md).

- force:

  If `TRUE`, always flush. If `FALSE`, flush only if a threshold set on
  the environment has been reached, which is 'libmdbx”s polling mode.

- nonblock:

  If `TRUE`, give up rather than wait when another process is in a write
  transaction. The wait is signalled as an `MDBX_BUSY` error.

## Value

Invisibly, `TRUE` if there was unsynced data and it was written, or
`FALSE` if nothing was pending.

## Details

Under `"SAFE_NOSYNC"` this also establishes a new steady commit point,
which is what lets 'libmdbx' start reusing freed pages again — so it
bounds file growth as well as making data durable.

## See also

[`mdbx_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_flags.md),
[`mdbx_env_set_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_set_flags.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path, flags = "SAFE_NOSYNC")

mdbx_with_write(env, function(txn) mdbx_put(txn, "k", "v"))

# The commit above flushed nothing; this does.
mdbx_env_sync(env)

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
