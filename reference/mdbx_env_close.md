# Close an MDBX environment

Closes the environment and releases its native resources. Closing is
idempotent: calling it on an already-closed environment does nothing, so
it is safe to pair an explicit close with an
[`on.exit()`](https://rdrr.io/r/base/on.exit.html) guard.

## Usage

``` r
mdbx_env_close(env)
```

## Arguments

- env:

  An `mdbx_env` object, from
  [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md).

## Value

`NULL`, invisibly.

## Details

Closing is refused while any transaction on the environment is still
open, because 'libmdbx' documents that using a transaction after its
environment closes is undefined behaviour. Commit or abort them first —
or use
[`mdbx_with_read()`](https://pedrobtz.github.io/mdbx/reference/mdbx_with_write.md)
/
[`mdbx_with_write()`](https://pedrobtz.github.io/mdbx/reference/mdbx_with_write.md),
which cannot leave one open.

Using a closed environment for anything else is an error rather than a
crash.

## See also

[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md),
[`mdbx_env_is_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_is_open.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

mdbx_env_close(env)
mdbx_env_is_open(env)
#> [1] FALSE

unlink(c(path, paste0(path, "-lck")))
```
