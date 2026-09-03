# Size limits imposed by 'libmdbx'

Reports the largest key, value and database 'libmdbx' will accept. Most
of these follow from the page size, which is why they are worth asking
about rather than assuming: the maximum key is a little under half a
page, so it is 8166 bytes where pages are 16 KB and 2022 bytes where
they are 4 KB. Code that hardcodes a size works on one machine and fails
on another.

## Usage

``` r
mdbx_limits(x = NULL)
```

## Arguments

- x:

  What to report limits for. An `mdbx_env` or `mdbx_txn` uses that
  database's actual page size — usually what you want. A single number
  is treated as a page size, for asking about a platform you are not on.
  `NULL`, the default, uses this system's default page size.

## Value

A named list of numbers: `pagesize`, `keysize_min`, `keysize_max`,
`valsize_min`, `valsize_max`, `dbsize_min`, `dbsize_max` and
`txnsize_max`, all in bytes. `keysize_min` and `valsize_min` are zero,
which is how an empty key and an empty value are both legal.

## See also

[`mdbx_env_stat()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_stat.md),
which reports the page size in use.

## Examples

``` r
# This system's defaults.
mdbx_limits()$keysize_max
#> [1] 2022

# The same question for a machine with 4 KB pages.
mdbx_limits(4096)$keysize_max
#> [1] 2022

path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

# The limits that actually apply to this database.
limits <- mdbx_limits(env)
limits$keysize_max
#> [1] 2022

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
