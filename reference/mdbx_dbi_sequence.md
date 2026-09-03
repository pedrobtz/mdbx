# A database's sequence counter

Every database carries a 64-bit counter that 'libmdbx' stores with it.
Reading it with `increment = 0` reports its current value; a positive
`increment` reserves that many values and returns the first, so two
callers in separate transactions can never be handed the same number.

## Usage

``` r
mdbx_dbi_sequence(txn, db = NULL, increment = 0)
```

## Arguments

- txn:

  An `mdbx_txn` object from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md).
  Incrementing needs a write transaction; reading does not.

- db:

  An `mdbx_dbi` object from
  [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_open.md),
  or `NULL` for the main database.

- increment:

  How many values to reserve. `0`, the default, reads the counter
  without changing it.

## Value

The counter's value before the increment, as a number.

## Details

It is the natural way to mint ids — a monotonically increasing insertion
order, of the kind a cache uses to evict what was stored longest ago.
Encode the result big-endian if it is going to be a key, so that byte
order matches numeric order.

Like every other write, an increment only stands if the transaction
commits.

## See also

[`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_open.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path, max_dbs = 8)

mdbx_with_write(env, function(txn) {
  ids <- mdbx_dbi_open(txn, "ids", create = TRUE)

  c(first = mdbx_dbi_sequence(txn, ids, 1),
    second = mdbx_dbi_sequence(txn, ids, 1),
    current = mdbx_dbi_sequence(txn, ids))
})
#>   first  second current 
#>       0       1       2 

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
