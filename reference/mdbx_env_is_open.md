# Is an MDBX environment still open?

Is an MDBX environment still open?

## Usage

``` r
mdbx_env_is_open(env)
```

## Arguments

- env:

  An `mdbx_env` object, from
  [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md).

## Value

`TRUE` if the environment is open and usable, `FALSE` once it has been
closed.

## See also

[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md),
[`mdbx_env_close()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_close.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path)

mdbx_env_is_open(env)
#> [1] TRUE
mdbx_env_close(env)
mdbx_env_is_open(env)
#> [1] FALSE

unlink(c(path, paste0(path, "-lck")))
```
