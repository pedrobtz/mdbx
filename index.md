# mdbx

R bindings to [libmdbx](https://libmdbx.dqdkfa.ru/), an embedded
transactional key-value store. The library is vendored and compiled into
the package, so there is no server to run and nothing to install beside
it.

A database is a single file. Keys and values are bytes, held in sorted
key order and optionally split across named databases within that one
file. Every read and write happens inside a transaction: commits are
ACID and fully durable by default, and a reader sees a consistent
snapshot without blocking the writer. Several processes can share a
database — many readers, one writer.

Three limits shape how it is used. An environment runs one transaction
at a time, because libmdbx binds a transaction to the thread that began
it and R is single-threaded. A handle does not survive `fork()`, so each
process opens its own. And storing bytes is where the package stops:
serializing R objects is left to you, as are cursors, duplicate keys and
batched calls, which are not implemented yet.

## Installation

mdbx is not on CRAN yet. Install the development version from
[GitHub](https://github.com/pedrobtz/mdbx) with:

``` r

# install.packages("pak")
pak::pak("pedrobtz/mdbx")
```

## Usage

Data lives in an *environment* (a file on disk, `.mdbx` by convention),
and every read or write happens inside a *transaction*:
[`mdbx_with_read()`](https://pedrobtz.github.io/mdbx/reference/mdbx_with_write.md)
and
[`mdbx_with_write()`](https://pedrobtz.github.io/mdbx/reference/mdbx_with_write.md)
open one, run your code, and commit if it returns or abort if it throws.
Keys and values are bytes: a string goes in as its UTF-8 bytes, so `"k"`
and `charToRaw("k")` are the same key. Reads decode back to text by
default, which MDBX cannot vouch for: pass `as = "raw"` for the rest; a
wrong guess errors, never corrupts.

``` r

library(mdbx)

path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

mdbx_with_write(env, function(txn) {
  mdbx_put(txn, "answer", "42")
  mdbx_put(txn, "config", serialize(list(retries = 3L), NULL))
})

mdbx_with_read(env, function(txn) {
  mdbx_get(txn, "answer")
})
#> [1] "42"

# Not text, so read the bytes and decode them yourself.
mdbx_with_read(env, function(txn) {
  unserialize(mdbx_get(txn, "config", as = "raw"))
})
#> $retries
#> [1] 3

# A key that is not there reads as NULL.
mdbx_with_read(env, function(txn) mdbx_get(txn, "missing"))
#> NULL

mdbx_env_close(env)
```

### Listing what is there

[`mdbx_keys()`](https://pedrobtz.github.io/mdbx/reference/mdbx_keys.md)
and
[`mdbx_items()`](https://pedrobtz.github.io/mdbx/reference/mdbx_items.md)
walk the database in key order, in a single crossing into C rather than
one per record.

``` r

env <- mdbx_env_open(tempfile(fileext = ".mdbx"))

mdbx_with_write(env, function(txn) {
  mdbx_put(txn, "banana", "2")
  mdbx_put(txn, "apple", "1")
})

mdbx_with_read(env, function(txn) mdbx_keys(txn))
#> [1] "apple"  "banana"

items <- mdbx_with_read(env, function(txn) mdbx_items(txn))
stats::setNames(items$values, items$keys)
#>  apple banana 
#>    "1"    "2"

mdbx_env_close(env)
```

Keys come back in key order, not insertion order. Both accept
`as = "raw"`, needed for keys or values that are not text, and both take
`limit` to bound the read. A scan with no `limit` refuses to run past
`mdbx_scan_max` (a million records) rather than quietly materializing
the lot — pass `limit = n`, or `limit = Inf` to mean it.

### Managing a transaction by hand

[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md),
[`mdbx_txn_commit()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_commit.md)
and
[`mdbx_txn_abort()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_abort.md)
drive a transaction directly, for when the decision to keep the writes
is only made at the end. The [worked
example](https://pedrobtz.github.io/mdbx/articles/workflow.html) shows
the pattern; the `with_*` helpers are those calls plus
[`on.exit()`](https://rdrr.io/r/base/on.exit.html).

## Testing

`testthat` covers the API, the `fork()` and cross-process contracts, and
panic recovery. Generated operation sequences are replayed against a
reference state model: valid calls must agree with it, forged handles
must be refused changing nothing, and injected faults must stay
recoverable. CI adds `R CMD check` on five OS/version legs, ASan/UBSan,
valgrind, LTO, gctorture, rchk and shuffled test order;
`tools/interop-check.sh` round-trips against an independently built
libmdbx.
