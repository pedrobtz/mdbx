# A worked example, end to end

``` r

library(mdbx)
```

[Getting started](https://pedrobtz.github.io/mdbx/articles/mdbx.md)
introduces the pieces one at a time. This article builds one thing
instead: a registry of pipeline runs, where each run gets an id, a
record, and an entry in an index of runs by status. It is small enough
to read in one sitting and complete enough that every exported function
turns up in the place you would actually reach for it.

If you are looking for a single function rather than a shape, its help
page is the better read.

## Before you open anything

Two functions answer questions about the library rather than about any
database.
[`mdbx_version()`](https://pedrobtz.github.io/mdbx/reference/mdbx_version.md)
says which libmdbx is compiled into the package — worth quoting in a bug
report, since the binding and the engine are versioned separately.

``` r

mdbx_version()$describe
#> [1] "v0.14.3-0-g251562b2"
```

[`mdbx_limits()`](https://pedrobtz.github.io/mdbx/reference/mdbx_limits.md)
gives the hard bounds. The one that bites in practice is `keysize_max`:
keys are short by design, and a scheme that concatenates a few fields
together needs to know the ceiling before it meets it.

``` r

limits <- mdbx_limits()
limits[c("pagesize", "keysize_max", "valsize_max")]
#> $pagesize
#> [1] 4096
#> 
#> $keysize_max
#> [1] 2022
#> 
#> $valsize_max
#> [1] 2146435072
```

Both work without an environment open, which is the point of them.

## Opening the environment

An environment is the file. `max_dbs` is the ceiling on named databases,
set here only to show where it goes: this registry wants two, unused
slots cost nothing, and the default of 16 suits most uses.

``` r

path <- file.path(tempdir(), "runs.mdbx")
env <- mdbx_env_open(path, max_dbs = 4)
env
#> <mdbx_env> /tmp/RtmpmrohJZ/runs.mdbx 
#>   access: read-write 
#>   layout: single file 
#>   status: open
```

[`mdbx_env_is_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_is_open.md)
is the question a cleanup path asks — it is `TRUE` until something
closes the handle, and never errors.

``` r

mdbx_env_is_open(env)
#> [1] TRUE
```

## One writer function, two databases

Each run needs an id nobody else will take.
[`mdbx_dbi_sequence()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_sequence.md)
is a counter stored in the database and bumped inside the transaction
that uses it, so two processes racing to add a run cannot land on the
same number. It returns the value *before* the increment.

[`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_open.md)
resolves a name to a handle. Resolve it inside the transaction you are
going to use it in and let it go afterwards: an aborted transaction
poisons the handle it created, so one cached in a global would
eventually be a handle to nothing.

``` r

new_run <- function(env, script, status) {
  mdbx_with_write(env, function(txn) {
    runs <- mdbx_dbi_open(txn, "runs", create = TRUE)
    by_status <- mdbx_dbi_open(txn, "by_status", create = TRUE)

    id <- mdbx_dbi_sequence(txn, runs, increment = 1)
    key <- sprintf("run-%04d", id + 1)

    record <- list(script = script, status = status, at = "2026-09-16")
    mdbx_put(txn, key, serialize(record, NULL), db = runs)
    mdbx_put(txn, paste0(status, "/", key), key, db = by_status)

    key
  })
}

for (run in list(c("ingest.R", "done"), c("clean.R", "done"),
                 c("model.R", "failed"))) {
  new_run(env, run[[1]], run[[2]])
}
```

[`mdbx_with_write()`](https://pedrobtz.github.io/mdbx/reference/mdbx_with_write.md)
commits when the block returns and aborts if it throws, so the record
and its index entry are added together or not at all. That is the whole
reason both writes live in one function.

[`mdbx_dbi_list()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_list.md)
names the databases that exist. The unnamed main database is always
there and is never listed.

``` r

mdbx_with_read(env, function(txn) mdbx_dbi_list(txn))
#> [1] "by_status" "runs"
```

## Reading a record back

[`mdbx_get()`](https://pedrobtz.github.io/mdbx/reference/mdbx_get.md)
returns text by default. These values are not text — they are
[`serialize()`](https://rdrr.io/r/base/serialize.html) output — so they
have to be asked for as bytes.

``` r

mdbx_with_read(env, function(txn) {
  runs <- mdbx_dbi_open(txn, "runs")
  unserialize(mdbx_get(txn, "run-0003", as = "raw", db = runs))
})
#> $script
#> [1] "model.R"
#> 
#> $status
#> [1] "failed"
#> 
#> $at
#> [1] "2026-09-16"
```

A key that is not there reads as `NULL`, which is distinct from a stored
empty value. Pass `default =` when a missing key has an obvious answer;
whatever you pass comes back as given, undecoded.

``` r

mdbx_with_read(env, function(txn) {
  runs <- mdbx_dbi_open(txn, "runs")
  mdbx_get(txn, "run-9999", default = "no such run", db = runs)
})
#> [1] "no such run"
```

[`mdbx_put()`](https://pedrobtz.github.io/mdbx/reference/mdbx_put.md)
overwrites by default. With `overwrite = FALSE` it refuses instead and
returns `FALSE`, which is how you write “claim this id if nobody has”
without a read first — the check and the write are one operation, so
nothing can slip between them.

``` r

claimed <- mdbx_with_write(env, function(txn) {
  mdbx_put(txn, "run-0001", "clobber", overwrite = FALSE,
           db = mdbx_dbi_open(txn, "runs"))
})
claimed
#> [1] FALSE
```

## Listing what is there

[`mdbx_keys()`](https://pedrobtz.github.io/mdbx/reference/mdbx_keys.md)
walks in key order. `start` seeks to a position and `limit` bounds what
comes back, which together are how you page through more records than
you want in memory at once.

``` r

mdbx_with_read(env, function(txn) {
  mdbx_keys(txn, db = mdbx_dbi_open(txn, "by_status"), limit = 10)
})
#> [1] "done/run-0001"   "done/run-0002"   "failed/run-0003"
```

`start` is a seek, not a filter: it says where to begin, and the scan
carries on past the prefix you had in mind. Prefixes are a property of
the ordering, so the filtering is yours to do.

``` r

mdbx_with_read(env, function(txn) {
  keys <- mdbx_keys(txn, db = mdbx_dbi_open(txn, "by_status"), start = "done/")
  keys[startsWith(keys, "done/")]
})
#> [1] "done/run-0001" "done/run-0002"
```

`reverse = TRUE` walks from the end, which with a sortable key scheme is
how you get the most recent record without reading the rest.

``` r

mdbx_with_read(env, function(txn) {
  mdbx_keys(txn, db = mdbx_dbi_open(txn, "runs"), reverse = TRUE, limit = 1)
})
#> [1] "run-0003"
```

[`mdbx_items()`](https://pedrobtz.github.io/mdbx/reference/mdbx_items.md)
returns keys and values together in one crossing into C. Here the keys
are text and the values are not, which is what the separate `keys_as`
argument is for.

``` r

items <- mdbx_with_read(env, function(txn) {
  mdbx_items(txn, db = mdbx_dbi_open(txn, "runs"), as = "raw",
             keys_as = "character", limit = 2)
})
items$keys
#> [1] "run-0001" "run-0002"
unserialize(items$values[[1]])
#> $script
#> [1] "ingest.R"
#> 
#> $status
#> [1] "done"
#> 
#> $at
#> [1] "2026-09-16"
```

A scan given no `limit` refuses to run past `mdbx_scan_max` rather than
quietly materializing a database that does not fit in memory. Pass a
`limit`, or `limit = Inf` to say you meant it.

``` r

mdbx_scan_max
#> [1] 1e+06
```

## Removing a run

[`mdbx_del()`](https://pedrobtz.github.io/mdbx/reference/mdbx_del.md)
takes the key. Removing a run means removing its index entry too, and
again both belong in one transaction.

``` r

mdbx_with_write(env, function(txn) {
  mdbx_del(txn, "failed/run-0003", db = mdbx_dbi_open(txn, "by_status"))
})

mdbx_with_read(env, function(txn) {
  mdbx_keys(txn, db = mdbx_dbi_open(txn, "by_status"))
})
#> [1] "done/run-0001" "done/run-0002"
```

## Driving a transaction by hand

A
[`mdbx_with_write()`](https://pedrobtz.github.io/mdbx/reference/mdbx_with_write.md)
block always commits when it returns, so it cannot express “decide at
the end whether to keep this”.
[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md),
[`mdbx_txn_commit()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_commit.md)
and
[`mdbx_txn_abort()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_abort.md)
give you that control — and everything written in the transaction is
kept or discarded as one unit.

``` r

txn <- mdbx_txn_begin(env, write = TRUE)
runs <- mdbx_dbi_open(txn, "runs")

mdbx_put(txn, "run-0004", serialize(list(script = "report.R"), NULL), db = runs)
mdbx_put(txn, "latest", "run-0004", db = runs)

# Both writes stand or fall together, on a condition only visible in here.
if (is.null(mdbx_get(txn, "licence", db = runs))) {
  mdbx_txn_abort(txn)
} else {
  mdbx_txn_commit(txn)
}
```

[`mdbx_txn_state()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_state.md)
says how it ended, and works on a transaction that has already finished
— which is what makes it safe to ask in a cleanup handler that does not
know what happened.

``` r

mdbx_txn_state(txn)
#> [1] "aborted"

# Neither write landed.
mdbx_with_read(env, function(txn) {
  mdbx_get(txn, "latest", db = mdbx_dbi_open(txn, "runs"))
})
#> NULL
```

The `with_*` helpers are exactly these calls plus
[`on.exit()`](https://rdrr.io/r/base/on.exit.html). Aborting is
idempotent, so `on.exit(mdbx_txn_abort(txn))` alongside an explicit
commit is safe rather than a double-end.

## Backfilling in bulk, and durability

Every commit is fully durable by default: a crash at any moment leaves
the database intact. Loading history into the registry is the case where
trading some of that away earns its keep.

[`mdbx_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_flags.md)
is the vocabulary — every flag libmdbx takes, which scope accepts it,
and whether it can be changed on an environment that is already open.
Flags pass by name rather than through a curated enum, so anything
libmdbx grows is available the day the vendored library is bumped.

``` r

head(mdbx_flags(), 4)
#>             flag scope settable runtime
#> 1 UTTERLY_NOSYNC   env     TRUE    TRUE
#> 2    SAFE_NOSYNC   env     TRUE    TRUE
#> 3     NOMETASYNC   env     TRUE    TRUE
#> 4       WRITEMAP   env     TRUE   FALSE
```

Three places set them: `mdbx_env_open(flags = )` at open,
`mdbx_txn_begin(flags = )` for one transaction, and
[`mdbx_env_set_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_set_flags.md)
on an environment in hand.
[`mdbx_env_get_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_get_flags.md)
reports what is set now — `NOSUBDIR` is here because this environment is
a single file rather than a directory.

``` r

mdbx_env_get_flags(env)
#> [1] "NOSUBDIR"
```

`SAFE_NOSYNC` stops each commit waiting for the disk. Recent
transactions can be lost to a crash; the database cannot be corrupted.

``` r

mdbx_env_set_flags(env, "SAFE_NOSYNC")
mdbx_env_get_flags(env)
#> [1] "SAFE_NOSYNC" "NOMETASYNC"  "NOSUBDIR"

mdbx_with_write(env, function(txn) {
  runs <- mdbx_dbi_open(txn, "runs")
  for (i in 5:104) {
    mdbx_put(txn, sprintf("run-%04d", i), serialize(list(id = i), NULL), db = runs)
  }
})
```

Note that setting `SAFE_NOSYNC` brought `NOMETASYNC` with it — it
implies the weaker flag, and clearing one does not clear the other.
[`mdbx_env_get_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_get_flags.md)
is how you find that out rather than assume it.

Nothing above is on disk yet, so make it so, and put the environment
back.

``` r

mdbx_env_sync(env)
mdbx_env_set_flags(env, c("SAFE_NOSYNC", "NOMETASYNC"), on = FALSE)
mdbx_env_get_flags(env)
#> [1] "NOSUBDIR"
```

**Measure before reaching for any of this.** What these flags remove is
the cost of a *commit*, not of a write. On the vendored library, 2000
single-write transactions ran 89× faster under `SAFE_NOSYNC`, while one
transaction of 200,000 writes ran 1.1× faster — the backfill above is
the second shape, and pays the flush once either way. Batching writes
into fewer transactions is usually the same win at no risk.

The three flags are not equally dangerous. `NOMETASYNC` and
`SAFE_NOSYNC` can lose recent transactions to a crash but never corrupt
the database. `UTTERLY_NOSYNC` can corrupt it beyond recovery, and
exists for data you are prepared to regenerate.
[`?mdbx_flags`](https://pedrobtz.github.io/mdbx/reference/mdbx_flags.md)
sets out what each one costs.

## Looking at what you have

[`mdbx_env_stat()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_stat.md)
on the environment covers the whole file.

``` r

mdbx_env_stat(env)[c("entries", "depth", "leaf_pages", "pagesize")]
#> $entries
#> [1] 107
#> 
#> $depth
#> [1] 4
#> 
#> $leaf_pages
#> [1] 5
#> 
#> $pagesize
#> [1] 4096
```

Given a transaction and a database it reports that one instead, which is
how you find out that an index has grown out of proportion to what it
indexes.

``` r

mdbx_with_read(env, function(txn) {
  mdbx_env_stat(txn, db = mdbx_dbi_open(txn, "runs"))
})[c("entries", "depth", "leaf_pages")]
#> $entries
#> [1] 103
#> 
#> $depth
#> [1] 2
#> 
#> $leaf_pages
#> [1] 3
```

[`mdbx_env_info()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_info.md)
is about the file rather than the records in it: how large the map may
grow, how much of it is in use, and how many readers are registered.

``` r

mdbx_env_info(env)[c("geo_current", "mapsize", "numreaders", "maxreaders")]
#> $geo_current
#> [1] 65536
#> 
#> $mapsize
#> [1] 22548578304
#> 
#> $numreaders
#> [1] 1
#> 
#> $maxreaders
#> [1] 110
```

## Maintenance and shutdown

A reader slot belongs to a process, and a process that dies mid-read
leaves its slot occupied. That stale slot holds back reclamation of the
pages its snapshot referred to, so a long-lived writer eventually grows
the file for no reason.
[`mdbx_env_reader_check()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_reader_check.md)
releases the slots whose owners are gone and returns how many it found.

``` r

stale <- mdbx_env_reader_check(env)
stale
#> [1] 0
```

[`mdbx_dbi_drop()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_drop.md)
empties a database. With `delete = TRUE` it removes the name as well and
frees the slot reserved by `max_dbs`.

``` r

mdbx_with_write(env, function(txn) {
  mdbx_dbi_drop(txn, mdbx_dbi_open(txn, "by_status"), delete = TRUE)
})

mdbx_with_read(env, function(txn) mdbx_dbi_list(txn))
#> [1] "runs"
```

Closing is the last step, and it refuses while a transaction is open
rather than pulling the file out from under it. Handles are also cleaned
up by the garbage collector, but closing explicitly is what makes it
timely.

``` r

mdbx_env_close(env)
mdbx_env_is_open(env)
#> [1] FALSE
```

## Things worth knowing

The walkthrough above works because of a few rules it never had to bump
into.

**One transaction at a time per environment.** libmdbx binds a
transaction to the thread that started it, and R is single-threaded.
Beginning a second is an error, never a hang. Concurrency comes from
separate processes: many readers and one writer, with readers never
blocking writers.

**An environment does not survive `fork()`.** Under
[`parallel::mclapply()`](https://rdrr.io/r/parallel/mclapply.html) and
anything else that forks, open the environment *inside* the worker.
Using an inherited one is an error naming the fork rather than a crash.
`?mdbx-concurrency` sets out the whole contract.

**A character key is its UTF-8 bytes**, normalized first, so the same
text is the same key whatever encoding the string carried. `"k"` and
`charToRaw("k")` are one key, not two. Only a `raw` key can contain a
NUL byte.

**`NULL` means absent, and nothing else does.** A stored empty value
reads back as `""` or `raw(0)`, so a key that is there with nothing in
it never looks like a key that is missing.

**[`mdbx_env_close()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_close.md)
refuses while a transaction is open**, because closing underneath one is
undefined behaviour in libmdbx. The `with_*` helpers cannot leave one
open, which is the main reason to prefer them.

## Where each function appeared

| Section | Functions |
|----|----|
| Before you open anything | [`mdbx_version()`](https://pedrobtz.github.io/mdbx/reference/mdbx_version.md), [`mdbx_limits()`](https://pedrobtz.github.io/mdbx/reference/mdbx_limits.md) |
| Opening the environment | [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md), [`mdbx_env_is_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_is_open.md) |
| One writer function, two databases | [`mdbx_with_write()`](https://pedrobtz.github.io/mdbx/reference/mdbx_with_write.md), [`mdbx_dbi_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_open.md), [`mdbx_dbi_sequence()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_sequence.md), [`mdbx_put()`](https://pedrobtz.github.io/mdbx/reference/mdbx_put.md), [`mdbx_dbi_list()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_list.md) |
| Reading a record back | [`mdbx_with_read()`](https://pedrobtz.github.io/mdbx/reference/mdbx_with_write.md), [`mdbx_get()`](https://pedrobtz.github.io/mdbx/reference/mdbx_get.md) |
| Listing what is there | [`mdbx_keys()`](https://pedrobtz.github.io/mdbx/reference/mdbx_keys.md), [`mdbx_items()`](https://pedrobtz.github.io/mdbx/reference/mdbx_items.md), `mdbx_scan_max` |
| Removing a run | [`mdbx_del()`](https://pedrobtz.github.io/mdbx/reference/mdbx_del.md) |
| Driving a transaction by hand | [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md), [`mdbx_txn_commit()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_commit.md), [`mdbx_txn_abort()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_abort.md), [`mdbx_txn_state()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_state.md) |
| Backfilling in bulk | [`mdbx_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_flags.md), [`mdbx_env_get_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_get_flags.md), [`mdbx_env_set_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_set_flags.md), [`mdbx_env_sync()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_sync.md) |
| Looking at what you have | [`mdbx_env_stat()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_stat.md), [`mdbx_env_info()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_info.md) |
| Maintenance and shutdown | [`mdbx_env_reader_check()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_reader_check.md), [`mdbx_dbi_drop()`](https://pedrobtz.github.io/mdbx/reference/mdbx_dbi_drop.md), [`mdbx_env_close()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_close.md) |

That is the whole exported surface. What is not here is not implemented
yet: cursors, batch entry points, duplicate keys, and anything that
serializes an R object for you.
