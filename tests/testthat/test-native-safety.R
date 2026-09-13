test_that("package initialization silences the libmdbx after-fork notice", {
  skip_if_cannot_fork()

  log_file <- tempfile()
  connection <- file(log_file, open = "wt")
  sink_depth <- sink.number(type = "message")
  connection_open <- TRUE

  on.exit({
    while (sink.number(type = "message") > sink_depth) {
      sink(type = "message")
    }
    if (connection_open) {
      close(connection)
    }
  }, add = TRUE)

  sink(connection, type = "message")
  # Positive control: proves the capture below is actually wired up, so a sink
  # that silently stopped working could not make this test pass vacuously.
  message("fork-capture-control")
  job <- parallel::mcparallel(invisible(TRUE))
  result <- parallel::mccollect(job)
  sink(type = "message")
  close(connection)
  connection_open <- FALSE

  captured <- readLines(log_file, warn = FALSE)

  expect_identical(unname(result), list(TRUE))
  expect_true(any(grepl("fork-capture-control", captured, fixed = TRUE)))

  # libmdbx's after-fork hook (rthc_afterfork) logs at NOTICE: one "drown %d
  # rthc entries" line, plus a "drown env %p" line per live environment.
  # Package load lowers the global level to FATAL so none of them reach the
  # console. Assert on that signature rather than on an empty stream: other
  # lines here belong to the front-end -- Positron writes its own when forking
  # -- and silencing those is not this package's contract.
  expect_identical(grep("drown|rthc", captured, value = TRUE), character(0))
})

test_that("a guarded panic poisons its owner before becoming an R error", {
  expect_error(
    mdbx:::mdbx_test_panic_boundary_(),
    "libmdbx assertion failed: panic-boundary test"
  )

  # The panic was contained below C++, so the DLL remains callable.
  expect_identical(mdbx_version()$major, 0L)
})

test_that("a panic inside stat or info poisons the environment", {
  for (info in c(FALSE, TRUE)) {
    env <- local_env()
    expect_error(mdbx:::mdbx_test_panic_stat_(env, info),
                 "libmdbx assertion failed: stat-guard test")

    # The point of poisoning: nothing may re-enter an environment whose
    # invariants have just failed. These two calls used to install no poison
    # callback at all, so a panic in them became an R error while leaving the
    # handle apparently usable.
    expect_error(mdbx_env_stat(env), "unusable after a libmdbx assertion")
    expect_error(mdbx_env_info(env), "unusable after a libmdbx assertion")
    expect_error(mdbx_txn_begin(env), "unusable after a libmdbx assertion")

    # Closing is the one thing that must still work, and it must not re-enter
    # libmdbx: the handle is dropped and the mapping left to the OS.
    expect_silent(mdbx_env_close(env))
    expect_false(mdbx_env_is_open(env))
  }
})

test_that("a handle is identified by its tag, not by its class attribute", {
  # `class<-` on an external pointer modifies it in place -- there is no copy to
  # reclass -- so each forgery below needs a handle of its own.
  env <- local_env()
  txn <- mdbx_txn_begin(env)

  # Both handle types are EXTPTRSXP, so the class was the only thing telling
  # them apart. Reclassing a transaction as an environment used to make the
  # entry point read a txn_handle as an env_handle, reporting a fabricated
  # owner pid from the wrong offset -- and mdbx_env_close() read a garbage
  # transaction count the same way.
  class(txn) <- "mdbx_env"
  expect_error(mdbx_env_stat(txn), "expected an 'mdbx_env' object")
  expect_error(mdbx_env_info(txn), "expected an 'mdbx_env' object")
  expect_error(mdbx_env_close(txn), "expected an 'mdbx_env' object")
  expect_error(mdbx_env_is_open(txn), "expected an 'mdbx_env' object")

  env2 <- local_env()
  class(env2) <- "mdbx_txn"
  expect_error(mdbx_get(env2, "k"), "expected an 'mdbx_txn' object")
  expect_error(mdbx_txn_commit(env2), "expected an 'mdbx_txn' object")

  # The state-tolerant entry points have to authenticate too, and used not to:
  # they checked the class and then read an env_handle through the txn_handle
  # layout. mdbx_txn_state() answered "aborted" for this, having read the
  # environment's pid where a txn_state belongs.
  expect_error(mdbx_txn_state(env2), "expected an 'mdbx_txn' object")
  expect_error(mdbx_txn_abort(env2), "expected an 'mdbx_txn' object")

  # R has no way to set an external pointer's tag, so a pointer from anywhere
  # else cannot be dressed up as either handle.
  stranger <- methods::new("externalptr")
  class(stranger) <- "mdbx_env"
  expect_error(mdbx_env_stat(stranger), "expected an 'mdbx_env' object")
  expect_error(mdbx_env_close(stranger), "expected an 'mdbx_env' object")

  another <- methods::new("externalptr")
  class(another) <- "mdbx_txn"
  expect_error(mdbx_txn_state(another), "expected an 'mdbx_txn' object")
  expect_error(mdbx_txn_abort(another), "expected an 'mdbx_txn' object")
  expect_error(mdbx_txn_commit(another), "expected an 'mdbx_txn' object")
  expect_error(mdbx_get(another, "k"), "expected an 'mdbx_txn' object")

  # The genuine article is unaffected.
  env3 <- local_env()
  expect_type(mdbx_env_stat(env3), "list")
  expect_true(mdbx_env_is_open(env3))

  # Including a finished transaction, which stays queryable and idempotently
  # abortable: authentication is not an excuse to forget its outcome.
  done <- mdbx_txn_begin(env3)
  mdbx_txn_abort(done)
  expect_identical(mdbx_txn_state(done), "aborted")
  expect_silent(mdbx_txn_abort(done))

  committed <- mdbx_txn_begin(env3, write = TRUE)
  mdbx_txn_commit(committed)
  expect_identical(mdbx_txn_state(committed), "committed")
  expect_silent(mdbx_txn_abort(committed))
})

