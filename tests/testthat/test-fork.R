# What happens to a handle that a fork() duplicated.
#
# The child gets a copy of the pointer and none of what it addresses: libmdbx's
# own after-fork hook drowns the inherited environment. Before the pid guard,
# every operation that reached libmdbx here killed the child with "An
# irrecoverable exception occurred" -- MDBX_ENV_CHECKPID only notices after a
# call has already dereferenced the dead mapping. These assert on the guard
# above libmdbx that makes the misuse an ordinary R error instead.

test_that("an inherited environment is refused rather than used", {
  skip_if_cannot_fork()

  env <- local_seeded_env()
  inherited <- "belongs to process"

  expect_match(in_fork(function() mdbx_env_stat(env)$entries), inherited)
  expect_match(in_fork(function() mdbx_env_info(env)$maxreaders), inherited)
  expect_match(in_fork(function() mdbx_txn_begin(env)), inherited)
  expect_match(in_fork(function() mdbx_txn_begin(env, write = TRUE)), inherited)
  expect_match(in_fork(function() mdbx_with_read(env, function(t) mdbx_get(t, "k"))),
               inherited)
  expect_match(in_fork(function() mdbx_with_write(env, function(t) mdbx_put(t, "x", "1"))),
               inherited)
  expect_match(in_fork(function() mdbx_env_get_flags(env)), inherited)
  expect_match(in_fork(function() mdbx_env_sync(env)), inherited)

  mdbx_env_close(env)
})

test_that("the refusal names the fork rather than blaming the environment", {
  skip_if_cannot_fork()

  env <- local_seeded_env()
  message <- in_fork(function() mdbx_env_stat(env))

  expect_match(message, "fork()", fixed = TRUE)
  expect_match(message, "Open the environment inside the worker", fixed = TRUE)

  # Not the message a closed environment gets: the two are different mistakes.
  expect_false(grepl("is closed", message, fixed = TRUE))

  mdbx_env_close(env)
})

test_that("an inherited transaction is refused too", {
  skip_if_cannot_fork()

  env <- local_seeded_env()
  txn <- mdbx_txn_begin(env, write = TRUE)

  # And it reports as unusable rather than "active": every operation in the
  # child refuses it, so the state has to say so too.
  expect_identical(in_fork(function() mdbx_txn_state(txn)), "invalid")
  expect_identical(mdbx_txn_state(txn), "active")

  expect_match(in_fork(function() mdbx_get(txn, "k")), "transaction belongs to process")
  expect_match(in_fork(function() mdbx_txn_commit(txn)), "transaction belongs to process")
  expect_match(in_fork(function() mdbx_keys(txn)), "belongs to process")

  # And the parent's transaction is untouched by any of it.
  expect_identical(mdbx_txn_state(txn), "active")
  expect_identical(mdbx_get(txn, "k"), "v")

  mdbx_txn_commit(txn)
  mdbx_env_close(env)
})

test_that("a child cannot close its parent's environment", {
  skip_if_cannot_fork()

  env <- local_seeded_env()

  expect_match(in_fork(function() mdbx_env_close(env)), "cannot be closed from process")

  # The parent still holds a working environment, which is the point: a child
  # that closed it would have released a lock and reader slot it never held.
  expect_identical(mdbx_with_read(env, function(t) mdbx_get(t, "k")), "v")
  expect_true(mdbx_env_is_open(env))

  mdbx_env_close(env)
})

test_that("is_open reports an inherited environment as unusable", {
  skip_if_cannot_fork()

  env <- local_seeded_env()

  # FALSE rather than an error, so `if (mdbx_env_is_open(env))` stays correct.
  expect_false(in_fork(function() mdbx_env_is_open(env)))
  expect_true(mdbx_env_is_open(env))

  mdbx_env_close(env)
})

test_that("a worker that opens its own environment works normally", {
  skip_if_cannot_fork()

  env <- local_seeded_env()
  path <- attr(env, "path")
  mdbx_env_close(env)

  # The documented way to use mdbx under mclapply(): open inside the worker.
  results <- parallel::mclapply(1:4, function(i) {
    worker <- mdbx_env_open(path, map_size = test_map_size)
    on.exit(mdbx_env_close(worker))
    mdbx_with_read(worker, function(txn) mdbx_get(txn, "k"))
  }, mc.cores = 2)

  expect_identical(unlist(results), rep("v", 4))
})

test_that("the one-open-per-process rule does not follow a fork", {
  skip_if_cannot_fork()

  env <- local_seeded_env()
  path <- attr(env, "path")

  # The registry of open environments is copied into the child along with the
  # rest of memory, but the entries in it belong to the parent. A child opening
  # the environment for itself is the documented way to use mdbx under
  # mclapply(), so it must not be refused as a second open.
  results <- parallel::mclapply(1:2, function(i) {
    tryCatch({
      worker <- mdbx_env_open(path, map_size = test_map_size)
      on.exit(mdbx_env_close(worker))
      mdbx_with_read(worker, function(txn) mdbx_get(txn, "k"))
    }, error = conditionMessage)
  }, mc.cores = 2)

  expect_identical(unlist(results), c("v", "v"))

  # And the parent, which held it open throughout, is unaffected.
  expect_identical(mdbx_with_read(env, function(t) mdbx_get(t, "k")), "v")
  mdbx_env_close(env)
})

test_that("a parent survives its children refusing the environment", {
  skip_if_cannot_fork()

  env <- local_seeded_env()

  results <- parallel::mclapply(1:2, function(i) {
    tryCatch(mdbx_env_stat(env)$entries, error = function(e) "refused")
  }, mc.cores = 2)

  expect_identical(unlist(results), c("refused", "refused"))

  # Still fully usable here, including for writes.
  mdbx_with_write(env, function(txn) mdbx_put(txn, "after", "1"))
  expect_identical(mdbx_with_read(env, function(t) mdbx_get(t, "after")), "1")

  mdbx_env_close(env)
})

test_that("MDBX_TXN_CHECKOWNER rejects a transaction used off its own thread", {
  env <- local_seeded_env()
  txn <- mdbx_txn_begin(env, write = TRUE)
  mdbx_put(txn, "threaded", "1")

  # The compile flag is asserted in test-stat.R; this proves it has an effect.
  # A commit attempted from another thread must be refused, not honoured.
  expect_identical(
    mdbx:::mdbx_test_thread_mismatch_(txn),
    mdbx:::mdbx_thread_mismatch_code_()
  )

  # libmdbx documents MDBX_THREAD_MISMATCH as the one result that does not end
  # the transaction, so the owning thread still holds a live one.
  expect_identical(mdbx_txn_state(txn), "active")
  mdbx_txn_commit(txn)

  expect_identical(mdbx_with_read(env, function(t) mdbx_get(t, "threaded")), "1")
  mdbx_env_close(env)
})
