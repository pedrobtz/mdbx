# Transactions.
#
# An `mdbx_txn` is an external pointer holding the native handle, retaining its
# environment in the protected field so R cannot collect the environment while
# the transaction is reachable. As for `mdbx_env`, class and attributes are
# attached natively; R only reads them.

#' Begin a transaction
#'
#' Starts a transaction against an open environment. Everything read or written
#' happens inside one: reads see a consistent snapshot taken when the
#' transaction began, and writes become visible to others only on commit.
#'
#' 'libmdbx' binds a transaction to the thread that started it, so an
#' environment supports **one transaction at a time per thread** — and R is
#' single-threaded, so that means one at a time. Beginning a second while one is
#' open is an error, never a deadlock or a hang. Distinct environments are
#' independent, and concurrency comes from separate processes: many readers and
#' one writer may hold transactions on the same environment simultaneously.
#'
#' A transaction must be ended with [mdbx_txn_commit()] or [mdbx_txn_abort()]. One
#' abandoned to the garbage collector is aborted, but that is a backstop rather
#' than a plan: a live write transaction holds the writer lock until it ends.
#' [mdbx_with_read()] and [mdbx_with_write()] handle this for you.
#'
#' @param env An `mdbx_env` object, from [mdbx_env_open()].
#' @param write If `TRUE`, start a read-write transaction; the environment must
#'   not have been opened with `readonly = TRUE`.
#' @param flags A character vector of 'libmdbx' transaction flag names, or
#'   `NULL` for none. `"NOMETASYNC"` and `"NOSYNC"` relax durability for this
#'   one transaction, exactly as the environment flags of the same names do for
#'   every transaction — see the Durability section of [mdbx_flags()].
#'   `"TRY"` fails with `MDBX_BUSY` rather than waiting for another process's
#'   writer. All three apply to write transactions only.
#'
#' @return An `mdbx_txn` object.
#' @seealso [mdbx_txn_commit()], [mdbx_txn_abort()], [mdbx_with_write()],
#'   [mdbx_flags()], [mdbx-concurrency]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' txn <- mdbx_txn_begin(env)
#' txn
#' mdbx_txn_abort(txn)
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_txn_begin <- function(env, write = FALSE, flags = NULL) {
  write <- check_bool(write, "write")
  flags <- check_flags(flags, "txn", "flags")

  # libmdbx would report MDBX_EACCES; name the actual conflict instead.
  if (write && isTRUE(attr(env, "readonly"))) {
    stop("cannot begin a write transaction on a read-only environment", call. = FALSE)
  }

  # All three transaction flags concern committing or waiting for the writer
  # lock, neither of which a read transaction does. Passing one is a
  # misunderstanding rather than a no-op worth honouring silently.
  if (!write && length(flags) > 0L) {
    stop(
      sprintf(
        "`flags` applies to write transactions only; got %s with write = FALSE",
        paste(sprintf('"%s"', flags), collapse = ", ")
      ),
      call. = FALSE
    )
  }

  mdbx_txn_begin_(env, write, flags)
}

#' Commit a transaction
#'
#' Makes the transaction's writes durable and visible to other readers, and ends
#' the transaction.
#'
#' Unlike [mdbx_txn_abort()], this is not idempotent: committing an already-finished
#' transaction is an error, because the second call cannot do what it appears
#' to. Note also that a commit which cannot complete is turned into an abort by
#' 'libmdbx' — if this raises an error, the transaction has still ended, and its
#' writes are gone.
#'
#' Some failures inside a transaction end it there and then. A rejected key or
#' value size ([mdbx_put()] returning `MDBX_BAD_VALSIZE`) is just that one
#' operation failing, and the transaction carries on. A failure that exhausts
#' the map (`MDBX_MAP_FULL`) instead marks the transaction unusable: every later
#' operation fails with `MDBX_BAD_TXN`, and the commit reports that the whole
#' transaction was rolled back rather than committed. [mdbx_txn_state()] reads
#' `"aborted"` in that case.
#'
#' @param txn An `mdbx_txn` object, from [mdbx_txn_begin()].
#' @return `NULL`, invisibly.
#' @seealso [mdbx_txn_begin()], [mdbx_txn_abort()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' txn <- mdbx_txn_begin(env, write = TRUE)
#' mdbx_txn_commit(txn)
#' mdbx_txn_state(txn)
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_txn_commit <- function(txn) {
  mdbx_txn_commit_(txn)
  invisible(NULL)
}

