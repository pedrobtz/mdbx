# Named databases.
#
# An environment can hold several independent key spaces. The unnamed "main"
# database is the default everywhere, so nothing here changes existing code.
#
# The handle is a plain S3 record of the database's *name*, not its MDBX_dbi.
# That is deliberate: a dbi obtained inside a transaction that later aborts is
# poisoned (MDBX_BAD_DBI) and its database does not exist, so an object holding
# the number could hand out an invalid handle. Names are re-resolved per
# transaction instead, which libmdbx makes cheap by returning the same dbi for
# repeated opens within one.

#' Open a named database
#'
#' An environment holds an unnamed main database and, if `max_dbs` allows, any
#' number of named ones. Named databases are independent key spaces: the same
#' key may appear in several with different values, and [mdbx_keys()] on one
#' never sees another's.
#'
#' The database is opened for the duration of this transaction and re-resolved
#' by name in later ones, so the returned handle stays usable for the life of
#' the environment — but only if the transaction that created it **commits**.
#' If it aborts, the database was never created and the handle refers to
#' nothing; using it then is an ordinary "not found" error.
#'
#' Reserve capacity with `max_dbs` in [mdbx_env_open()] before opening any: the
#' libmdbx default leaves no room for named databases at all, and running out
#' reports `MDBX_DBS_FULL`.
#'
#' @param txn An `mdbx_txn` object, from [mdbx_txn_begin()]. Creating a database
#'   needs a write transaction; opening an existing one does not.
#' @param name The database's name, a single string.
#' @param create If `TRUE`, create the database when it does not exist. If
#'   `FALSE`, opening a database that was never created is an error.
#'
#' @return An `mdbx_dbi` object, to pass as the `db` argument of [mdbx_get()],
#'   [mdbx_put()], [mdbx_del()], [mdbx_keys()] and [mdbx_items()].
#' @seealso [mdbx_dbi_drop()], [mdbx_env_open()] for `max_dbs`
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path, max_dbs = 8)
#'
#' mdbx_with_write(env, function(txn) {
#'   files <- mdbx_dbi_open(txn, "files", create = TRUE)
#'   metadata <- mdbx_dbi_open(txn, "metadata", create = TRUE)
#'
#'   mdbx_put(txn, "abc", "/data/abc.parquet", db = files)
#'   mdbx_put(txn, "abc", '{"size":1234}', db = metadata)
#' })
#'
#' # The same key, two databases, two values.
#' mdbx_with_read(env, function(txn) {
#'   c(files = mdbx_get(txn, "abc", db = mdbx_dbi_open(txn, "files")),
#'     metadata = mdbx_get(txn, "abc", db = mdbx_dbi_open(txn, "metadata")))
#' })
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_dbi_open <- function(txn, name, create = FALSE) {
  name <- check_string(name, "name")
  create <- check_bool(create, "create")

  mdbx_dbi_open_(txn, name, create)

  structure(list(name = name, path = attr(txn, "path")), class = "mdbx_dbi")
}

#' Empty or delete a named database
#'
#' `delete = FALSE` removes every record but keeps the database. `delete = TRUE`
#' removes the database itself, after which the handle refers to nothing and
#' reopening it needs `create = TRUE` again.
#'
#' Like every other write, this takes effect only when the transaction commits.
#'
#' @param txn An `mdbx_txn` object from [mdbx_txn_begin()], opened for writing.
#' @param db An `mdbx_dbi` object from [mdbx_dbi_open()], or `NULL` for the main
#'   database — which can be emptied but not deleted.
#' @param delete If `TRUE`, delete the database rather than just emptying it.
#' @return `NULL`, invisibly.
#' @seealso [mdbx_dbi_open()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path, max_dbs = 8)
#'
#' mdbx_with_write(env, function(txn) {
#'   scratch <- mdbx_dbi_open(txn, "scratch", create = TRUE)
#'   mdbx_put(txn, "k", "v", db = scratch)
#'   mdbx_dbi_drop(txn, scratch)
#'   mdbx_keys(txn, db = scratch)
#' })
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_dbi_drop <- function(txn, db, delete = FALSE) {
  delete <- check_bool(delete, "delete")
  mdbx_dbi_drop_(txn, db_name(db, txn), delete)
  invisible(NULL)
}

