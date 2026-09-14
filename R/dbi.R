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
#' nothing; passing it as `db` then reports the database as missing, naming it.
#'
#' Opening a database that does not exist is an error rather than `NULL`: a
#' name is something you wrote, so a mistyped one is worth reporting where it
#' was written. To find out whether one exists without handling an error, look
#' for it in [mdbx_dbi_list()].
#'
#' Reserve capacity with `max_dbs` in [mdbx_env_open()] before opening any: the
#' libmdbx default leaves no room for named databases at all, and running out
#' reports `MDBX_DBS_FULL`.
#'
#' @param txn An `mdbx_txn` object, from [mdbx_txn_begin()]. Creating a database
#'   needs a write transaction; opening an existing one does not.
#' @param name The database's name, a single string.
#' @param create If `TRUE`, create the database when it does not exist — which
#'   needs a write transaction, and is refused in a read one. If `FALSE`,
#'   opening a database that was never created is an error naming it.
#'
#' @return An `mdbx_dbi` object, to pass as the `db` argument of [mdbx_get()],
#'   [mdbx_put()], [mdbx_del()], [mdbx_keys()] and [mdbx_items()].
#' @seealso [mdbx_dbi_list()], [mdbx_dbi_drop()], [mdbx_env_open()] for
#'   `max_dbs`
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
#' # Opening one that was never created is an error, so a reader that does not
#' # know which exist yet asks rather than catching.
#' mdbx_with_read(env, function(txn) {
#'   c("files" %in% mdbx_dbi_list(txn), "sizes" %in% mdbx_dbi_list(txn))
#' })
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_dbi_open <- function(txn, name, create = FALSE) {
  name <- check_string(name, "name")
  create <- check_bool(create, "create")

  mdbx_dbi_open_(txn, name, create)

  # `token` is what identifies the environment; `path` is carried only so a
  # refusal can name it. See db_name().
  structure(list(name = name, path = attr(txn, "path"),
                 token = attr(txn, "token")),
            class = "mdbx_dbi")
}

#' Empty or delete a named database
#'
#' `delete = FALSE` removes every record but keeps the database. `delete = TRUE`
#' removes the database itself, after which the handle refers to nothing and
#' reopening it needs `create = TRUE` again.
#'
#' The main database is the exception, twice over. It is what records the named
#' ones, so it cannot be deleted at all: `db = NULL` with `delete = TRUE` is an
#' error rather than the quiet emptying 'libmdbx' would perform. And emptying it
#' destroys every named database along with it, for the same reason — so that is
#' refused too while any named database exists. Drop those by name first if you
#' really mean to, or delete the main database's own keys individually.
#'
#' Emptying a database that holds records also resets its
#' [sequence counter][mdbx_dbi_sequence] to zero, because 'libmdbx' rewrites
#' the database's record and the counter lives in it. (Emptying one that is
#' already empty rewrites nothing and leaves the counter alone, but that is not
#' a distinction to build on.) Do not rely on ids minted before an emptying
#' staying unique afterwards — if they are still referenced somewhere, remove
#' the records by deleting their keys instead.
#'
#' Like every other write, this takes effect only when the transaction commits.
#'
#' @param txn An `mdbx_txn` object from [mdbx_txn_begin()], opened for writing.
#'   Both emptying and deleting are writes, so a read transaction is refused.
#' @param db An `mdbx_dbi` object from [mdbx_dbi_open()], or `NULL` for the main
#'   database — which can never be deleted, and can be emptied only while no
#'   named database exists to be destroyed along with it.
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
  name <- db_name(db, txn)

  # Emptying the main database destroys every named database with it, because
  # what a named database *is* is a record in the main one -- libmdbx purges the
  # whole main tree and those records go with it. Nothing about "removes every
  # record but keeps the database" prepares anyone for that.
  #
  # Worse, it cannot be made consistent afterwards. The transaction's cached
  # handles go on answering from trees libmdbx has already purged, so within the
  # same transaction mdbx_dbi_list() reports nothing while a handle opened a
  # moment earlier still returns rows; and libmdbx keeps its own environment-
  # level record of the name, so after the commit mdbx_dbi_open() still succeeds
  # for a database that no longer exists and the read through it fails with a
  # raw MDBX_BAD_DBI. Putting that right would need mdbx_dbi_close(), the one
  # call this package refuses to make (see .agents/design.md).
  #
  # So refuse while there is anything to lose. Emptying main is exactly as safe
  # as it sounds once no named database is riding on it, and that case stays
  # allowed.
  # Only for a write transaction. A read one is refused by the native layer for
  # being read-only, which is the problem it actually has -- and checking here
  # first named the other one, so the two halves of this function disagreed
  # about what was wrong with the same call.
  if (length(name) == 0L && !delete && isTRUE(attr(txn, "write"))) {
    named <- mdbx_dbi_list_(txn)
    if (length(named) > 0L) {
      stop(sprintf(paste0(
        "emptying the main database would also destroy the %d named database%s ",
        "in this environment, because each one is a record in the main ",
        "database. Drop them by name first if that is what you want, or delete ",
        "the main database's keys individually"
      ), length(named), if (length(named) == 1L) "" else "s"), call. = FALSE)
    }
  }

  mdbx_dbi_drop_(txn, name, delete)
  invisible(NULL)
}

