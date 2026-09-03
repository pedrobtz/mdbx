# Flags accepted by 'libmdbx'

Lists the flag names
[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_open.md),
[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md)
and
[`mdbx_env_set_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_set_flags.md)
accept. They are 'libmdbx”s own names with the `MDBX_` prefix dropped,
so anything written about `MDBX_SAFE_NOSYNC` upstream applies to
`"SAFE_NOSYNC"` here.

## Usage

``` r
mdbx_flags()
```

## Value

A data frame with one row per flag and the columns `flag`, `scope`
(`"env"` or `"txn"`), `settable` (accepted by
[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_open.md)
or
[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_begin.md))
and `runtime` (accepted by
[`mdbx_env_set_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_set_flags.md)).

## Durability

By default every commit is fully durable: data and metadata are flushed
before
[`mdbx_txn_commit()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_txn_commit.md)
returns, and a crash at any moment leaves the database intact. Three
flags trade that away, in increasing order of risk:

- `"NOMETASYNC"`:

  Skips the metadata flush. A system crash may undo the last committed
  transaction. Integrity is never at risk.

- `"SAFE_NOSYNC"`:

  Flushes nothing on commit. A crash rolls the database back to the last
  steady commit — recent transactions are lost, but the database
  **cannot be corrupted**. The cost is file growth, because pages freed
  since that steady point cannot be reused;
  [`mdbx_env_sync()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_sync.md)
  establishes a new one.

- `"UTTERLY_NOSYNC"`:

  As above, but previous steady commits are wiped too. A crash shortly
  after a commit **can corrupt the database beyond recovery**.
  'libmdbx”s own documentation cites a messenger that lost user data
  this way. Suitable only for data you are prepared to regenerate from
  scratch.

Measure before reaching for these. The cost they remove is per-*commit*,
not per-write: on a benchmark of the vendored library, 2000 single-write
transactions ran 89x faster under `"SAFE_NOSYNC"`, while one transaction
of 200000 writes ran 1.1x faster. Batching writes into fewer
transactions is usually the same win at no risk.

## Other flags

`"WRITEMAP"` maps the database writable and updates it in place, which
is faster but exposes the map to stray writes from the process; it also
changes what `"SAFE_NOSYNC"` does, to asynchronous mmap flushes.
`"LIFORECLAIM"` reuses the most recently freed pages first, which suits
filesystems with copy-on-write or trim. `"NORDAHEAD"` suppresses
readahead for databases larger than RAM, `"NOMEMINIT"` skips
zero-filling new pages, `"EXCLUSIVE"` takes the environment for this
process alone, `"ACCEDE"` accepts the flags an existing environment was
opened with rather than conflicting with them, and `"VALIDATION"` turns
on expensive internal checking for debugging.

## What is not here

`"RDONLY"` and `"NOSUBDIR"` are reported but not settable, because they
are the `readonly` and `subdir` arguments of
[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_open.md).
`NOSTICKYTHREADS` is never set: it lifts 'libmdbx”s
one-transaction-per-thread rule, which this package's transaction
registry and finalizer ordering rely on.

## See also

[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_open.md),
[`mdbx_env_set_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_set_flags.md),
[`mdbx_env_sync()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_sync.md)

## Examples

``` r
mdbx_flags()
#>               flag scope settable runtime
#> 1   UTTERLY_NOSYNC   env     TRUE    TRUE
#> 2      SAFE_NOSYNC   env     TRUE    TRUE
#> 3       NOMETASYNC   env     TRUE    TRUE
#> 4         WRITEMAP   env     TRUE   FALSE
#> 5      LIFORECLAIM   env     TRUE    TRUE
#> 6        NORDAHEAD   env     TRUE   FALSE
#> 7        NOMEMINIT   env     TRUE    TRUE
#> 8        EXCLUSIVE   env     TRUE   FALSE
#> 9           ACCEDE   env     TRUE   FALSE
#> 10      VALIDATION   env     TRUE   FALSE
#> 11          RDONLY   env    FALSE   FALSE
#> 12        NOSUBDIR   env    FALSE   FALSE
#> 13 NOSTICKYTHREADS   env    FALSE   FALSE
#> 14          NOSYNC   txn     TRUE   FALSE
#> 15      NOMETASYNC   txn     TRUE   FALSE
#> 16             TRY   txn     TRUE   FALSE

# The durability flags, and where each may be set.
flags <- mdbx_flags()
flags[grepl("SYNC", flags$flag), ]
#>              flag scope settable runtime
#> 1  UTTERLY_NOSYNC   env     TRUE    TRUE
#> 2     SAFE_NOSYNC   env     TRUE    TRUE
#> 3      NOMETASYNC   env     TRUE    TRUE
#> 14         NOSYNC   txn     TRUE   FALSE
#> 15     NOMETASYNC   txn     TRUE   FALSE
```
