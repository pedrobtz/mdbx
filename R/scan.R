# Listing what a database holds.
#
# Both walk a cursor in C and cross the R/C boundary once, rather than once per
# record. No cursor object is exposed: the shape of a low-level cursor API is
# still an open question, and these do not prejudge it.

#' List the keys in a database
#'
#' Walks the whole database in key order and returns its keys.
#'
#' Everything is materialized in memory at once, so on a large database this can
#' be expensive. A scan with no `limit` therefore refuses to run when the
#' database holds more than [mdbx_scan_max] records; pass an explicit `limit` —
#' or `limit = Inf` — to go ahead anyway. [mdbx_env_stat()]`$entries` tells you
#' how many there are before you ask.
#'
#' @param txn An `mdbx_txn` object, from [mdbx_txn_begin()].
#' @param limit Maximum number of records to return, in key order. `NULL`, the
#'   default, returns all of them, subject to the [mdbx_scan_max] guard;
#'   `Inf` returns all of them unconditionally.
#' @param as `"character"` (the default) to decode keys as UTF-8 text, or
#'   `"raw"` to get a list of raw vectors. As with [mdbx_get()], decoding fails
#'   rather than corrupting anything if a key is not valid UTF-8 text.
#' @param start Begin at this key rather than at an end: the first key at or
#'   after it going forwards, or the last key at or before it going backwards.
#'   A raw vector or a single string, as for [mdbx_get()].
#'
#'   `start` is *inclusive*, so a key that exists is returned rather than
#'   skipped. To walk a database in chunks, pass the last key of one call as the
#'   `start` of the next and drop the first record of the result — otherwise it
#'   repeats. `start` positions the cursor and nothing more: it does not bound
#'   how much comes back, so it does not exempt a scan from
#'   [mdbx_scan_max][mdbx_scan_max]. Pass `limit` for that.
#' @param reverse If `TRUE`, walk from the last key towards the first.
#'   `limit = 1` with `reverse = TRUE` is the largest key, which is otherwise
#'   only reachable by reading every key.
#'
#' @param db An `mdbx_dbi` object from [mdbx_dbi_open()] naming a database to
#'   address instead of the unnamed main one, or `NULL` for the main database.
#' @return A character vector, or a list of raw vectors if `as = "raw"`. Empty
#'   (`character(0)` or `list()`) if the database has no records.
#' @seealso [mdbx_items()], [mdbx_get()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' mdbx_with_write(env, function(txn) {
#'   mdbx_put(txn, "b", "2")
#'   mdbx_put(txn, "a", "1")
#'   mdbx_put(txn, "c", "3")
#' })
#'
#' # Always in key order, whatever order they were written in.
#' mdbx_with_read(env, function(txn) mdbx_keys(txn))
#'
#' mdbx_with_read(env, function(txn) mdbx_keys(txn, limit = 2))
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_keys <- function(txn, limit = NULL, as = c("character", "raw"), db = NULL,
                      start = NULL, reverse = FALSE) {
  as <- match.arg(as)
  reverse <- check_bool(reverse, "reverse")
  if (is.null(limit)) guard_unbounded(txn, db)

  keys <- mdbx_scan_(txn, check_limit(limit), values = FALSE, db_name(db, txn),
                     check_start(start), reverse)$keys
  decode_many(keys, as)
}

