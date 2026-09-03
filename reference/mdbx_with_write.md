# Run code inside a transaction

Begins a transaction, calls `fun` with it, and ends it — whatever
happens. `mdbx_with_write()` commits if `fun` returns normally and
aborts if it throws; `mdbx_with_read()` always aborts, which for a read
transaction simply releases the snapshot. Both use
[`on.exit()`](https://rdrr.io/r/base/on.exit.html), so the transaction
is also ended if `fun` is interrupted.

## Usage

``` r
mdbx_with_write(env, fun)

mdbx_with_read(env, fun)
```

## Arguments

- env:

  An `mdbx_env` object, from
  [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md).

- fun:

  A function of one argument, called with the `mdbx_txn`.

## Value

The value of `fun`.

## Details

This is the recommended way to use transactions: it makes the "abandoned
a write transaction and kept the writer lock" mistake unreachable.

## See also

[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

# Committed on normal return.
mdbx_with_write(env, function(txn) mdbx_txn_state(txn))
#> [1] "active"

mdbx_with_read(env, function(txn) mdbx_txn_state(txn))
#> [1] "active"

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
