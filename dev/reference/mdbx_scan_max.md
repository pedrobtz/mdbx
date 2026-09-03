# Largest scan `mdbx_keys()` and `mdbx_items()` will do unasked

A scan with no `limit` refuses to run when the database holds more
records than this, rather than materializing the lot. One million keys
is roughly 70 MB as an R character vector, and more again with their
values: enough headroom for ordinary work, small enough to catch a
database that was never meant to be read in one go.

## Usage

``` r
mdbx_scan_max
```

## Format

A single number.

## Details

The guard applies only when `limit` is `NULL`. Any explicit `limit` is
honoured, including `limit = Inf` to say "all of them, really".

## See also

[`mdbx_keys()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_keys.md),
[`mdbx_items()`](https://pedrobtz.github.io/mdbx/dev/reference/mdbx_items.md)

## Examples

``` r
mdbx_scan_max
#> [1] 1e+06
```
