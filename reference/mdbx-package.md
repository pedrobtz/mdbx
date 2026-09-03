# mdbx: Bindings to the 'libmdbx' Embedded Key-Value Store

Provides low-level bindings to 'libmdbx', a compact and fast
transactional key-value store built on memory-mapped files
(<https://libmdbx.dqdkfa.ru/>). Database environments, transactions, and
byte-oriented read and write operations are exposed directly. The
'libmdbx' sources are bundled and compiled into the package, so no
system library installation is required.

## Getting started

Data lives in an *environment* — a file on disk, opened with
[`mdbx_env_open()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_open.md)
and closed with
[`mdbx_env_close()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_close.md).
Every read and write happens inside a *transaction*:
[`mdbx_with_read()`](https://pedrobtz.github.io/mdbx/reference/mdbx_with_write.md)
and
[`mdbx_with_write()`](https://pedrobtz.github.io/mdbx/reference/mdbx_with_write.md)
open one, run your code and end it, committing if the block returns and
aborting if it throws.
[`mdbx_txn_begin()`](https://pedrobtz.github.io/mdbx/reference/mdbx_txn_begin.md)
gives you the same thing by hand when you need to decide at the end
whether to keep the writes.

Within a transaction,
[`mdbx_get()`](https://pedrobtz.github.io/mdbx/reference/mdbx_get.md),
[`mdbx_put()`](https://pedrobtz.github.io/mdbx/reference/mdbx_put.md)
and
[`mdbx_del()`](https://pedrobtz.github.io/mdbx/reference/mdbx_del.md)
address single records, and
[`mdbx_keys()`](https://pedrobtz.github.io/mdbx/reference/mdbx_keys.md)
and
[`mdbx_items()`](https://pedrobtz.github.io/mdbx/reference/mdbx_items.md)
list what is there.

## Keys and values are bytes

'libmdbx' stores byte strings and records no type. A `raw` vector is
stored as-is; a single string is stored as its UTF-8 bytes, so `"k"` and
`charToRaw("k")` are the same key. Reads decode back to text by default
and fail rather than corrupt anything if the bytes are not text — pass
`as = "raw"` for values written with
[`serialize()`](https://rdrr.io/r/base/serialize.html). A key that is
not there reads as `NULL`.

Serialization of arbitrary R objects is deliberately outside this
package.

## The rules that are not obvious

- **One transaction at a time per environment.** Concurrency comes from
  separate processes, and an environment does not survive a `fork()`.
  See
  [mdbx-concurrency](https://pedrobtz.github.io/mdbx/reference/mdbx-concurrency.md),
  which is worth reading before using this package with parallel or
  future.

- **Every commit is durable by default.**
  [`mdbx_flags()`](https://pedrobtz.github.io/mdbx/reference/mdbx_flags.md)
  describes the flags that trade that for speed, and what each one
  costs.

- **Closing is refused while a transaction is open**, because closing
  underneath one is undefined behaviour in 'libmdbx'.

[`mdbx_env_stat()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_stat.md),
[`mdbx_env_info()`](https://pedrobtz.github.io/mdbx/reference/mdbx_env_info.md)
and
[`mdbx_version()`](https://pedrobtz.github.io/mdbx/reference/mdbx_version.md)
report on a database and on the bundled library.

## See also

Useful links:

- <https://github.com/pedrobtz/mdbx>

- Report bugs at <https://github.com/pedrobtz/mdbx/issues>

## Author

**Maintainer**: Pedro Baltazar <pedrobtz@gmail.com> \[copyright holder\]

Authors:

- Pedro Baltazar <pedrobtz@gmail.com> \[copyright holder\]

Other contributors:

- Leonid Yuriev (Vendored 'libmdbx' library in src/vendor/libmdbx; see
  inst/COPYRIGHTS.) \[contributor, copyright holder\]

- Howard Chu (Author of LMDB, from which libmdbx derives; see
  inst/COPYRIGHTS.) \[contributor, copyright holder\]

- Symas Corporation (Copyright holder of LMDB; see inst/COPYRIGHTS.)
  \[copyright holder\]

- Martin Hedenfalk (Author of btree.c, from which LMDB derives; see
  inst/COPYRIGHTS.) \[contributor, copyright holder\]