#' Abort a transaction
#'
#' Discards the transaction's writes and ends it. Aborting is idempotent: doing
#' it to an already-finished transaction does nothing, so it is safe to register
#' with `on.exit()` alongside an explicit [mdbx_txn_commit()].
#'
#' @param txn An `mdbx_txn` object, from [mdbx_txn_begin()].
#' @return `NULL`, invisibly.
#' @seealso [mdbx_txn_begin()], [mdbx_txn_commit()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' txn <- mdbx_txn_begin(env, write = TRUE)
#' mdbx_txn_abort(txn)
#' mdbx_txn_abort(txn) # already aborted; does nothing
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_txn_abort <- function(txn) {
  mdbx_txn_abort_(txn)
  invisible(NULL)
}

#' State of a transaction
#'
#' @param txn An `mdbx_txn` object, from [mdbx_txn_begin()].
#' @return One of `"active"`, `"committed"`, or `"aborted"`. `"poisoned"` is
#'   reported for a transaction abandoned after a 'libmdbx' assertion failure,
#'   and `"invalid"` for one whose handle has already been reclaimed.
#' @seealso [mdbx_txn_begin()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' txn <- mdbx_txn_begin(env)
#' mdbx_txn_state(txn)
#' mdbx_txn_abort(txn)
#' mdbx_txn_state(txn)
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_txn_state <- function(txn) {
  mdbx_txn_state_(txn)
}

#' Run code inside a transaction
#'
#' Begins a transaction, calls `fun` with it, and ends it — whatever happens.
#' `mdbx_with_write()` commits if `fun` returns normally and aborts if it throws;
#' `mdbx_with_read()` always aborts, which for a read transaction simply releases
#' the snapshot. Both use `on.exit()`, so the transaction is also ended if `fun`
#' is interrupted.
#'
#' This is the recommended way to use transactions: it makes the "abandoned a
#' write transaction and kept the writer lock" mistake unreachable.
#'
#' @param env An `mdbx_env` object, from [mdbx_env_open()].
#' @param fun A function of one argument, called with the `mdbx_txn`.
#' @return The value of `fun`.
#' @seealso [mdbx_txn_begin()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' # Committed on normal return.
#' mdbx_with_write(env, function(txn) mdbx_txn_state(txn))
#'
#' mdbx_with_read(env, function(txn) mdbx_txn_state(txn))
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_with_write <- function(env, fun) {
  fun <- check_function(fun, "fun")

  txn <- mdbx_txn_begin(env, write = TRUE)
  # A no-op once the commit below has run, so this covers only the paths that
  # do not reach it: an error, or an interrupt.
  on.exit(mdbx_txn_abort(txn), add = TRUE)

  # withVisible, so that a block ending in an invisible call -- mdbx_put(), say
  # -- does not become visible just by passing through this wrapper.
  result <- withVisible(fun(txn))
  mdbx_txn_commit(txn)

  if (result$visible) result$value else invisible(result$value)
}

#' @rdname mdbx_with_write
#' @export
mdbx_with_read <- function(env, fun) {
  fun <- check_function(fun, "fun")

  txn <- mdbx_txn_begin(env, write = FALSE)
  on.exit(mdbx_txn_abort(txn), add = TRUE)

  result <- withVisible(fun(txn))
  if (result$visible) result$value else invisible(result$value)
}

#' @export
print.mdbx_txn <- function(x, ...) {
  cat("<mdbx_txn>", attr(x, "path"), "\n")
  cat("  mode: ", if (isTRUE(attr(x, "write"))) "read-write" else "read-only", "\n")
  cat("  state:", mdbx_txn_state(x), "\n")
  invisible(x)
}

check_function <- function(x, arg) {
  if (!is.function(x)) {
    stop(sprintf("`%s` must be a function", arg), call. = FALSE)
  }
  x
}
