# List the named databases in an environment

Reports the named databases visible to this transaction. Visibility is
the transaction's own: a database this transaction created is listed
immediately, and one it deleted is gone immediately, both before any
commit. What other transactions see is decided when this one commits or
aborts — until then they see neither the creation nor the deletion.

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

That makes this the way to ask whether a database exists without
handling an error, which is what
[`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_open.md)
raises for a name that was never created.

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
