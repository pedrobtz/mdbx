# Statistics and environment info.
#
# Both accept either an environment or a transaction, mirroring libmdbx's own
# entry points, which take an optional transaction.
#
# The environment form passes the transaction this thread already holds, when
# there is one, rather than a null transaction. That is not a nicety: given a
# null transaction libmdbx opens an internal read transaction of its own, which
# collides with a read transaction the same thread is holding and fails with
# MDBX_BAD_RSLOT. Reusing the live one both avoids the collision and makes the
# two forms report the same thing, uncommitted changes included -- so an abort
# takes the counts back down.
#
# They diverge only when a transaction pins a snapshot the environment has
# since moved past, which needs a second process.

#' Database statistics
#'
#' Reports the shape of the main database: its page size, B-tree depth, page
#' counts, and how many records it holds.
#'
#' Passing a transaction reports what that transaction sees, including changes
#' it has made but not committed. Passing the environment reports the same
#' thing whenever this thread holds a transaction, because the environment form
#' reuses it — so uncommitted changes are included, and an abort takes the
#' counts back down.
#'
#' The two therefore agree in a single-threaded R session. They differ only
#' when a transaction holds a snapshot the environment has moved past, which
#' requires another process to have committed in the meantime.
#'
#' Without `db`, the counts cover the **whole environment** — every named
#' database as well as the main one. Measured, since 'libmdbx' does not say so:
#' a main database of 4 keys plus a named database of 7 reports 11 entries.
#' Pass `db` for one database's own B-tree.
#'
#' @param x An `mdbx_env` from [mdbx_env_open()], or an `mdbx_txn` from
#'   [mdbx_txn_begin()].
#' @param ... Unused, for extensibility.
#'
#' @return A named list of numbers: `pagesize`, `depth`, `branch_pages`,
#'   `leaf_pages`, `overflow_pages`, `entries` (the number of records), and
#'   `mod_txnid` (the transaction that last modified the database). Counts are
#'   `double` because 'libmdbx' reports them as 64-bit integers, which R has no
#'   type for; every realistic value is exact.
#' @seealso [mdbx_env_info()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' mdbx_with_write(env, function(txn) {
#'   mdbx_put(txn, "a", "1")
#'
#'   # Counted before the commit.
#'   mdbx_env_stat(txn)$entries
#' })
#'
#' mdbx_env_stat(env)$entries
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_env_stat <- function(x, ...) {
  UseMethod("mdbx_env_stat")
}

#' @export
mdbx_env_stat.mdbx_env <- function(x, ...) {
  mdbx_env_stat_(x)
}

#' @param db An `mdbx_dbi` object from [mdbx_dbi_open()] to report on instead of
#'   the main database, or `NULL` for the main one. Only available when `x` is a
#'   transaction, since a database is resolved within one.
#' @rdname mdbx_env_stat
#' @export
mdbx_env_stat.mdbx_txn <- function(x, db = NULL, ...) {
  mdbx_txn_stat_(x, db_name(db, x))
}

#' @export
mdbx_env_stat.default <- function(x, ...) {
  stop("expected an 'mdbx_env' or 'mdbx_txn' object", call. = FALSE)
}

#' Environment information
#'
#' Reports the environment as a whole: the size limits it was opened with, how
#' much of the map is in use, the most recent transaction, and reader slots.
#'
#' The choice between an environment and a transaction behaves as described for
#' [mdbx_env_stat()].
#'
#' @param x An `mdbx_env` from [mdbx_env_open()], or an `mdbx_txn` from
#'   [mdbx_txn_begin()].
#' @param ... Unused, for extensibility.
#'
#' @return A named list of numbers. The `geo_*` entries are the datafile
#'   geometry — `geo_lower` and `geo_upper` are the bounds the map may grow
#'   between (`geo_upper` is what `map_size` sets in [mdbx_env_open()]),
#'   `geo_current` its present size, and `geo_shrink` / `geo_grow` the steps it
#'   changes by. Also `mapsize`, `file_size`, `last_pgno`, `recent_txnid`,
#'   `latter_reader_txnid`, `maxreaders`, `numreaders`, `pagesize` and
#'   `sys_pagesize`.
#'
#'   This is a useful subset, not the whole of 'libmdbx''s `MDBX_envinfo`; the
#'   omitted fields are meta-page signatures, boot ids, page-operation counters
#'   and sync timings, which are diagnostics for 'libmdbx' itself.
#' @seealso [mdbx_env_stat()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path, map_size = 4 * 1024^2)
#'
#' info <- mdbx_env_info(env)
#' info$geo_upper
#' info$numreaders
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_env_info <- function(x, ...) {
  UseMethod("mdbx_env_info")
}

#' @export
mdbx_env_info.mdbx_env <- function(x, ...) {
  mdbx_env_info_(x)
}

#' @export
mdbx_env_info.mdbx_txn <- function(x, ...) {
  mdbx_txn_info_(x)
}

#' @export
mdbx_env_info.default <- function(x, ...) {
  stop("expected an 'mdbx_env' or 'mdbx_txn' object", call. = FALSE)
}

#' Size limits imposed by 'libmdbx'
#'
#' Reports the largest key, value and database 'libmdbx' will accept. Most of
#' these follow from the page size, which is why they are worth asking about
#' rather than assuming: the maximum key is a little under half a page, so it is
#' 8166 bytes where pages are 16 KB and 2022 bytes where they are 4 KB. Code
#' that hardcodes a size works on one machine and fails on another.
#'
#' @param x What to report limits for. An `mdbx_env` or `mdbx_txn` uses that
#'   database's actual page size — usually what you want. A single number is
#'   treated as a page size, for asking about a platform you are not on.
#'   `NULL`, the default, uses this system's default page size.
#'
#' @return A named list of numbers: `pagesize`, `keysize_min`, `keysize_max`,
#'   `valsize_min`, `valsize_max`, `dbsize_min`, `dbsize_max` and
#'   `txnsize_max`, all in bytes. `keysize_min` and `valsize_min` are zero,
#'   which is how an empty key and an empty value are both legal.
#' @seealso [mdbx_env_stat()], which reports the page size in use.
#' @export
#' @examples
#' # This system's defaults.
#' mdbx_limits()$keysize_max
#'
#' # The same question for a machine with 4 KB pages.
#' mdbx_limits(4096)$keysize_max
#'
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' # The limits that actually apply to this database.
#' limits <- mdbx_limits(env)
#' limits$keysize_max
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_limits <- function(x = NULL) {
  pagesize <- if (is.null(x)) {
    0
  } else if (inherits(x, "mdbx_env") || inherits(x, "mdbx_txn")) {
    mdbx_env_stat(x)$pagesize
  } else if (is.numeric(x) && length(x) == 1L) {
    # A page size lands in an intptr_t natively, so Inf and anything past the
    # pointer range have to be stopped here rather than at the cast.
    check_size(x, "x", max_native_integer(), "this system's page size")
  } else {
    stop("`x` must be an 'mdbx_env', an 'mdbx_txn', a single page size, or NULL",
         call. = FALSE)
  }

  mdbx_limits_(pagesize)
}
