# Read a value

Looks up `key` in the transaction's snapshot.

## Usage

``` r
mdbx_get(txn, key, default = NULL, as = c("character", "raw"), db = NULL)
```

## Arguments

- txn:

  An `mdbx_txn` object, from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md).

- key:

  A raw vector, or a single string, which is stored as its UTF-8 bytes.
  The two are interchangeable: `"k"` and `charToRaw("k")` name the same
  key. Only raw can express a key containing a NUL byte.

- default:

  Value returned when `key` is absent. It is returned exactly as given,
  and is never decoded, whatever `as` is set to.

- as:

  `"character"` (the default) to decode the stored bytes as UTF-8 text,
  or `"raw"` to return them untouched. Decoding fails, rather than
  returning something corrupt, if the value contains a NUL byte or is
  not valid UTF-8 — which is what any non-text value will do.

- db:

  An `mdbx_dbi` object from
  [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_dbi_open.md)
  naming a database to address instead of the unnamed main one, or
  `NULL` for the main database.

## Value

A length-1 character vector — or a raw vector if `as = "raw"` — or
`default` if the key is not present.

## Details

A key that is not present returns `default` (`NULL` unless you say
otherwise). That is unambiguous: a *stored* zero-length value comes back
as `raw(0)`, which is not `NULL`, so absence and emptiness stay
distinguishable.

By default the stored bytes are decoded as UTF-8 text, so a value
written as a string comes back as one. MDBX records no type, so this is
an assumption rather than something the database knows: **pass
`as = "raw"` for any value that is not text**, including anything
written with [`serialize()`](https://rdrr.io/r/base/serialize.html).
Decoding raises an error rather than returning something corrupt when
the bytes are not valid UTF-8 text, so a wrong assumption is never
silent.

The returned vector is a copy. 'libmdbx' hands out memory owned by the
database, valid only until the transaction ends, so nothing here points
into the memory map.

## See also

[`mdbx_put()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_put.md),
[`mdbx_del()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_del.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

mdbx_with_write(env, function(txn) {
  mdbx_put(txn, "answer", "42")
})

# Decoded as text by default.
mdbx_with_read(env, function(txn) {
  mdbx_get(txn, "answer")
})
#> [1] "42"

# Anything that is not text needs as = "raw".
mdbx_with_read(env, function(txn) {
  mdbx_get(txn, "answer", as = "raw")
})
#> [1] 34 32

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
