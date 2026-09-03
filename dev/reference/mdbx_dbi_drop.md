# Empty or delete a named database

`delete = FALSE` removes every record but keeps the database.
`delete = TRUE` removes the database itself, after which the handle
refers to nothing and reopening it needs `create = TRUE` again.

## Usage

``` r
mdbx_dbi_drop(txn, db, delete = FALSE)
```

## Arguments

- txn:

  An `mdbx_txn` object from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md),
  opened for writing.

- db:

  An `mdbx_dbi` object from
  [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_dbi_open.md),
  or `NULL` for the main database — which can be emptied but not
  deleted.

- delete:

  If `TRUE`, delete the database rather than just emptying it.

## Value

`NULL`, invisibly.

## Details

Like every other write, this takes effect only when the transaction
commits.

## See also

[`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_dbi_open.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path, max_dbs = 8)

mdbx_with_write(env, function(txn) {
  scratch <- mdbx_dbi_open(txn, "scratch", create = TRUE)
  mdbx_put(txn, "k", "v", db = scratch)
  mdbx_dbi_drop(txn, scratch)
  mdbx_keys(txn, db = scratch)
})
#> character(0)

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
