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
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md),
  opened for writing. Both emptying and deleting are writes, so a read
  transaction is refused.

- db:

  An `mdbx_dbi` object from
  [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_open.md),
  or `NULL` for the main database — which can be emptied but not
  deleted.

- delete:

  If `TRUE`, delete the database rather than just emptying it.

## Value

`NULL`, invisibly.

## Details

Emptying a database that holds records also resets its [sequence
counter](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_sequence.md)
to zero, because 'libmdbx' rewrites the database's record and the
counter lives in it. (Emptying one that is already empty rewrites
nothing and leaves the counter alone, but that is not a distinction to
build on.) Do not rely on ids minted before an emptying staying unique
afterwards — if they are still referenced somewhere, remove the records
by deleting their keys instead.

Like every other write, this takes effect only when the transaction
commits.

## See also

[`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_open.md)

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
