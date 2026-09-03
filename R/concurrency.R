#' Concurrency in mdbx
#'
#' How 'libmdbx' shares a database between threads and processes, and what that
#' means for R. This is the contract the rest of the package is built on; the
#' short version is **many readers and one writer, across processes, never
#' within one**.
#'
#' @section One transaction at a time per environment:
#'
#' 'libmdbx' binds a transaction to the thread that began it, and R is
#' single-threaded. An environment therefore supports exactly one live
#' transaction: [mdbx_txn_begin()] refuses a second rather than deadlocking, and
#' [mdbx_env_close()] refuses while one is open. Distinct environments — even
#' two opened on the same file in the same session — are independent.
#'
#' Using a transaction from another thread is rejected by 'libmdbx' itself, with
#' `MDBX_THREAD_MISMATCH`, because the package is compiled with
#' `MDBX_TXN_CHECKOWNER`. `mdbx_version()$build$options` shows that flag, and
#' the test suite asserts it actually fires rather than trusting the build.
#'
#' @section Concurrency comes from separate processes:
#'
#' Any number of processes may hold read transactions on one database at the
#' same time, and one of them may hold a write transaction while they do.
#' Writers are serialized against each other by a lock file: a second writer
#' waits, or fails immediately with `MDBX_BUSY` if the transaction was begun
#' with `flags = "TRY"`.
#'
#' Readers never block writers and writers never block readers. A read
#' transaction sees the snapshot that existed when it began and keeps it, even
#' as other processes commit — so a long-lived reader is safe, though it does
#' hold back the pages its snapshot needs. End read transactions promptly.
#'
#' @section fork() does not carry an environment with it:
#'
#' `parallel::mclapply()`, `parallel::mcparallel()` and anything else built on
#' `fork()` give the child a copy of the R object but not the mapping, lock or
#' reader slot behind it. 'libmdbx' invalidates the inherited environment in its
#' own after-fork hook.
#'
#' Using one in the child is therefore an error naming the fork, rather than a
#' crash: every entry point checks the process that opened the handle.
#' [mdbx_env_is_open()] reports `FALSE` in the child, and closing is refused, so
#' a worker cannot release a lock it never held.
#'
#' **Open the environment inside the worker instead.** Each process gets its own
#' handle, and the many-readers-one-writer rules above then apply normally:
#'
#' ```r
#' parallel::mclapply(keys, function(key) {
#'   env <- mdbx_env_open(path)
#'   on.exit(mdbx_env_close(env))
#'   mdbx_with_read(env, function(txn) mdbx_get(txn, key))
#' })
#' ```
#'
#' The same applies to `future`, `callr` and any other backend that forks. A
#' backend that starts fresh R processes instead has nothing to inherit, and
#' needs no special care beyond opening its own environment.
#'
#' @section Durability is per-environment, not per-process:
#'
#' Flags such as `"SAFE_NOSYNC"` are properties of the database as it is
#' currently open, and a process that opens an environment another process
#' already has open inherits its flags. `"ACCEDE"` asks for that explicitly
#' rather than failing on the difference. See [mdbx_flags()].
#'
#' @name mdbx-concurrency
#' @seealso [mdbx_txn_begin()], [mdbx_env_open()], [mdbx_flags()]
NULL
