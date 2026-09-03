## R CMD check results

0 errors | 0 warnings | 0 notes

## Notes for the reviewer

This is a new submission.

The package bundles the amalgamated sources of 'libmdbx' (Apache-2.0) under
`src/vendor/libmdbx/`, compiled into the package's own shared object. There is
no system library, submodule, or CMake step. The bundled sources carry four
local patches, which route the library's panic and logging paths through R's
API so that an internal assertion cannot terminate the R session. Both the
bundling and the modifications are declared in `inst/COPYRIGHTS`, which is the
Apache-2.0 section 4(b) notice, and the upstream `LICENSE` and `NOTICE` files
ship alongside the sources. Copyright holders for the bundled code are listed
in `Authors@R`.
