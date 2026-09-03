# Flags an environment is using

Reports every flag in effect on an open environment, including the ones
[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_open.md)
set from its own `readonly` and `subdir` arguments — this describes the
environment, not the call that made it.

## Usage

``` r
mdbx_env_get_flags(env)
```

## Arguments

- env:

  An `mdbx_env` object, from
  [`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_open.md).

## Value

A character vector of flag names, empty if the environment is at
'libmdbx”s defaults in every respect.

## Details

Flags can appear that were never asked for. 'libmdbx' normalizes the
sync modes, so both `"SAFE_NOSYNC"` and `"UTTERLY_NOSYNC"` also report
`"NOMETASYNC"` — the weaker relaxation is implied by the stronger one,
and clearing the stronger one does not clear it. `"UTTERLY_NOSYNC"` does
*not* additionally report `"SAFE_NOSYNC"`, whose bits it contains:
naming both would describe one durability mode as two. An environment
another process opened first may also carry flags this one did not ask
for; that is what `"ACCEDE"` is about.

'libmdbx' keeps internal state in the same word, which is not reported
here: only the names in
[`mdbx_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_flags.md)
are ever returned.

## See also

[`mdbx_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_flags.md),
[`mdbx_env_set_flags()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_env_set_flags.md)

## Examples

``` r
path <- tempfile(fileext = ".mdbx")
env <- mdbx_env_open(path, flags = "NOMETASYNC")

mdbx_env_get_flags(env)
#> [1] "NOMETASYNC" "NOSUBDIR"  

mdbx_env_close(env)
unlink(c(path, paste0(path, "-lck")))
```