#' List the named databases in an environment
#'
#' Reports the named databases visible to this transaction. Visibility is the
#' transaction's own: a database this transaction created is listed
#' immediately, and one it deleted is gone immediately, both before any commit.
#' What other transactions see is decided when this one commits or aborts —
#' until then they see neither the creation nor the deletion.
#'
#' That makes this the way to ask whether a database exists without handling an
#' error, which is what [mdbx_dbi_open()] raises for a name that was never
#' created.
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
#
# What they carry for that is the environment's `token`, not its path. A path
# names a place, and an environment can be closed, deleted and another created
# in the same place -- after which a handle from the first would have gone on
# reading and writing the same-named database in its replacement, which has
# nothing to do with it. The token names the open, so the two do not compare
# equal. The path is kept alongside it only so the refusal can say where.
#
# The contents are checked, not just the class. An mdbx_dbi is an ordinary
# mutable list, so `db$name <- character(0)` is something R code can do -- and
# character(0) is exactly how the native layer spells "the main database". A
# damaged named handle therefore used to redirect the operation rather than be
# refused, silently, for reads and writes and drops alike. NULL stays the only
# way to ask for the main database.
db_name <- function(db, txn) {
  if (is.null(db)) {
    return(character(0))
  }
  if (!inherits(db, "mdbx_dbi") || !is.list(db)) {
    stop("`db` must be an 'mdbx_dbi' object from mdbx_dbi_open(), or NULL for the main database",
         call. = FALSE)
  }

  name <- db$name
  path <- db$path
  token <- db$token

  if (!is_single_string(name) || !is_single_string(path) ||
      !is_single_string(token)) {
    stop(paste0(
      "`db` is not a valid 'mdbx_dbi' object: its `name`, `path` and `token` ",
      "must each be a single non-empty string. Use mdbx_dbi_open() to obtain ",
      "one, or NULL for the main database"
    ), call. = FALSE)
  }

  # A `txn` that is not a transaction is not this function's to complain about.
  # It gets here because R forces db_name(db, txn) before the native entry point
  # can check its own argument, and comparing a handle against the attributes of
  # something that has none produced a message about the database handle for
  # what is really a bad `txn` -- an empty one, in fact, since sprintf() with a
  # NULL argument returns character(0) and stop() then raises no text at all.
  if (!inherits(txn, "mdbx_txn")) {
    return(name)
  }

  if (!identical(token, attr(txn, "token"))) {
    # Same path, different token: the environment it was opened in has been
    # closed and another opened in its place. Naming the path twice would read
    # as a mistake, so say what actually happened.
    stop(
      if (identical(path, attr(txn, "path"))) {
        sprintf(paste0(
          "this database handle belongs to an environment at '%s' that has ",
          "since been closed; the one open there now is a different ",
          "environment. Open the database again in this transaction"
        ), path)
      } else {
        sprintf(
          "this database handle belongs to the environment at '%s', not '%s'",
          path, attr(txn, "path")
        )
      },
      call. = FALSE
    )
  }

  name
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
#' Emptying or deleting the database can reset the counter to zero — see
#' [mdbx_dbi_drop()].
#'
#' @param txn An `mdbx_txn` object from [mdbx_txn_begin()]. Incrementing needs a
#'   write transaction and is refused in a read one; reading the counter —
#'   `increment = 0` — works in either.
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