#' List the named databases in an environment
#'
#' Reports the named databases visible to this transaction, which is not the
#' same as the ones it could open: a database created by a transaction that has
#' not committed is not listed, and one deleted but not yet committed still is.
#'
#' Names are bytes, like keys, so a name that is not valid UTF-8 text needs
#' `as = "raw"`. The unnamed main database is not listed, having no name.
#'
#' @param txn An `mdbx_txn` object, from [mdbx_txn_begin()].
#' @param as `"character"` (the default) to decode names as UTF-8 text, or
#'   `"raw"` for a list of raw vectors.
#' @return A character vector of names, or a list of raw vectors if
#'   `as = "raw"`. Empty when the environment has only the main database.
#' @seealso [mdbx_dbi_open()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path, max_dbs = 8)
#'
#' mdbx_with_write(env, function(txn) {
#'   mdbx_dbi_open(txn, "files", create = TRUE)
#'   mdbx_dbi_open(txn, "metadata", create = TRUE)
#' })
#'
#' mdbx_with_read(env, function(txn) mdbx_dbi_list(txn))
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_dbi_list <- function(txn, as = c("character", "raw")) {
  as <- match.arg(as)
  decode_many(mdbx_dbi_list_(txn), as)
}

#' @export
print.mdbx_dbi <- function(x, ...) {
  cat("<mdbx_dbi>", x$name, "\n")
  invisible(x)
}

# The `db` argument as the native layer wants it: character(0) for the main
# database, or the name. Handles carry the environment they were opened against
# so that using one elsewhere is caught rather than silently addressing a
# same-named database in another environment.
db_name <- function(db, txn) {
  if (is.null(db)) {
    return(character(0))
  }
  if (!inherits(db, "mdbx_dbi")) {
    stop("`db` must be an 'mdbx_dbi' object from mdbx_dbi_open(), or NULL for the main database",
         call. = FALSE)
  }
  if (!identical(db$path, attr(txn, "path"))) {
    stop(sprintf(
      "this database handle belongs to the environment at '%s', not '%s'",
      db$path, attr(txn, "path")
    ), call. = FALSE)
  }
  db$name
}

#' A database's sequence counter
#'
#' Every database carries a 64-bit counter that 'libmdbx' stores with it.
#' Reading it with `increment = 0` reports its current value; a positive
#' `increment` reserves that many values and returns the first, so two callers
#' in separate transactions can never be handed the same number.
#'
#' It is the natural way to mint ids — a monotonically increasing insertion
#' order, of the kind a cache uses to evict what was stored longest ago. Encode
#' the result big-endian if it is going to be a key, so that byte order matches
#' numeric order.
#'
#' Like every other write, an increment only stands if the transaction commits.
#'
#' @param txn An `mdbx_txn` object from [mdbx_txn_begin()]. Incrementing needs a
#'   write transaction; reading does not.
#' @param db An `mdbx_dbi` object from [mdbx_dbi_open()], or `NULL` for the main
#'   database.
#' @param increment How many values to reserve. `0`, the default, reads the
#'   counter without changing it.
#' @return The counter's value before the increment, as a number.
#' @seealso [mdbx_dbi_open()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path, max_dbs = 8)
#'
#' mdbx_with_write(env, function(txn) {
#'   ids <- mdbx_dbi_open(txn, "ids", create = TRUE)
#'
#'   c(first = mdbx_dbi_sequence(txn, ids, 1),
#'     second = mdbx_dbi_sequence(txn, ids, 1),
#'     current = mdbx_dbi_sequence(txn, ids))
#' })
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_dbi_sequence <- function(txn, db = NULL, increment = 0) {
  if (!is.numeric(increment) || length(increment) != 1L || !is.finite(increment) ||
      increment < 0 || increment > max_exact_integer) {
    stop(sprintf("`increment` must be a single number between 0 and %.0f (2^53)",
                 max_exact_integer), call. = FALSE)
  }
  check_whole(increment, "increment")
  mdbx_dbi_sequence_(txn, db_name(db, txn), as.double(increment))
}
