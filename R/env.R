# Environment objects.
#
# An `mdbx_env` is an external pointer to the native MDBX handle, carrying the
# S3 class and the opening parameters as attributes. Both are attached natively
# when the object is built: modifying an external pointer from R can duplicate
# it, and a duplicate shares the address without inheriting the finalizer, so
# the original would close the environment out from under the copy.

#' Open an MDBX environment
#'
#' Opens, and by default creates, an MDBX environment at `path`. An environment
#' is the unit that holds the memory map, the lock, and the databases within it;
#' transactions and all data access happen against one.
#'
#' The environment is closed when [mdbx_env_close()] is called on it, or when the
#' object is garbage collected, whichever happens first. Relying on garbage
#' collection is safe but not timely; close explicitly when the moment matters.
#'
#' @param path Path to the environment. With `subdir = FALSE` (the default) this
#'   is the data file itself, and the lock file is the same path with `-lck`
#'   appended. With `subdir = TRUE` it is a directory, which libmdbx populates
#'   with `mdbx.dat` and `mdbx.lck`.
#' @param readonly If `TRUE`, open for reading only; no write transaction can be
#'   started, and the environment must already exist.
#' @param create If `FALSE`, require the environment to exist already rather
#'   than creating it. This is a best-effort check rather than an atomic one:
#'   libmdbx has no "open but never create" flag, so the existence test and the
#'   open are two steps, and another process deleting the database in between
#'   would leave a fresh one created here.
#' @param subdir Selects the on-disk layout described under `path`. It applies
#'   only when creating; opening an existing environment detects the layout.
#' @param max_dbs How many named databases to make room for. The default of 16
#'   is this package's, not libmdbx's: libmdbx reserves none, which makes
#'   [mdbx_dbi_open()] fail with `MDBX_DBS_FULL` on an environment opened with
#'   default arguments. Unused slots cost nothing. Each name that
#'
#'   Each name that [mdbx_dbi_open()] resolves occupies one slot. Raise this if
#'   you need more than 16, or pass `NULL` to take libmdbx's default of none —
#'   which leaves only the unnamed main database usable.
#' @param map_size Upper bound, in bytes, on the size the memory map may grow
#'   to, or `NULL` for the libmdbx default. Only the upper bound is set; the
#'   initial size and growth behaviour stay at their defaults.
#' @param max_readers Number of reader slots to make room for, or `NULL` for the
#'   libmdbx default. One slot is used per process holding a read transaction,
#'   so this is the ceiling on concurrent readers across all processes — see
#'   [mdbx-concurrency]. The default is derived from the lock file's page size
#'   (a few hundred, platform-dependent); raise it only if you expect more
#'   concurrent reader processes than that. It sizes the lock file, so it takes
#'   effect only for the first process to open the environment.
#' @param mode File permissions for a newly created database, as a string of
#'   octal digits or an [octmode] object. The default `"0664"` is libmdbx's own,
#'   and is masked by the process `umask` as usual — so it typically lands as
#'   `0644`, readable by everyone. Pass `"0600"` for a database only its owner
#'   can read. Ignored when the database already exists.
#' @param flags A character vector of 'libmdbx' flag names, or `NULL` for none.
#'   These are the remaining `MDBX_*` environment flags, with the prefix
#'   dropped — [mdbx_flags()] lists them and explains what each does.
#'
#'   The durability flags live here: `"NOMETASYNC"`, `"SAFE_NOSYNC"` and
#'   `"UTTERLY_NOSYNC"` each make commits cheaper by giving up some of what a
#'   crash cannot take away, and the last of the three can leave the database
#'   corrupt. The default — passing nothing — is fully durable. Read the
#'   Durability section of [mdbx_flags()] before using any of them.
#'
#' @return An `mdbx_env` object.
#' @seealso [mdbx_env_close()], [mdbx_env_is_open()], [mdbx_flags()],
#'   [mdbx-concurrency]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#'
#' env <- mdbx_env_open(path)
#' env
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_env_open <- function(path,
                      readonly = FALSE,
                      create = TRUE,
                      subdir = FALSE,
                      max_dbs = 16L,
                      map_size = NULL,
                      max_readers = NULL,
                      mode = "0664",
                      flags = NULL) {
  path <- path.expand(check_string(path, "path"))
  readonly <- check_bool(readonly, "readonly")
  create <- check_bool(create, "create")
  subdir <- check_bool(subdir, "subdir")
  max_dbs <- check_size(max_dbs, "max_dbs")
  map_size <- check_size(map_size, "map_size", max_native_integer())
  max_readers <- check_readers(max_readers)
  mode <- check_mode(mode)
  flags <- check_flags(flags, "env", "flags")

  # libmdbx would report a bare ENOENT here; say which argument forbade the
  # creation that would otherwise have happened.
  if ((!create || readonly) && !env_exists(path)) {
    stop(
      sprintf(
        "mdbx environment '%s' does not exist, and %s",
        path,
        if (readonly) "readonly = TRUE cannot create one" else "create = FALSE"
      ),
      call. = FALSE
    )
  }

  mdbx_env_open_(path, readonly, subdir, max_dbs, map_size, max_readers,
                 mode, flags)
}

