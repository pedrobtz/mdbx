# Environment and transaction flags.
#
# libmdbx takes flags as an OR'ed bitmask. R has no comfortable idiom for that,
# so these are named: a character vector of the C names with the `MDBX_` prefix
# dropped. The vocabulary itself comes from C (see src/r_flags.cpp), so the
# accepted names and their bits cannot drift from the vendored header.

#' Flags accepted by 'libmdbx'
#'
#' Lists the flag names [mdbx_env_open()], [mdbx_txn_begin()] and
#' [mdbx_env_set_flags()] accept. They are 'libmdbx''s own names with the
#' `MDBX_` prefix dropped, so anything written about `MDBX_SAFE_NOSYNC` upstream
#' applies to `"SAFE_NOSYNC"` here.
#'
#' @section Durability:
#'
#' By default every commit is fully durable: data and metadata are flushed
#' before [mdbx_txn_commit()] returns, and a crash at any moment leaves the
#' database intact. Three flags trade that away, in increasing order of risk:
#'
#' \describe{
#'   \item{`"NOMETASYNC"`}{Skips the metadata flush. A system crash may undo the
#'     last committed transaction. Integrity is never at risk.}
#'   \item{`"SAFE_NOSYNC"`}{Flushes nothing on commit. A crash rolls the database
#'     back to the last steady commit — recent transactions are lost, but the
#'     database **cannot be corrupted**. The cost is file growth, because pages
#'     freed since that steady point cannot be reused; [mdbx_env_sync()]
#'     establishes a new one.}
#'   \item{`"UTTERLY_NOSYNC"`}{As above, but previous steady commits are wiped
#'     too. A crash shortly after a commit **can corrupt the database beyond
#'     recovery**. 'libmdbx''s own documentation cites a messenger that lost
#'     user data this way. Suitable only for data you are prepared to
#'     regenerate from scratch.}
#' }
#'
#' Measure before reaching for these. The cost they remove is per-*commit*, not
#' per-write: on a benchmark of the vendored library, 2000 single-write
#' transactions ran 89x faster under `"SAFE_NOSYNC"`, while one transaction of
#' 200000 writes ran 1.1x faster. Batching writes into fewer transactions is
#' usually the same win at no risk.
#'
#' @section Other flags:
#'
#' `"WRITEMAP"` maps the database writable and updates it in place, which is
#' faster but exposes the map to stray writes from the process; it also changes
#' what `"SAFE_NOSYNC"` does, to asynchronous mmap flushes. `"LIFORECLAIM"`
#' reuses the most recently freed pages first, which suits filesystems with
#' copy-on-write or trim. `"NORDAHEAD"` suppresses readahead for databases
#' larger than RAM, `"NOMEMINIT"` skips zero-filling new pages, `"EXCLUSIVE"`
#' takes the environment for this process alone, `"ACCEDE"` accepts the flags an
#' existing environment was opened with rather than conflicting with them, and
#' `"VALIDATION"` turns on expensive internal checking for debugging.
#'
#' @section What is not here:
#'
#' `"RDONLY"` and `"NOSUBDIR"` are reported but not settable, because they are
#' the `readonly` and `subdir` arguments of [mdbx_env_open()]. `NOSTICKYTHREADS`
#' is never set: it lifts 'libmdbx''s one-transaction-per-thread rule, which
#' this package's transaction registry and finalizer ordering rely on.
#'
#' @return A data frame with one row per flag and the columns `flag`, `scope`
#'   (`"env"` or `"txn"`), `settable` (accepted by [mdbx_env_open()] or
#'   [mdbx_txn_begin()]) and `runtime` (accepted by [mdbx_env_set_flags()]).
#' @seealso [mdbx_env_open()], [mdbx_env_set_flags()], [mdbx_env_sync()]
#' @export
#' @examples
#' mdbx_flags()
#'
#' # The durability flags, and where each may be set.
#' flags <- mdbx_flags()
#' flags[grepl("SYNC", flags$flag), ]
mdbx_flags <- function() {
  as.data.frame(mdbx_flags_(), stringsAsFactors = FALSE)
}

#' Flags an environment is using
#'
#' Reports every flag in effect on an open environment, including the ones
#' [mdbx_env_open()] set from its own `readonly` and `subdir` arguments — this
#' describes the environment, not the call that made it.
#'
#' Flags can appear that were never asked for. 'libmdbx' normalizes the sync
#' modes, so both `"SAFE_NOSYNC"` and `"UTTERLY_NOSYNC"` also report
#' `"NOMETASYNC"` — the weaker relaxation is implied by the stronger one, and
#' clearing the stronger one does not clear it. `"UTTERLY_NOSYNC"` does *not*
#' additionally report `"SAFE_NOSYNC"`, whose bits it contains: naming both
#' would describe one durability mode as two. An environment another process
#' opened first may also carry flags this one did not ask for; that is what
#' `"ACCEDE"` is about.
#'
#' 'libmdbx' keeps internal state in the same word, which is not reported here:
#' only the names in [mdbx_flags()] are ever returned.
#'
#' @param env An `mdbx_env` object, from [mdbx_env_open()].
#' @return A character vector of flag names, empty if the environment is at
#'   'libmdbx''s defaults in every respect.
#' @seealso [mdbx_flags()], [mdbx_env_set_flags()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path, flags = "NOMETASYNC")
#'
#' mdbx_env_get_flags(env)
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_env_get_flags <- function(env) {
  mdbx_env_get_flags_(env)
}

