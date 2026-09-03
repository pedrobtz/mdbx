# List the keys and values in a database

Walks the whole database in key order and returns both keys and values,
in one pass. Use
[`mdbx_keys()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_keys.md)
instead when you do not need the values — fetching them is the expensive
part.

## Usage

``` r
mdbx_items(
  txn,
  limit = NULL,
  as = c("character", "raw"),
  db = NULL,
  start = NULL,
  reverse = FALSE,
  keys_as = NULL
)
```

## Arguments

- txn:

  An `mdbx_txn` object, from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md).

- limit:

  Maximum number of records to return, in key order. `NULL`, the
  default, returns all of them, subject to the
  [mdbx_scan_max](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_scan_max.md)
  guard; `Inf` returns all of them unconditionally.

- as:

  `"character"` (the default) to decode values as UTF-8 text, or `"raw"`
  for a list of raw vectors. Decoding fails rather than corrupting
  anything, so a database holding
  [`serialize()`](https://rdrr.io/r/base/serialize.html) output needs
  `as = "raw"`. Governs keys too unless `keys_as` says otherwise.

- db:

  An `mdbx_dbi` object from
  [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_dbi_open.md)
  naming a database to address instead of the unnamed main one, or
  `NULL` for the main database.

- start:

  Begin at this key rather than at an end: the first key at or after it
  going forwards, or the last key at or before it going backwards. A raw
  vector or a single string, as for
  [`mdbx_get()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_get.md).

  `start` is *inclusive*, so a key that exists is returned rather than
  skipped. To walk a database in chunks, pass the last key of one call
  as the `start` of the next and drop the first record of the result —
  otherwise it repeats. `start` positions the cursor and nothing more:
  it does not bound how much comes back, so it does not exempt a scan
  from
  [mdbx_scan_max](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_scan_max.md).
  Pass `limit` for that.

- reverse:

  If `TRUE`, walk from the last key towards the first. `limit = 1` with
  `reverse = TRUE` is the largest key, which is otherwise only reachable
  by reading every key.

- keys_as:

  How to decode keys, when that differs from the values. An index
  typically has binary keys — an encoded timestamp or counter — and text
  values, which is `as = "character", keys_as = "raw"`.

## Value

A list with two parallel components, `keys` and `values`, each a
character vector or a list of raw vectors according to `as`.

## Details

The two components are parallel: `keys[[i]]` names `values[[i]]`. When
keys are text, `setNames(items$values, items$keys)` turns the result
into a lookup list.

The caution in
[`mdbx_keys()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_keys.md)
about materializing everything applies here with more force, since
values are usually larger than keys.

## See also

[`mdbx_keys()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_keys.md),
[`mdbx_get()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_get.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

mdbx_with_write(env, function(txn) {
  mdbx_put(txn, "a", "1")
  mdbx_put(txn, "b", "2")
})

items <- mdbx_with_read(env, function(txn) mdbx_items(txn))
items
#> $keys
#> [1] "a" "b"
#> 
#> $values
#> [1] "1" "2"
#> 

# A lookup list, when the keys are text.
stats::setNames(items$values, items$keys)
#>   a   b 
#> "1" "2" 

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
