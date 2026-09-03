test_that("a read transaction begins, reports itself, and aborts", {
  env <- local_env()

  txn <- mdbx_txn_begin(env)

  expect_s3_class(txn, "mdbx_txn")
  expect_identical(mdbx_txn_state(txn), "active")
  expect_output(print(txn), "<mdbx_txn>", fixed = TRUE)
  expect_output(print(txn), "read-only")
  expect_output(print(txn), "active")

  mdbx_txn_abort(txn)

  expect_identical(mdbx_txn_state(txn), "aborted")
  expect_output(print(txn), "aborted")
})

test_that("a write transaction commits", {
  env <- local_env()

  txn <- mdbx_txn_begin(env, write = TRUE)
  expect_output(print(txn), "read-write")

  mdbx_txn_commit(txn)
  expect_identical(mdbx_txn_state(txn), "committed")
})

test_that("a transaction retains its environment against garbage collection", {
  path <- tempfile(fileext = ".mdbx")

  # The only reference to the environment is the one the transaction holds in
  # its protected field. If retention were broken, the environment would be
  # finalized here and the transaction left dangling.
  txn <- local({
    env <- mdbx_env_open(path, map_size = test_map_size)
    mdbx_txn_begin(env)
  })

  gc()
  gc()

  expect_identical(mdbx_txn_state(txn), "active")
  expect_type(mdbx:::mdbx_txn_id_(txn), "double")

  mdbx_txn_abort(txn)
})

test_that("using a transaction after commit or abort is an error", {
  env <- local_env()

  committed <- mdbx_txn_begin(env, write = TRUE)
  mdbx_txn_commit(committed)
  expect_error(mdbx:::mdbx_txn_id_(committed), "already committed")

  aborted <- mdbx_txn_begin(env)
  mdbx_txn_abort(aborted)
  expect_error(mdbx:::mdbx_txn_id_(aborted), "already aborted")
})

test_that("committing twice is an error, aborting twice is not", {
  env <- local_env()

  txn <- mdbx_txn_begin(env, write = TRUE)
  mdbx_txn_commit(txn)
  expect_error(mdbx_txn_commit(txn), "already committed")

  # Abort stays idempotent so on.exit() can pair with an explicit commit.
  expect_silent(mdbx_txn_abort(txn))
  expect_identical(mdbx_txn_state(txn), "committed")

  other <- mdbx_txn_begin(env)
  mdbx_txn_abort(other)
  expect_silent(mdbx_txn_abort(other))
})

test_that("a write transaction cannot start on a read-only environment", {
  path <- tempfile(fileext = ".mdbx")
  mdbx_env_close(mdbx_env_open(path, map_size = test_map_size))

  env <- mdbx_env_open(path, readonly = TRUE, map_size = test_map_size)
  on.exit(mdbx_env_close(env), add = TRUE)

  expect_error(mdbx_txn_begin(env, write = TRUE), "read-only environment")
})

test_that("an environment allows only one transaction at a time", {
  # libmdbx binds a transaction to its thread, so every combination below is
  # refused in a single-threaded R session. It reports the rule as MDBX_BAD_RSLOT,
  # MDBX_TXN_OVERLAPPING or MDBX_BUSY depending on the pair; the binding reports
  # it once, clearly, and never blocks.
  for (held in c(FALSE, TRUE)) {
    env <- local_env()
    first <- mdbx_txn_begin(env, write = held)

    expect_error(mdbx_txn_begin(env, write = FALSE), "already has an open transaction")
    expect_error(mdbx_txn_begin(env, write = TRUE), "already has an open transaction")

    # The refusal left the held transaction untouched.
    expect_identical(mdbx_txn_state(first), "active")
    mdbx_txn_abort(first)

    # And the slot is free again once it ends.
    second <- mdbx_txn_begin(env, write = TRUE)
    expect_identical(mdbx_txn_state(second), "active")
    mdbx_txn_abort(second)
  }
})

test_that("distinct environments hold transactions independently", {
  first <- local_env()
  second <- local_env()

  a <- mdbx_txn_begin(first, write = TRUE)
  b <- mdbx_txn_begin(second, write = TRUE)

  expect_identical(mdbx_txn_state(a), "active")
  expect_identical(mdbx_txn_state(b), "active")
  expect_identical(mdbx:::mdbx_env_txn_count_(first), 1L)
  expect_identical(mdbx:::mdbx_env_txn_count_(second), 1L)

  mdbx_txn_abort(a)
  mdbx_txn_abort(b)
})

test_that("an environment refuses to close while a transaction is open", {
  env <- mdbx_env_open(tempfile(fileext = ".mdbx"), map_size = test_map_size)

  txn <- mdbx_txn_begin(env)
  expect_error(mdbx_env_close(env), "transaction")
  expect_true(mdbx_env_is_open(env))

  mdbx_txn_abort(txn)
  expect_silent(mdbx_env_close(env))
})

test_that("the environment's open-transaction registry stays exact", {
  env <- local_env()

  expect_identical(mdbx:::mdbx_env_txn_count_(env), 0L)

  a <- mdbx_txn_begin(env)
  expect_identical(mdbx:::mdbx_env_txn_count_(env), 1L)
  mdbx_txn_abort(a)
  expect_identical(mdbx:::mdbx_env_txn_count_(env), 0L)

  b <- mdbx_txn_begin(env, write = TRUE)
  expect_identical(mdbx:::mdbx_env_txn_count_(env), 1L)
  mdbx_txn_commit(b)
  expect_identical(mdbx:::mdbx_env_txn_count_(env), 0L)

  # A transaction dropped without ending it must also leave the registry.
  local(mdbx_txn_begin(env))
  gc()
  gc()
  expect_identical(mdbx:::mdbx_env_txn_count_(env), 0L)
})

