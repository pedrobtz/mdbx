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

  # R has no way to set an external pointer's tag, so a pointer from anywhere
  # else cannot be dressed up as either handle.
  stranger <- methods::new("externalptr")
  class(stranger) <- "mdbx_env"
  expect_error(mdbx_env_stat(stranger), "expected an 'mdbx_env' object")
  expect_error(mdbx_env_close(stranger), "expected an 'mdbx_env' object")

  # The genuine article is unaffected.
  env3 <- local_env()
  expect_type(mdbx_env_stat(env3), "list")
  expect_true(mdbx_env_is_open(env3))
})
