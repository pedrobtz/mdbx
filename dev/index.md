# mdbx

R bindings to [libmdbx](https://libmdbx.dqdkfa.ru/), a compact and fast
transactional key-value store built on memory-mapped files.

- **ACID transactions.** Writes are all-or-nothing, and readers see a
  consistent snapshot.
- **No server, no connection.** A database is a file; opening it is a
  function call.
- **Safe across processes.** Many readers and one writer, with readers
  never blocking writers.
- **Nothing to install.** The libmdbx sources are bundled and compiled
  into the package.

## Installation

mdbx is not on CRAN yet. Install the development version from
[GitHub](https://github.com/pedrobtz/mdbx) with:

``` r

# install.packages("pak")
pak::pak("pedrobtz/mdbx")
```

## Usage

Data lives in an *environment* (a file on disk), and every read or write
happens inside a *transaction*.
[`mdbx_with_read()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_with_write.md)
and
[`mdbx_with_write()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_with_write.md)
open one, run your code, and end it — committing if the block returns,
aborting if it throws.

Keys and values are bytes. Pass a string and it is stored as its UTF-8
bytes, or pass a `raw` vector for full control — `"k"` and
`charToRaw("k")` are the same key. Reads decode back to text by default.
MDBX records no type, so that is an assumption rather than something it
knows: pass `as = "raw"` for anything that is not text, such as a value
written with [`serialize()`](https://rdrr.io/r/base/serialize.html). A
wrong assumption is an error, never a corrupt string.

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

[`mdbx_keys()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_keys.md)
and
[`mdbx_items()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_items.md)
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

A
[`mdbx_with_write()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_with_write.md)
block always commits when it returns, so it cannot express “decide at
the end whether to keep this”.
[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md),
[`mdbx_txn_commit()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_commit.md)
and
[`mdbx_txn_abort()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_abort.md)
give you that control — and everything written in the transaction is
kept or discarded as one unit.

``` r

env <- mdbx_env_open(tempfile(fileext = ".mdbx"))

txn <- mdbx_txn_begin(env, write = TRUE)

mdbx_put(txn, "seen", "1")
mdbx_put(txn, "count", "7")

# Both writes stand or fall together, on a condition only visible in here.
if (is.null(mdbx_get(txn, "licence"))) {
  mdbx_txn_abort(txn)
} else {
  mdbx_txn_commit(txn)
}

mdbx_txn_state(txn)
#> [1] "aborted"

# Neither write landed.
mdbx_with_read(env, function(txn) mdbx_get(txn, "count"))
#> NULL

mdbx_env_close(env)
```

The `with_*` helpers are exactly these calls plus
[`on.exit()`](https://rdrr.io/r/base/on.exit.html). Aborting is
idempotent, so `on.exit(mdbx_txn_abort(txn))` alongside an explicit
commit is safe rather than a double-end.

### Durability

Every commit is fully durable by default: a crash at any moment leaves
the database intact.
[`mdbx_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_flags.md)
lists the libmdbx flags that trade that away, and
`mdbx_env_open(flags = )`, `mdbx_txn_begin(flags = )` and
[`mdbx_env_set_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_set_flags.md)
set them.

``` r

mdbx_flags()[1:3, ]
#>             flag scope settable runtime
#> 1 UTTERLY_NOSYNC   env     TRUE    TRUE
#> 2    SAFE_NOSYNC   env     TRUE    TRUE
#> 3     NOMETASYNC   env     TRUE    TRUE

env <- mdbx_env_open(tempfile(fileext = ".mdbx"), flags = "SAFE_NOSYNC")

mdbx_with_write(env, function(txn) mdbx_put(txn, "k", "v"))

# Nothing was flushed on commit, so this is what makes it durable.
mdbx_env_sync(env)

mdbx_env_close(env)
```

**Measure before reaching for these.** What they remove is the cost of a
*commit*, not of a write. On the vendored library, 2000 single-write
transactions ran 89× faster under `SAFE_NOSYNC`, while one transaction
of 200,000 writes ran 1.1× faster. Batching writes into fewer
transactions is usually the same win at no risk.

`NOMETASYNC` and `SAFE_NOSYNC` can lose recent transactions to a crash
but never corrupt the database. `UTTERLY_NOSYNC` can corrupt it beyond
recovery, and exists for data you are prepared to regenerate.
[`?mdbx_flags`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_flags.md)
sets out what each one costs.

## Things worth knowing

- **One transaction at a time per environment.** libmdbx binds a
  transaction to the thread that started it, and R is single-threaded.
  Beginning a second is an error, never a hang. Concurrency comes from
  separate processes: many readers and one writer, with readers never
  blocking writers.
- **An environment does not survive `fork()`.** Under
  [`parallel::mclapply()`](https://rdrr.io/r/parallel/mclapply.html) and
  anything else that forks, open the environment *inside* the worker;
  using an inherited one is an error naming the fork rather than a
  crash. `?mdbx-concurrency` sets out the whole contract.
- **`NULL` means absent.** A stored empty value reads back as `""` (or
  `raw(0)`), never as `NULL`, so the two never blur. Pass `default =` to
  [`mdbx_get()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_get.md)
  if you want something else — it is returned as given, never decoded.
- **A character key is its UTF-8 bytes**, normalized first, so the same
  text is the same key whatever encoding the string carried. Only a
  `raw` key can contain a NUL byte.
- **[`mdbx_env_close()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_close.md)
  refuses while a transaction is open**, because closing underneath one
  is undefined behaviour in libmdbx. The `with_*` helpers cannot leave
  one open.
- Environments and transactions are also cleaned up by the garbage
  collector, but closing explicitly is what makes it timely.

## Documentation

- [Getting
  started](https://pedrobtz.github.io/mdbx/dev/articles/mdbx.html) — a
  longer tour of the same ground, plus batching, bulk loads and the
  patterns that matter in practice.
- [Designing a disk
  cache](https://pedrobtz.github.io/mdbx/dev/articles/cache.html) — how
  the SQLite-shaped parts of a cache map onto ordered keys and named
  databases.
- `?mdbx-package` for an overview, `?mdbx-concurrency` for the threading
  and `fork()` contract, and
  [`?mdbx_flags`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_flags.md)
  for durability.

## Status

Under development, and the API may still change. Working today:
environments, transactions, raw and text get/put/delete, named databases
with per-database statistics, ordered and resumable key and item
listing, sequences, statistics and limits, environment and transaction
flags including the durability modes, and the cross-process and `fork()`
safety described above.

Not implemented yet: a low-level cursor API, batch entry points
(`mdbx_get_many()` and friends), duplicate keys (`DUPSORT`), and
anything that serializes R objects for you. Those are the 0.2 scope.