test_that("an abandoned transaction is aborted by garbage collection", {
  env <- local_env()

  gc()
  before <- mdbx:::mdbx_txn_live_count_()

  local({
    txn <- mdbx_txn_begin(env, write = TRUE)
    expect_identical(mdbx_txn_state(txn), "active")
  })

  gc()
  gc()

  expect_identical(mdbx:::mdbx_txn_live_count_(), before)

  # The writer lock was released, so a new write transaction can start.
  txn <- mdbx_txn_begin(env, write = TRUE)
  mdbx_txn_abort(txn)
})

test_that("an environment and its transaction finalized together do not crash", {
  gc()
  envs_before <- mdbx:::mdbx_env_live_count_()
  txns_before <- mdbx:::mdbx_txn_live_count_()

  # Both become unreachable in the same cycle, so R may run the two finalizers
  # in either order. Closing the environment first would leave the transaction
  # handle dangling, and aborting it would be a SIGSEGV.
  local({
    env <- mdbx_env_open(tempfile(fileext = ".mdbx"), map_size = test_map_size)
    txn <- mdbx_txn_begin(env, write = TRUE)
    expect_identical(mdbx_txn_state(txn), "active")
  })

  gc()
  gc()

  expect_identical(mdbx:::mdbx_env_live_count_(), envs_before)
  expect_identical(mdbx:::mdbx_txn_live_count_(), txns_before)

  # The session survived both finalizers.
  expect_identical(mdbx_version()$major, 0L)
})

test_that("mdbx_with_write commits on success and aborts on error", {
  env <- local_env()

  seen <- NULL
  result <- mdbx_with_write(env, function(txn) {
    seen <<- txn
    "value"
  })

  expect_identical(result, "value")
  expect_identical(mdbx_txn_state(seen), "committed")

  failed <- NULL
  expect_error(
    mdbx_with_write(env, function(txn) {
      failed <<- txn
      stop("boom")
    }),
    "boom"
  )
  expect_identical(mdbx_txn_state(failed), "aborted")

  # Nothing was left holding the writer lock or the registry.
  expect_identical(mdbx:::mdbx_env_txn_count_(env), 0L)
})

test_that("mdbx_with_read aborts its snapshot", {
  env <- local_env()

  seen <- NULL
  result <- mdbx_with_read(env, function(txn) {
    seen <<- txn
    mdbx_txn_state(txn)
  })

  expect_identical(result, "active")
  expect_identical(mdbx_txn_state(seen), "aborted")
  expect_identical(mdbx:::mdbx_env_txn_count_(env), 0L)
})

test_that("non-transaction objects and bad arguments are rejected", {
  env <- local_env()

  expect_error(mdbx_txn_commit(42), "mdbx_txn")
  expect_error(mdbx_txn_abort("nope"), "mdbx_txn")
  expect_error(mdbx_txn_state(NULL), "mdbx_txn")

  expect_error(mdbx_txn_begin(env, write = NA), "TRUE or FALSE")
  expect_error(mdbx_txn_begin("not an environment"), "mdbx_env")
  expect_error(mdbx_with_read(env, "not a function"), "must be a function")
  expect_error(mdbx_with_write(env, 42), "must be a function")
})

test_that("a transaction cannot begin on a closed environment", {
  env <- mdbx_env_open(tempfile(fileext = ".mdbx"), map_size = test_map_size)
  mdbx_env_close(env)

  expect_error(mdbx_txn_begin(env), "closed")
})

test_that("the with_* wrappers preserve their block's visibility", {
  env <- local_env()

  # A block ending in mdbx_put() is invisible; one ending in a value is not.
  expect_false(withVisible(mdbx_with_write(env, function(txn) {
    mdbx_put(txn, charToRaw("k"), charToRaw("v"))
  }))$visible)

  expect_true(withVisible(mdbx_with_write(env, function(txn) "value"))$visible)
  expect_true(withVisible(mdbx_with_read(env, function(txn) "value"))$visible)
  expect_false(withVisible(mdbx_with_read(env, function(txn) invisible(1)))$visible)

  # The value itself is unchanged either way.
  expect_true(mdbx_with_write(env, function(txn) {
    mdbx_put(txn, charToRaw("k2"), charToRaw("v"))
  }))
})

test_that("a finished transaction stops holding its environment open", {
  invisible(gc())
  before <- mdbx:::mdbx_env_live_count_()

  kept <- local({
    env <- local_env()
    txn <- mdbx_txn_begin(env, write = TRUE)
    mdbx_put(txn, "k", "v")
    mdbx_txn_commit(txn)
    txn
  })

  invisible(gc())
  invisible(gc())

  # The environment was dropped, so its memory map and file descriptors must go
  # with it -- holding the finished transaction is not a reason to keep them.
  expect_identical(mdbx:::mdbx_env_live_count_(), before)

  # The finished object still answers for itself, and using it is still the
  # error it always was rather than a crash on freed memory.
  expect_identical(mdbx_txn_state(kept), "committed")
  expect_error(mdbx_get(kept, "k"), "already committed")

  invisible(gc())
  expect_identical(mdbx_txn_state(kept), "committed")
})

test_that("an aborted transaction releases its environment too", {
  invisible(gc())
  before <- mdbx:::mdbx_env_live_count_()

  kept <- local({
    env <- local_env()
    txn <- mdbx_txn_begin(env)
    mdbx_txn_abort(txn)
    txn
  })

  invisible(gc())
  invisible(gc())
  expect_identical(mdbx:::mdbx_env_live_count_(), before)
  expect_identical(mdbx_txn_state(kept), "aborted")
})
