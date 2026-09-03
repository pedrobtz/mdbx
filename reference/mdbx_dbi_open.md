# Open a named database

An environment holds an unnamed main database and, if `max_dbs` allows,
any number of named ones. Named databases are independent key spaces:
the same key may appear in several with different values, and
[`mdbx_keys()`](https://pedrobtz.github.io/mdbx/reference/mdbx_keys.md)
on one never sees another's.

## Usage

``` r
mdbx_dbi_open(txn, name, create = FALSE)
```

## Arguments

- txn:

  An `mdbx_txn` object, from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md).
  Creating a database needs a write transaction; opening an existing one
  does not.

- name:

  The database's name, a single string.

- create:

  If `TRUE`, create the database when it does not exist. If `FALSE`,
  opening a database that was never created is an error.

## Value

An `mdbx_dbi` object, to pass as the `db` argument of
[`mdbx_get()`](https://pedrobtz.github.io/mdbx/reference/mdbx_get.md),
[`mdbx_put()`](https://pedrobtz.github.io/mdbx/reference/mdbx_put.md),
[`mdbx_del()`](https://pedrobtz.github.io/mdbx/reference/mdbx_del.md),
[`mdbx_keys()`](https://pedrobtz.github.io/mdbx/reference/mdbx_keys.md)
and
[`mdbx_items()`](https://pedrobtz.github.io/mdbx/reference/mdbx_items.md).

## Details

The database is opened for the duration of this transaction and
re-resolved by name in later ones, so the returned handle stays usable
for the life of the environment — but only if the transaction that
created it **commits**. If it aborts, the database was never created and
the handle refers to nothing; using it then is an ordinary "not found"
error.

Reserve capacity with `max_dbs` in
[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md)
before opening any: the libmdbx default leaves no room for named
databases at all, and running out reports `MDBX_DBS_FULL`.

## See also

[`mdbx_dbi_drop()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_drop.md),
[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md)
for `max_dbs`

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path, max_dbs = 8)

mdbx_with_write(env, function(txn) {
  files <- mdbx_dbi_open(txn, "files", create = TRUE)
  metadata <- mdbx_dbi_open(txn, "metadata", create = TRUE)

  mdbx_put(txn, "abc", "/data/abc.parquet", db = files)
  mdbx_put(txn, "abc", '{"size":1234}', db = metadata)
})

# The same key, two databases, two values.
mdbx_with_read(env, function(txn) {
  c(files = mdbx_get(txn, "abc", db = mdbx_dbi_open(txn, "files")),
    metadata = mdbx_get(txn, "abc", db = mdbx_dbi_open(txn, "metadata")))
})
#>               files            metadata 
#> "/data/abc.parquet"   "{\"size\":1234}" 

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