#' Close an MDBX environment
#'
#' Closes the environment and releases its native resources. Closing is
#' idempotent: calling it on an already-closed environment does nothing, so it
#' is safe to pair an explicit close with an `on.exit()` guard.
#'
#' Closing is refused while any transaction on the environment is still open,
#' because 'libmdbx' documents that using a transaction after its environment
#' closes is undefined behaviour. Commit or abort them first — or use
#' [mdbx_with_read()] / [mdbx_with_write()], which cannot leave one open.
#'
#' Using a closed environment for anything else is an error rather than a
#' crash.
#'
#' @param env An `mdbx_env` object, from [mdbx_env_open()].
#' @return `NULL`, invisibly.
#' @seealso [mdbx_env_open()], [mdbx_env_is_open()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' mdbx_env_close(env)
#' mdbx_env_is_open(env)
#'
#' unlink(c(path, paste0(path, "-lck")))
mdbx_env_close <- function(env) {
  mdbx_env_close_(env)
  invisible(NULL)
}

#' Is an MDBX environment still open?
#'
#' @param env An `mdbx_env` object, from [mdbx_env_open()].
#' @return `TRUE` if the environment is open and usable, `FALSE` once it has
#'   been closed.
#' @seealso [mdbx_env_open()], [mdbx_env_close()]
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' mdbx_env_is_open(env)
#' mdbx_env_close(env)
#' mdbx_env_is_open(env)
#'
#' unlink(c(path, paste0(path, "-lck")))
mdbx_env_is_open <- function(env) {
  mdbx_env_is_open_(env)
}

#' @export
print.mdbx_env <- function(x, ...) {
  cat("<mdbx_env>", attr(x, "path"), "\n")
  cat("  access:", if (isTRUE(attr(x, "readonly"))) "read-only" else "read-write", "\n")
  cat("  layout:", if (isTRUE(attr(x, "subdir"))) "directory" else "single file", "\n")
  cat("  status:", if (mdbx_env_is_open(x)) "open" else "closed", "\n")
  invisible(x)
}

# libmdbx rejects anything outside 1..MDBX_READERS_LIMIT with a bare EINVAL;
# naming the bound here is friendlier, and the native call remains the backstop.
max_readers_limit <- 32767

check_readers <- function(x) {
  if (is.null(x)) {
    return(0)
  }
  x <- check_size(x, "max_readers")
  if (x > max_readers_limit) {
    stop(sprintf("`max_readers` must be at most %d, libmdbx's limit",
                 max_readers_limit), call. = FALSE)
  }
  x
}

# Accepts what Sys.chmod() accepts: octal digits as a string, or an octmode.
# A bare number would be ambiguous -- 600 is not 0600 -- so it is refused.
check_mode <- function(x) {
  if (inherits(x, "octmode")) {
    x <- format(x)
  }
  if (!is.character(x) || length(x) != 1L || is.na(x) ||
      !grepl("^[0-7]{3,4}$", x)) {
    stop('`mode` must be octal digits as a string, such as "0600", or an octmode object',
         call. = FALSE)
  }
  strtoi(x, base = 8L)
}

