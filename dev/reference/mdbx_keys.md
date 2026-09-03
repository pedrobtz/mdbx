# List the keys in a database

Walks the whole database in key order and returns its keys.

## Usage

``` r
mdbx_keys(
  txn,
  limit = NULL,
  as = c("character", "raw"),
  db = NULL,
  start = NULL,
  reverse = FALSE
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

  `"character"` (the default) to decode keys as UTF-8 text, or `"raw"`
  to get a list of raw vectors. As with
  [`mdbx_get()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_get.md),
  decoding fails rather than corrupting anything if a key is not valid
  UTF-8 text.

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

## Value

A character vector, or a list of raw vectors if `as = "raw"`. Empty
(`character(0)` or [`list()`](https://rdrr.io/r/base/list.html)) if the
database has no records.

## Details

Everything is materialized in memory at once, so on a large database
this can be expensive. A scan with no `limit` therefore refuses to run
when the database holds more than
[mdbx_scan_max](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_scan_max.md)
records; pass an explicit `limit` — or `limit = Inf` — to go ahead
anyway.
[`mdbx_env_stat()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_stat.md)`$entries`
tells you how many there are before you ask.

## See also

[`mdbx_items()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_items.md),
[`mdbx_get()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_get.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

mdbx_with_write(env, function(txn) {
  mdbx_put(txn, "b", "2")
  mdbx_put(txn, "a", "1")
  mdbx_put(txn, "c", "3")
})

# Always in key order, whatever order they were written in.
mdbx_with_read(env, function(txn) mdbx_keys(txn))
#> [1] "a" "b" "c"

mdbx_with_read(env, function(txn) mdbx_keys(txn, limit = 2))
#> [1] "a" "b"

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
