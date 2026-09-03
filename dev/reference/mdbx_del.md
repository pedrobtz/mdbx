# Delete a key

Removes `key` and its value. Deleting a key that is not present is not
an error; the return value says which happened.

## Usage

``` r
mdbx_del(txn, key, db = NULL)
```

## Arguments

- txn:

  An `mdbx_txn` object from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md),
  opened with `write = TRUE`.

- key:

  A raw vector, or a single string, which is stored as its UTF-8 bytes.

- db:

  An `mdbx_dbi` object from
  [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_dbi_open.md)
  naming a database to address instead of the unnamed main one, or
  `NULL` for the main database.

## Value

`TRUE` if a record existed and was removed, `FALSE` otherwise. Returned
invisibly.

## See also

[`mdbx_get()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_get.md),
[`mdbx_put()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_put.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

mdbx_with_write(env, function(txn) {
  mdbx_put(txn, "k", "v")
  mdbx_del(txn, "k")
})

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