#' Change an environment's flags
#'
#' Sets or clears flags on an open environment. Only the flags 'libmdbx'
#' documents as changeable at any time can be set this way — `mdbx_flags()$runtime`
#' marks them; the rest are fixed when the environment is opened.
#'
#' This is refused while a transaction is open, because 'libmdbx' serializes
#' flag changes against the writer lock and would return `MDBX_BUSY`. Changing
#' durability between transactions is the intended use: relax it for a bulk
#' load, restore it and call [mdbx_env_sync()] afterwards.
#'
#' @param env An `mdbx_env` object, from [mdbx_env_open()].
#' @param flags A character vector of flag names — see [mdbx_flags()].
#' @param on `TRUE` to set the flags, `FALSE` to clear them.
#' @return `NULL`, invisibly.
#' @seealso [mdbx_flags()], [mdbx_env_get_flags()], [mdbx_env_sync()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' # Bulk load without paying for a flush per commit.
#' mdbx_env_set_flags(env, "SAFE_NOSYNC")
#' for (i in 1:10) {
#'   mdbx_with_write(env, function(txn) mdbx_put(txn, sprintf("k%d", i), "v"))
#' }
#'
#' # Then make it durable again, and flush what is outstanding.
#' mdbx_env_set_flags(env, "SAFE_NOSYNC", on = FALSE)
#' mdbx_env_sync(env)
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_env_set_flags <- function(env, flags, on = TRUE) {
  on <- check_bool(on, "on")
  flags <- check_flags(flags, "env_runtime", "flags")

  if (length(flags) == 0L) {
    stop("`flags` must name at least one flag", call. = FALSE)
  }

  mdbx_env_set_flags_(env, flags, on)
  invisible(NULL)
}

#' Flush an environment to disk
#'
#' Writes and flushes any data a relaxed durability mode has left outstanding.
#' With the default durability there is never anything to flush, because
#' [mdbx_txn_commit()] has already done it.
#'
#' Under `"SAFE_NOSYNC"` this also establishes a new steady commit point, which
#' is what lets 'libmdbx' start reusing freed pages again — so it bounds file
#' growth as well as making data durable.
#'
#' @param env An `mdbx_env` object, from [mdbx_env_open()].
#' @param force If `TRUE`, always flush. If `FALSE`, flush only if a threshold
#'   set on the environment has been reached, which is 'libmdbx''s polling mode.
#' @param nonblock If `TRUE`, give up rather than wait when another process is
#'   in a write transaction. The wait is signalled as an `MDBX_BUSY` error.
#' @return Invisibly, `TRUE` if there was unsynced data and it was written, or
#'   `FALSE` if nothing was pending.
#' @seealso [mdbx_flags()], [mdbx_env_set_flags()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path, flags = "SAFE_NOSYNC")
#'
#' mdbx_with_write(env, function(txn) mdbx_put(txn, "k", "v"))
#'
#' # The commit above flushed nothing; this does.
#' mdbx_env_sync(env)
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_env_sync <- function(env, force = TRUE, nonblock = FALSE) {
  force <- check_bool(force, "force")
  nonblock <- check_bool(nonblock, "nonblock")

  # libmdbx would report MDBX_EACCES; name the actual conflict instead.
  if (isTRUE(attr(env, "readonly"))) {
    stop("cannot sync a read-only environment: it has nothing unwritten",
         call. = FALSE)
  }

  invisible(mdbx_env_sync_(env, force, nonblock))
}

# Validate flag names against the vocabulary C owns, and say something useful
# about the ways they are usually got wrong. `scope` is "env" (settable at
# open), "env_runtime" (settable on a live environment) or "txn".
check_flags <- function(flags, scope, arg) {
  if (is.null(flags)) {
    return(character(0))
  }
  if (!is.character(flags) || anyNA(flags)) {
    stop(
      sprintf("`%s` must be a character vector of flag names, or NULL for none", arg),
      call. = FALSE
    )
  }

  flags <- unique(flags)
  unknown <- setdiff(flags, allowed_flags(scope))

  if (length(unknown) > 0L) {
    stop(flag_message(unknown[[1]], scope, arg), call. = FALSE)
  }

  flags
}

allowed_flags <- function(scope) {
  table <- mdbx_flags()

  if (scope == "txn") {
    return(table$flag[table$scope == "txn" & table$settable])
  }
  if (scope == "env_runtime") {
    return(table$flag[table$scope == "env" & table$runtime])
  }
  table$flag[table$scope == "env" & table$settable]
}

# One rejected name, explained. Each branch is a mistake worth naming rather
# than answering with a bare list of what would have been valid.
flag_message <- function(name, scope, arg) {
  table <- mdbx_flags()
  known <- table$flag[table$scope == if (scope == "txn") "txn" else "env"]
  bare <- sub("^MDBX_(TXN_)?", "", name)

  detail <- if (bare != name && bare %in% known) {
    sprintf('use "%s"; the MDBX_ prefix is not part of the name', bare)
  } else if (scope != "txn" && name == "RDONLY") {
    "use `readonly = TRUE` on mdbx_env_open() instead"
  } else if (scope != "txn" && name == "NOSUBDIR") {
    "use `subdir = FALSE` on mdbx_env_open() instead"
  } else if (name == "NOSTICKYTHREADS") {
    paste(
      "this package never sets it: it lifts libmdbx's one-transaction-per-thread",
      "rule, which the transaction lifecycle depends on"
    )
  } else if (scope == "txn" && name %in% table$flag[table$scope == "env"]) {
    "that is an environment flag; set it on mdbx_env_open() or mdbx_env_set_flags()"
  } else if (scope == "env_runtime" && name %in% known) {
    "libmdbx only allows that flag to be set when the environment is opened"
  } else {
    paste("valid names are", paste(sort(allowed_flags(scope)), collapse = ", "))
  }

  sprintf('`%s` contains "%s": %s', arg, name, detail)
}
