# Errors raised by mdbx

How to handle a failure from 'libmdbx' without matching its message
text.

## Details

A status 'libmdbx' returns and this package could not turn into an
ordinary value reaches R as a condition carrying the status itself, not
only a sentence describing it. Contention, a full map and a full DBI
table are all expected outcomes that a caller may want to retry, grow or
report differently, and deciding which is which by parsing English is a
contract nobody should have to depend on.

## Class and fields

Every such condition inherits from `mdbx_error`, and from `error` and
`condition` as usual. When the status has a symbolic name, the condition
also carries that name lower-cased as its most specific class — so
`MDBX_BUSY` arrives as:

    c("mdbx_busy", "mdbx_error", "error", "condition")

Three fields beyond `message`:

- `code`:

  The 'libmdbx' status, as an integer. Negative for MDBX's own codes,
  positive for a system `errno` passed through.

- `name`:

  The symbolic name, such as `"MDBX_BUSY"`, or `NA` for a system
  `errno`, which has no MDBX name.

- `call`:

  `NULL`. The messages name what failed and the argument responsible, so
  there is nothing a call would add.

## What is not an mdbx_error

This package's own refusals — a read-only transaction asked to write, a
handle used after its environment closed, an argument of the wrong type,
a second
[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md)
on a path already open — are ordinary errors with no `code`. They report
a mistake in the calling code rather than a condition the database
reached, so there is nothing to retry and no status to inspect.
Assertion failures inside 'libmdbx' are also ordinary errors: see
[`mdbx_txn_state()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_state.md)
for what becomes of the handles.

Remember too that the common "expected" outcomes are not errors at all.
A missing key is `NULL` from
[`mdbx_get()`](https://pedrobtz.github.io/mdbx/reference/mdbx_get.md), a
refused overwrite is `FALSE` from
[`mdbx_put()`](https://pedrobtz.github.io/mdbx/reference/mdbx_put.md),
and deleting an absent key is `FALSE` from
[`mdbx_del()`](https://pedrobtz.github.io/mdbx/reference/mdbx_del.md).

## See also

[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md)
for `flags = "TRY"`, which turns waiting for another process's writer
into an immediate `MDBX_BUSY`;
[mdbx-concurrency](https://pedrobtz.github.io/mdbx/reference/mdbx-concurrency.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path, max_dbs = 2)

# Reserving only two named databases makes the third one fail.
condition <- tryCatch(
  mdbx_with_write(env, function(txn) {
    for (i in 1:3) mdbx_dbi_open(txn, paste0("db", i), create = TRUE)
  }),
  mdbx_error = function(e) e
)

class(condition)
#> [1] "mdbx_dbs_full" "mdbx_error"    "error"         "condition"    
condition$name
#> [1] "MDBX_DBS_FULL"
condition$code
#> [1] -30791

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
