# Write a value

Stores `value` under `key`, replacing any existing value unless
`overwrite` is `FALSE`.

## Usage

``` r
mdbx_put(txn, key, value, overwrite = TRUE, db = NULL)
```

## Arguments

- txn:

  An `mdbx_txn` object from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md),
  opened with `write = TRUE`.

- key:

  A raw vector, or a single string, which is stored as its UTF-8 bytes.

- value:

  A raw vector, or a single string, which is stored as its UTF-8 bytes.
  Use `serialize(x, NULL)` for an arbitrary R object.

- overwrite:

  If `FALSE`, leave an existing value alone and return `FALSE` instead
  of replacing it.

- db:

  An `mdbx_dbi` object from
  [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_open.md)
  naming a database to address instead of the unnamed main one, or
  `NULL` for the main database.

## Value

`TRUE` if the value was stored, `FALSE` if `overwrite = FALSE` and the
key already existed. Returned invisibly.

## See also

[`mdbx_get()`](https://pedrobtz.github.io/mdbx/reference/mdbx_get.md),
[`mdbx_del()`](https://pedrobtz.github.io/mdbx/reference/mdbx_del.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

mdbx_with_write(env, function(txn) {
  mdbx_put(txn, "k", "first")

  # Refuses to replace, and says so.
  mdbx_put(txn, "k", "second", overwrite = FALSE)
})

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
