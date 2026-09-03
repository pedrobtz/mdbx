# Change an environment's flags

Sets or clears flags on an open environment. Only the flags 'libmdbx'
documents as changeable at any time can be set this way —
`mdbx_flags()$runtime` marks them; the rest are fixed when the
environment is opened.

## Usage

``` r
mdbx_env_set_flags(env, flags, on = TRUE)
```

## Arguments

- env:

  An `mdbx_env` object, from
  [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md).

- flags:

  A character vector of flag names — see
  [`mdbx_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_flags.md).

- on:

  `TRUE` to set the flags, `FALSE` to clear them.

## Value

`NULL`, invisibly.

## Details

This is refused while a transaction is open, because 'libmdbx'
serializes flag changes against the writer lock and would return
`MDBX_BUSY`. Changing durability between transactions is the intended
use: relax it for a bulk load, restore it and call
[`mdbx_env_sync()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_sync.md)
afterwards.

## See also

[`mdbx_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_flags.md),
[`mdbx_env_get_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_get_flags.md),
[`mdbx_env_sync()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_sync.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

# Bulk load without paying for a flush per commit.
mdbx_env_set_flags(env, "SAFE_NOSYNC")
for (i in 1:10) {
  mdbx_with_write(env, function(txn) mdbx_put(txn, sprintf("k%d", i), "v"))
}

# Then make it durable again, and flush what is outstanding.
mdbx_env_set_flags(env, "SAFE_NOSYNC", on = FALSE)
mdbx_env_sync(env)

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
