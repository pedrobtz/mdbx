# List the named databases in an environment

Reports the named databases visible to this transaction, which is not
the same as the ones it could open: a database created by a transaction
that has not committed is not listed, and one deleted but not yet
committed still is.

## Usage

``` r
mdbx_dbi_list(txn, as = c("character", "raw"))
```

## Arguments

- txn:

  An `mdbx_txn` object, from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md).

- as:

  `"character"` (the default) to decode names as UTF-8 text, or `"raw"`
  for a list of raw vectors.

## Value

A character vector of names, or a list of raw vectors if `as = "raw"`.
Empty when the environment has only the main database.

## Details

Names are bytes, like keys, so a name that is not valid UTF-8 text needs
`as = "raw"`. The unnamed main database is not listed, having no name.

## See also

[`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_open.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path, max_dbs = 8)

mdbx_with_write(env, function(txn) {
  mdbx_dbi_open(txn, "files", create = TRUE)
  mdbx_dbi_open(txn, "metadata", create = TRUE)
})
#> <mdbx_dbi> metadata 

mdbx_with_read(env, function(txn) mdbx_dbi_list(txn))
#> [1] "files"    "metadata"

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