#' List the keys and values in a database
#'
#' Walks the whole database in key order and returns both keys and values, in
#' one pass. Use [mdbx_keys()] instead when you do not need the values —
#' fetching them is the expensive part.
#'
#' The two components are parallel: `keys[[i]]` names `values[[i]]`. When keys
#' are text, `setNames(items$values, items$keys)` turns the result into a
#' lookup list.
#'
#' The caution in [mdbx_keys()] about materializing everything applies here with
#' more force, since values are usually larger than keys.
#'
#' @inheritParams mdbx_keys
#' @param as `"character"` (the default) to decode values as UTF-8 text, or
#'   `"raw"` for a list of raw vectors. Decoding fails rather than corrupting
#'   anything, so a database holding `serialize()` output needs `as = "raw"`.
#'   Governs keys too unless `keys_as` says otherwise.
#' @param keys_as How to decode keys, when that differs from the values. An
#'   index typically has binary keys — an encoded timestamp or counter — and
#'   text values, which is `as = "character", keys_as = "raw"`.
#'
#' @return A list with two parallel components, `keys` and `values`, each a
#'   character vector or a list of raw vectors according to `as`.
#' @seealso [mdbx_keys()], [mdbx_get()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' mdbx_with_write(env, function(txn) {
#'   mdbx_put(txn, "a", "1")
#'   mdbx_put(txn, "b", "2")
#' })
#'
#' items <- mdbx_with_read(env, function(txn) mdbx_items(txn))
#' items
#'
#' # A lookup list, when the keys are text.
#' stats::setNames(items$values, items$keys)
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_items <- function(txn, limit = NULL, as = c("character", "raw"), db = NULL,
                       start = NULL, reverse = FALSE, keys_as = NULL) {
  as <- match.arg(as)
  keys_as <- if (is.null(keys_as)) as else match.arg(keys_as, c("character", "raw"))
  reverse <- check_bool(reverse, "reverse")
  if (is.null(limit)) guard_unbounded(txn, db)

  found <- mdbx_scan_(txn, check_limit(limit), values = TRUE, db_name(db, txn),
                      check_start(start), reverse)
  list(
    keys = decode_many(found$keys, keys_as),
    values = decode_many(found$values, as)
  )
}

# NULL means "no limit", which the native layer spells as a negative value.
# Zero is a real limit meaning "none", so it must not share that sentinel.
check_limit <- function(limit) {
  if (is.null(limit)) {
    return(-1)
  }
  if (!is.numeric(limit) || length(limit) != 1L || is.na(limit) || limit < 0) {
    stop("`limit` must be a single non-negative number, or NULL for no limit",
         call. = FALSE)
  }
  # Inf is a legitimate way to say "all of them", and would overflow a cast.
  if (is.infinite(limit)) {
    return(-1)
  }
  check_whole(limit, "limit")
  # Anything past the platform's size_t would be an out-of-range cast; see
  # max_native_integer in R/env.R. A limit that large means "no limit" anyway.
  if (limit > max_native_integer()) {
    stop(sprintf("`limit` is too large: at most %.0f on this platform, or Inf for no limit",
                 max_native_integer()),
         call. = FALSE)
  }
  as.double(limit)
}

#' Largest scan `mdbx_keys()` and `mdbx_items()` will do unasked
#'
#' A scan with no `limit` refuses to run when the database holds more records
#' than this, rather than materializing the lot. One million keys is roughly
#' 70 MB as an R character vector, and more again with their values: enough
#' headroom for ordinary work, small enough to catch a database that was never
#' meant to be read in one go.
#'
#' The guard applies only when `limit` is `NULL`. Any explicit `limit` is
#' honoured, including `limit = Inf` to say "all of them, really".
#'
#' @format A single number.
#' @seealso [mdbx_keys()], [mdbx_items()]
#' @export
#' @examples
#' mdbx_scan_max
mdbx_scan_max <- 1e6

# Refuse an unbounded scan of a database that is too big to be read in one go.
# `entries` is exact within a transaction, so this is a real check rather than
# an estimate.
guard_unbounded <- function(txn, db = NULL) {
  entries <- mdbx_env_stat(txn, db = db)$entries

  if (entries > mdbx_scan_max) {
    stop(
      sprintf(
        paste0(
          "this database holds %.0f records, more than mdbx_scan_max (%.0f); ",
          "reading them all at once is refused by default. Pass `limit = n` ",
          "for the first n in key order, or `limit = Inf` to read them all anyway"
        ),
        entries, mdbx_scan_max
      ),
      call. = FALSE
    )
  }

  invisible(NULL)
}

# Raw vectors as they came back from the scan, or all decoded as UTF-8 text.
decode_many <- function(items, as) {
  if (as == "raw") {
    return(items)
  }
  vapply(items, decode_utf8, character(1), USE.NAMES = FALSE)
}

# The scan's starting key, as raw bytes, or NULL to start from an end.
check_start <- function(start) {
  if (is.null(start)) {
    return(NULL)
  }
  as_bytes(start, "start")
}
