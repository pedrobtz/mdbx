# Getting started with mdbx

``` r

library(mdbx)
```

`mdbx` is a thin binding to [libmdbx](https://libmdbx.dqdkfa.ru/), an
embedded transactional key-value store. It is not a database server:
there is no process to start and no connection to make, just a file on
disk that one or more processes map into memory.

This article covers the patterns that matter in practice. For the
reference documentation of any single function, see its help page.

## Environments and transactions

Data lives in an **environment** — a file, opened with
[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md).

``` r

path <- file.path(tempdir(), "notes.mdbx")
env <- mdbx_env_open(path)
env
#> <mdbx_env> /tmp/RtmpqG8TAS/notes.mdbx 
#>   access: read-write 
#>   layout: single file 
#>   status: open
```

Every read and write happens inside a **transaction**.
[`mdbx_with_write()`](https://pedrobtz.github.io/mdbx/reference/mdbx_with_write.md)
opens one, runs your code, and commits if the block returns — or aborts
it if the block throws, leaving the database exactly as it was.

``` r

mdbx_with_write(env, function(txn) {
  mdbx_put(txn, "colour", "blue")
  mdbx_put(txn, "size", "large")
})

mdbx_with_read(env, function(txn) mdbx_get(txn, "colour"))
#> [1] "blue"
```

That all-or-nothing property is the main thing a transaction buys you.
If something fails part-way, nothing lands:

``` r

try(mdbx_with_write(env, function(txn) {
  mdbx_put(txn, "colour", "red")
  stop("changed my mind")
}))
#> Error in fun(txn) : changed my mind

# The write above was rolled back with the error.
mdbx_with_read(env, function(txn) mdbx_get(txn, "colour"))
#> [1] "blue"
```

When you need to decide at the end whether to keep the writes, drive the
transaction yourself with
[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md):

``` r

txn <- mdbx_txn_begin(env, write = TRUE)
mdbx_put(txn, "draft", "unfinished")

if (nchar(mdbx_get(txn, "draft")) < 20) {
  mdbx_txn_abort(txn)
} else {
  mdbx_txn_commit(txn)
}

mdbx_txn_state(txn)
#> [1] "aborted"
```

Aborting is idempotent, so `on.exit(mdbx_txn_abort(txn))` alongside an
explicit commit is a safe belt-and-braces pattern rather than a
double-end.

## Keys and values are bytes

libmdbx stores byte strings and records no type. A single string is
stored as its UTF-8 bytes, so `"k"` and `charToRaw("k")` are the same
key. Reads decode back to text by default.

``` r

mdbx_with_write(env, function(txn) mdbx_put(txn, "ключ", "значение"))
mdbx_with_read(env, function(txn) mdbx_get(txn, "ключ"))
#> [1] "значение"
```

Because no type is recorded, decoding is an assumption — but never a
silent one. Anything that is not valid UTF-8 text raises an error naming
the fix rather than returning a mangled string:

``` r

blob <- serialize(list(retries = 3L), NULL)
mdbx_with_write(env, function(txn) mdbx_put(txn, "config", blob))

try(mdbx_with_read(env, function(txn) mdbx_get(txn, "config")))
#> Error : value is not text: it contains a NUL byte. Read it with as = "raw", and unserialize() it if it was written with serialize()
```

`as = "raw"` gives you the exact bytes back:

``` r

mdbx_with_read(env, function(txn) {
  unserialize(mdbx_get(txn, "config", as = "raw"))
})
#> $retries
#> [1] 3
```

This is why serialization is deliberately left out of the package:
[`serialize()`](https://rdrr.io/r/base/serialize.html) is one choice,
but so are JSON, Arrow, and a domain-specific encoding. Pick your own
and store the bytes.

A key that is not there reads as `NULL`, and a stored empty value reads
as `""` — the two never blur.

``` r

mdbx_with_read(env, function(txn) mdbx_get(txn, "absent"))
#> NULL

mdbx_with_write(env, function(txn) mdbx_put(txn, "blank", ""))
mdbx_with_read(env, function(txn) mdbx_get(txn, "blank"))
#> [1] ""
```

Pass `default =` when a missing key should read as something else. It is
returned exactly as given, never decoded.

``` r

mdbx_with_read(env, function(txn) mdbx_get(txn, "absent", default = NA))
#> [1] NA
```

## Listing what is there

``` r

mdbx_with_read(env, function(txn) mdbx_keys(txn))
#> [1] "blank"  "colour" "config" "size"   "ключ"
```

Keys come back in **key order** — libmdbx’s byte order — not insertion
order.
[`mdbx_items()`](https://pedrobtz.github.io/mdbx/reference/mdbx_items.md)
returns keys and values together in a single pass, which is cheaper than
a key list plus a
[`mdbx_get()`](https://pedrobtz.github.io/mdbx/reference/mdbx_get.md)
per key.

``` r

items <- mdbx_with_read(env, function(txn) {
  mdbx_items(txn, limit = 3, as = "raw")
})
names(items)
#> [1] "keys"   "values"
vapply(items$keys, rawToChar, character(1))
#> [1] "blank"  "colour" "config"
```

Both materialize everything in memory, so an unbounded scan of a
database with more than `mdbx_scan_max` records is refused rather than
attempted. Pass an explicit `limit`, or `limit = Inf` to mean it.

``` r

mdbx_scan_max
#> [1] 1e+06
```

## Batch your writes

This is the single most valuable performance habit, and it is worth
showing rather than asserting. The cost of a durable commit is paid *per
transaction*, not per write:

``` r

words <- sprintf("word-%04d", 1:200)

per_txn <- system.time(
  for (w in words) mdbx_with_write(env, function(txn) mdbx_put(txn, w, "1"))
)[["elapsed"]]

one_txn <- system.time(
  mdbx_with_write(env, function(txn) {
    for (w in words) mdbx_put(txn, w, "2")
  })
)[["elapsed"]]

c(per_transaction = per_txn, single_transaction = one_txn)
#>    per_transaction single_transaction 
#>              0.053              0.004
```

Each commit flushes to disk, so the gap is really a count of `fsync`
calls. How big it gets depends entirely on the filesystem and hardware —
the ratio above is whatever the machine that built this page managed,
and on storage where a durable flush is expensive it is commonly a
hundredfold or more.

Either way the advice is the same, and it costs nothing: group related
writes into one transaction. It is faster *and* it makes them atomic.

The same idea applies to reads, though less dramatically: prefer one
[`mdbx_items()`](https://pedrobtz.github.io/mdbx/reference/mdbx_items.md)
over a loop of
[`mdbx_get()`](https://pedrobtz.github.io/mdbx/reference/mdbx_get.md)
calls, because each call crosses the R/C boundary.

## Durability

Every commit is fully durable by default: a crash at any moment leaves
the database intact.
[`mdbx_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_flags.md)
lists the flags that trade that away.

``` r

flags <- mdbx_flags()
flags[flags$scope == "env" & flags$settable, c("flag", "runtime")]
#>              flag runtime
#> 1  UTTERLY_NOSYNC    TRUE
#> 2     SAFE_NOSYNC    TRUE
#> 3      NOMETASYNC    TRUE
#> 4        WRITEMAP   FALSE
#> 5     LIFORECLAIM    TRUE
#> 6       NORDAHEAD   FALSE
#> 7       NOMEMINIT    TRUE
#> 8       EXCLUSIVE   FALSE
#> 9          ACCEDE   FALSE
#> 10     VALIDATION   FALSE
```

`"NOMETASYNC"` and `"SAFE_NOSYNC"` can lose recent transactions to a
system crash but cannot corrupt the database. `"UTTERLY_NOSYNC"` can
corrupt it beyond recovery, and is for data you are prepared to
regenerate.

Reach for these only after batching, and measure. Relaxing durability
speeds up *commits*; if you have already reduced the number of commits,
there is little left to win. A typical use is a bulk load:

``` r

bulk <- mdbx_env_open(file.path(tempdir(), "bulk.mdbx"), flags = "SAFE_NOSYNC")

mdbx_with_write(bulk, function(txn) {
  for (i in 1:1000) mdbx_put(txn, sprintf("row-%04d", i), "x")
})

# Nothing was flushed on commit, so make it durable explicitly.
mdbx_env_sync(bulk)
mdbx_env_close(bulk)
```

A single transaction can relax durability for itself alone, leaving the
environment’s own setting untouched:

``` r

txn <- mdbx_txn_begin(env, write = TRUE, flags = "NOSYNC")
mdbx_put(txn, "scratch", "1")
mdbx_txn_commit(txn)
```

## Concurrency

An environment supports **one transaction at a time**: libmdbx binds a
transaction to the thread that began it, and R is single-threaded.
Beginning a second is a clean error, never a hang.

``` r

txn <- mdbx_txn_begin(env)
try(mdbx_txn_begin(env))
#> Error : this mdbx environment already has an open transaction; commit or abort it before beginning another (libmdbx allows one transaction per environment per thread)
mdbx_txn_abort(txn)
```

Concurrency comes from **separate processes**: many readers and one
writer, with readers never blocking writers. A reader holds the snapshot
that existed when it began, even as another process commits over it.

An environment does not survive a `fork()`, so under
[`parallel::mclapply()`](https://rdrr.io/r/parallel/mclapply.html) and
anything else that forks, open the environment *inside* the worker:

``` r

mdbx_env_close(env)

results <- parallel::mclapply(c("colour", "size"), function(key) {
  worker <- mdbx_env_open(path)
  on.exit(mdbx_env_close(worker))
  mdbx_with_read(worker, function(txn) mdbx_get(txn, key))
}, mc.cores = 1)

unlist(results)
#> [1] "blue"  "large"
```

Using an inherited one is an error naming the fork rather than a crash.
See
[`?"mdbx-concurrency"`](https://pedrobtz.github.io/mdbx/reference/mdbx-concurrency.md)
for the whole contract.

## Inspecting a database

``` r

env <- mdbx_env_open(path)

stat <- mdbx_env_stat(env)
stat[c("entries", "depth", "pagesize")]
#> $entries
#> [1] 206
#> 
#> $depth
#> [1] 2
#> 
#> $pagesize
#> [1] 4096

info <- mdbx_env_info(env)
info[c("geo_current", "geo_upper", "numreaders")]
#> $geo_current
#> [1] 65536
#> 
#> $geo_upper
#> [1] 22548578304
#> 
#> $numreaders
#> [1] 1
```

`map_size` in
[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md)
sets `geo_upper`, the ceiling the file may grow to. It costs nothing to
set generously — the map is virtual address space, not disk — and a
database that hits it raises `MDBX_MAP_FULL`.

[`mdbx_version()`](https://pedrobtz.github.io/mdbx/reference/mdbx_version.md)
reports the bundled library and how it was built.

``` r

mdbx_version()$describe
#> [1] "v0.14.3-0-g251562b2"
```

## Cleaning up

Environments are closed by the garbage collector eventually, but closing
explicitly is what makes it timely. Closing is refused while a
transaction is open, because closing underneath one is undefined
behaviour in libmdbx.

``` r

mdbx_env_close(env)
mdbx_env_is_open(env)
#> [1] FALSE
```

With the default single-file layout, a database is the path plus a
`-lck` companion.

``` r

unlink(c(path, paste0(path, "-lck")))
```
