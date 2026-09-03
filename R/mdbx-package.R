#' @keywords internal
#'
#' @section Getting started:
#'
#' Data lives in an *environment* — a file on disk, opened with
#' [mdbx_env_open()] and closed with [mdbx_env_close()]. Every read and write
#' happens inside a *transaction*: [mdbx_with_read()] and [mdbx_with_write()]
#' open one, run your code and end it, committing if the block returns and
#' aborting if it throws. [mdbx_txn_begin()] gives you the same thing by hand
#' when you need to decide at the end whether to keep the writes.
#'
#' Within a transaction, [mdbx_get()], [mdbx_put()] and [mdbx_del()] address
#' single records, and [mdbx_keys()] and [mdbx_items()] list what is there.
#'
#' @section Keys and values are bytes:
#'
#' 'libmdbx' stores byte strings and records no type. A `raw` vector is stored
#' as-is; a single string is stored as its UTF-8 bytes, so `"k"` and
#' `charToRaw("k")` are the same key. Reads decode back to text by default and
#' fail rather than corrupt anything if the bytes are not text — pass
#' `as = "raw"` for values written with [serialize()]. A key that is not there
#' reads as `NULL`.
#'
#' Serialization of arbitrary R objects is deliberately outside this package.
#'
#' @section The rules that are not obvious:
#'
#' * **One transaction at a time per environment.** Concurrency comes from
#'   separate processes, and an environment does not survive a `fork()`. See
#'   [mdbx-concurrency], which is worth reading before using this package with
#'   \pkg{parallel} or \pkg{future}.
#' * **Every commit is durable by default.** [mdbx_flags()] describes the flags
#'   that trade that for speed, and what each one costs.
#' * **Closing is refused while a transaction is open**, because closing
#'   underneath one is undefined behaviour in 'libmdbx'.
#'
#' [mdbx_env_stat()], [mdbx_env_info()] and [mdbx_version()] report on a
#' database and on the bundled library.
#'
"_PACKAGE"

## usethis namespace: start
#' @useDynLib mdbx, .registration = TRUE
## usethis namespace: end
NULL
