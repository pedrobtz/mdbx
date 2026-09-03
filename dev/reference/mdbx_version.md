# Version of the bundled libmdbx

Reports the version of the vendored 'libmdbx' amalgamation that was
compiled into this package. The sources are bundled, so this describes
the library actually in use, not one found on the system.

## Usage

``` r
mdbx_version()
```

## Value

A list with integer components `major`, `minor`, `patch` and `tweak`;
character components `describe` (the upstream git-describe string) and
`commit`; and `build`, a list describing how the amalgamation was
compiled into this package — `datetime`, `target` (the cpu/arch/system
triplet), `compiler`, `options` (the 'libmdbx' build options in effect)
and `flags`.

## Examples

``` r
mdbx_version()$describe
#> [1] "v0.14.3-0-g251562b2"

# How the bundled sources were compiled here.
mdbx_version()$build$target
#> [1] "Linux-AMD64"
```
