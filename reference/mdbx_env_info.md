# Environment information

Reports the environment as a whole: the size limits it was opened with,
how much of the map is in use, the most recent transaction, and reader
slots.

## Usage

``` r
mdbx_env_info(x, ...)
```

## Arguments

- x:

  An `mdbx_env` from
  [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md),
  or an `mdbx_txn` from
  [`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md).

- ...:

  Unused, for extensibility.

## Value

A named list of numbers. The `geo_*` entries are the datafile geometry —
`geo_lower` and `geo_upper` are the bounds the map may grow between
(`geo_upper` is what `map_size` sets in
[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md)),
`geo_current` its present size, and `geo_shrink` / `geo_grow` the steps
it changes by. Also `mapsize`, `file_size`, `last_pgno`, `recent_txnid`,
`latter_reader_txnid`, `maxreaders`, `numreaders`, `pagesize` and
`sys_pagesize`.

This is a useful subset, not the whole of 'libmdbx”s `MDBX_envinfo`; the
omitted fields are meta-page signatures, boot ids, page-operation
counters and sync timings, which are diagnostics for 'libmdbx' itself.

## Details

The choice between an environment and a transaction behaves as described
for
[`mdbx_env_stat()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_stat.md).

## See also

[`mdbx_env_stat()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_stat.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path, map_size = 4 * 1024^2)

info <- mdbx_env_info(env)
info$geo_upper
#> [1] 4194304
info$numreaders
#> [1] 0

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
