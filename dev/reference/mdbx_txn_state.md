# State of a transaction

State of a transaction

## Usage

``` r
mdbx_txn_state(txn)
```

## Arguments

- txn:

  An `mdbx_txn` object, from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md).

## Value

One of `"active"`, `"committed"`, or `"aborted"`. `"poisoned"` is
reported for a transaction abandoned after a 'libmdbx' assertion
failure, and `"invalid"` for one whose handle has already been
reclaimed.

## See also

[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md)

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