test_that("a panic in a transaction operation poisons the environment too", {
  env <- local_env()
  txn <- mdbx_txn_begin(env)

  # Every transaction-backed poison callback but the scan's used to mark the
  # transaction alone. The finalizer then skipped the native abort a poisoned
  # handle must not make, unregistered itself, and left the environment
  # believing it had no transactions -- so its close handed libmdbx one that
  # was never ended.
  expect_error(mdbx:::mdbx_test_panic_get_(txn), "libmdbx assertion failed")

  expect_identical(mdbx_txn_state(txn), "poisoned")
  expect_false(mdbx_env_is_open(env))
  expect_error(mdbx_env_stat(env), "unusable after a libmdbx assertion")
})

test_that("a panic with a live transaction can still be cleaned up", {
  env <- local_env()
  txn <- mdbx_txn_begin(env)

  expect_error(mdbx:::mdbx_test_panic_stat_(env, FALSE), "libmdbx assertion failed")

  # Both handles report the panic rather than a lifecycle state that is no
  # longer true of either.
  expect_identical(mdbx_txn_state(txn), "poisoned")
  expect_false(mdbx_env_is_open(env))

  # Neither of these may re-enter libmdbx, and neither may refuse. Refusing is
  # what made a panic unrecoverable: abort was rejected because the environment
  # was poisoned, and close was rejected because the transaction was still
  # registered, so only dropping both references and forcing a GC released it.
  expect_silent(mdbx_txn_abort(txn))
  expect_silent(mdbx_env_close(env))
  expect_false(mdbx_env_is_open(env))

  # Once cleaned up it reads as ended rather than as poisoned: the transaction
  # is over, and "aborted" is what the caller needs to know about its writes.
  expect_identical(mdbx_txn_state(txn), "aborted")

  # Idempotent, and stable across the finalizers that run later.
  expect_silent(mdbx_txn_abort(txn))
  expect_silent(mdbx_env_close(env))
  gc()
  gc()
  expect_identical(mdbx_txn_state(txn), "aborted")
  expect_identical(mdbx_version()$major, 0L)
})

test_that("closing a poisoned environment detaches its transactions", {
  env <- local_env()
  txn <- mdbx_txn_begin(env)

  expect_error(mdbx:::mdbx_test_panic_stat_(env, FALSE), "libmdbx assertion failed")

  # Closing goes first this time, so the detaching is the close's own work
  # rather than something the abort already did.
  expect_silent(mdbx_env_close(env))

  # detach_txns() ended it, so it reads as aborted rather than still live.
  expect_identical(mdbx_txn_state(txn), "aborted")
  expect_silent(mdbx_txn_abort(txn))
  expect_identical(mdbx_version()$major, 0L)
})

test_that("cleanup after a panic does not replace the panic", {
  env <- local_env()

  # mdbx_with_*() end their transaction from on.exit(). While abort refused a
  # poisoned graph, that refusal was raised on the way out and became the
  # condition the caller saw -- destroying the only message that said what
  # libmdbx had actually found.
  message <- conditionMessage(tryCatch(
    mdbx_with_read(env, function(txn) mdbx:::mdbx_test_panic_stat_(env, FALSE)),
    error = identity
  ))

  expect_match(message, "libmdbx assertion failed", fixed = TRUE)
  expect_false(grepl("unusable after a libmdbx assertion", message, fixed = TRUE))

  expect_silent(mdbx_env_close(env))
  expect_identical(mdbx_version()$major, 0L)
})

test_that("a panic leaves no transaction registered against the environment", {
  gc()
  before <- mdbx:::mdbx_txn_live_count_()

  local({
    env <- local_env()
    txn <- mdbx_txn_begin(env, write = TRUE)
    expect_error(mdbx:::mdbx_test_panic_get_(txn), "libmdbx assertion failed")
    mdbx_txn_abort(txn)
    mdbx_env_close(env)
  })

  gc()
  gc()
  expect_identical(mdbx:::mdbx_txn_live_count_(), before)
})
