# Reclaim reader slots from processes that died

A process holding a read transaction occupies a slot in the
environment's reader table. If it exits without ending the transaction —
killed, crashed, or `SIGKILL`ed — the slot stays occupied. Enough of
those and new readers fail with `MDBX_READERS_FULL` even though nothing
is actually reading.

## Usage

``` r
mdbx_env_reader_check(env)
```

## Arguments

- env:

  An `mdbx_env` object, from
  [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md).

## Value

The number of stale slots that were released, invisibly. Zero when every
occupied slot belongs to a live process.

## Details

This asks 'libmdbx' to check every occupied slot and release the ones
whose owning process is gone. It is safe to call at any time and costs
nothing when there is nothing to reclaim, so it is a reasonable thing to
run when opening a long-lived environment that other processes also use.

Raising
[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md)'s
`max_readers` makes the table bigger; this makes room in the table you
have. See
[mdbx-concurrency](https://pedrobtz.github.io/mdbx/reference/mdbx-concurrency.md).

## See also

[`mdbx_env_info()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_info.md),
which reports `numreaders` and `maxreaders`.

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

# Nothing has died, so nothing is reclaimed.
mdbx_env_reader_check(env)

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