# Does an environment already exist at `path`?
#
# Not the same question as file.exists(). A directory satisfies file.exists()
# while containing no database at all, and libmdbx detects the directory layout
# and happily creates one inside -- so `create = FALSE` used to create a
# database in any existing empty directory.
env_exists <- function(path) {
  if (!file.exists(path)) {
    return(FALSE)
  }
  if (dir.exists(path)) {
    return(file.exists(file.path(path, "mdbx.dat")))
  }
  TRUE
}

check_string <- function(x, arg) {
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    stop(sprintf("`%s` must be a single non-empty string", arg), call. = FALSE)
  }
  x
}

check_bool <- function(x, arg) {
  if (!is.logical(x) || length(x) != 1L || is.na(x)) {
    stop(sprintf("`%s` must be TRUE or FALSE", arg), call. = FALSE)
  }
  x
}

# The largest integer a double represents exactly. Above this, doubles cannot
# even hold consecutive integers, and every native type these values are cast
# to is narrower still -- so bounding here is what stops an out-of-range
# double->integer conversion, which is undefined behaviour in C++, rather than
# an error. Comparing against the destination type's own maximum would not
# work: PTRDIFF_MAX is 2^63 - 1, which rounds *up* to 2^63 as a double, so
# `x > (double) PTRDIFF_MAX` lets exactly 2^63 through to a cast that cannot
# hold it.
max_exact_integer <- 2^53

# Arguments that reach an `intptr_t` or a `size_t` need a narrower bound than
# that: both stop at 2^31 - 1 on a 32-bit build, where 2^53 would let a value
# through to exactly the cast it is meant to protect.
max_native_integer <- function() {
  if (.Machine$sizeof.pointer >= 8) max_exact_integer else 2^31 - 1
}

# Counts, sizes and limits are whole numbers. Truncating a fraction silently is
# worse than refusing it: `limit = 1.9` returning one record and
# `increment = 0.5` doing nothing are wrong answers rather than errors.
check_whole <- function(x, arg) {
  if (x != trunc(x)) {
    stop(sprintf("`%s` must be a whole number, not %s", arg, format(x)),
         call. = FALSE)
  }
  invisible(NULL)
}

# NULL means "leave the libmdbx default alone", which the native layer spells
# as a non-positive value.
check_size <- function(x, arg, bound = max_exact_integer,
                       null_hint = "the libmdbx default") {
  if (is.null(x)) {
    return(0)
  }
  if (!is.numeric(x) || length(x) != 1L || !is.finite(x) || x <= 0) {
    stop(
      sprintf("`%s` must be a single positive number, or NULL for %s", arg, null_hint),
      call. = FALSE
    )
  }
  check_whole(x, arg)
  if (x > bound) {
    stop(
      sprintf("`%s` is too large: at most %.0f on this platform", arg, bound),
      call. = FALSE
    )
  }
  as.double(x)
}

#' Reclaim reader slots from processes that died
#'
#' A process holding a read transaction occupies a slot in the environment's
#' reader table. If it exits without ending the transaction — killed, crashed,
#' or `SIGKILL`ed — the slot stays occupied. Enough of those and new readers
#' fail with `MDBX_READERS_FULL` even though nothing is actually reading.
#'
#' This asks 'libmdbx' to check every occupied slot and release the ones whose
#' owning process is gone. It is safe to call at any time and costs nothing when
#' there is nothing to reclaim, so it is a reasonable thing to run when opening
#' a long-lived environment that other processes also use.
#'
#' Raising [mdbx_env_open()]'s `max_readers` makes the table bigger; this makes
#' room in the table you have. See [mdbx-concurrency].
#'
#' @param env An `mdbx_env` object, from [mdbx_env_open()].
#' @return The number of stale slots that were released, invisibly. Zero when
#'   every occupied slot belongs to a live process.
#' @seealso [mdbx_env_info()], which reports `numreaders` and `maxreaders`.
#' @export
#' @examples
#' path <- tempfile(fileext = ".mdbx")
#' env <- mdbx_env_open(path)
#'
#' # Nothing has died, so nothing is reclaimed.
#' mdbx_env_reader_check(env)
#'
#' mdbx_env_close(env)
#' unlink(c(path, paste0(path, "-lck")))
mdbx_env_reader_check <- function(env) {
  invisible(mdbx_env_reader_check_(env))
}
