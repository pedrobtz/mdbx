# Concurrency between processes: many readers, one writer.

seeded_db <- function(key = "k", value = "v1") {
  path <- tempfile(fileext = ".mdbx")
  env <- mdbx_env_open(path, map_size = test_map_size)
  mdbx_with_write(env, function(txn) mdbx_put(txn, key, value))
  mdbx_env_close(env)
  path
}

test_that("another process sees committed data but not uncommitted", {
  skip_if_no_subprocess()

  path <- seeded_db()
  env <- mdbx_env_open(path, map_size = test_map_size)
  txn <- mdbx_txn_begin(env, write = TRUE)
  mdbx_put(txn, "pending", "not yet")

  reader <- sprintf(
    'env <- mdbx_env_open(%s, readonly = TRUE)
     cat(mdbx_with_read(env, function(t) c(mdbx_get(t, "k"), mdbx_get(t, "pending"))))',
    as_code(path)
  )

  # The write transaction above is still open, and its writes are private to it.
  expect_identical(r_run(reader), "v1")

  mdbx_txn_commit(txn)
  expect_identical(r_run(reader), "v1 not yet")

  mdbx_env_close(env)
})

test_that("two processes can hold read transactions at the same time", {
  skip_if_no_subprocess()

  path <- seeded_db()
  env <- mdbx_env_open(path, map_size = test_map_size)
  txn <- mdbx_txn_begin(env)

  # This process is inside a read transaction for the whole of the subprocess.
  result <- r_run(sprintf(
    'env <- mdbx_env_open(%s)
     txn <- mdbx_txn_begin(env)
     cat(mdbx_get(txn, "k"))
     mdbx_txn_abort(txn)',
    as_code(path)
  ))

  expect_identical(result, "v1")
  expect_identical(mdbx_get(txn, "k"), "v1")

  # Both readers were counted against the environment's reader slots.
  expect_true(mdbx_env_info(env)$maxreaders >= 2)

  mdbx_txn_abort(txn)
  mdbx_env_close(env)
})

test_that("a second writer is refused while one is active", {
  skip_if_no_subprocess()

  path <- seeded_db()
  env <- mdbx_env_open(path, map_size = test_map_size)
  txn <- mdbx_txn_begin(env, write = TRUE)

  # `TRY` turns the wait into an immediate MDBX_BUSY, so this asserts on
  # serialization without racing a timeout.
  result <- r_run(sprintf(
    'env <- mdbx_env_open(%s)
     cat(tryCatch({
       mdbx_txn_begin(env, write = TRUE, flags = "TRY")
       "got the writer lock"
     }, error = function(e) conditionMessage(e)))',
    as_code(path)
  ))

  expect_match(result, "MDBX_BUSY", fixed = TRUE)
  expect_false(grepl("got the writer lock", result, fixed = TRUE))

  # Once this one ends, the lock is available again.
  mdbx_txn_commit(txn)

  after <- r_run(sprintf(
    'env <- mdbx_env_open(%s)
     txn <- mdbx_txn_begin(env, write = TRUE, flags = "TRY")
     mdbx_put(txn, "from-elsewhere", "1")
     mdbx_txn_commit(txn)
     cat("wrote")',
    as_code(path)
  ))

  expect_identical(after, "wrote")
  expect_identical(mdbx_with_read(env, function(t) mdbx_get(t, "from-elsewhere")), "1")

  mdbx_env_close(env)
})

test_that("a reader keeps its snapshot while another process commits", {
  skip_if_no_subprocess()

  path <- seeded_db()
  env <- mdbx_env_open(path, map_size = test_map_size)
  txn <- mdbx_txn_begin(env)

  expect_identical(mdbx_get(txn, "k"), "v1")

  # A reader does not block a writer: this succeeds while the snapshot is held.
  result <- r_run(sprintf(
    'env <- mdbx_env_open(%s)
     mdbx_with_write(env, function(t) mdbx_put(t, "k", "v2"))
     cat("committed")',
    as_code(path)
  ))
  expect_identical(result, "committed")

  # And the snapshot is unchanged by it -- this is the isolation guarantee.
  expect_identical(mdbx_get(txn, "k"), "v1")

  mdbx_txn_abort(txn)

  # A transaction begun now sees the new state.
  expect_identical(mdbx_with_read(env, function(t) mdbx_get(t, "k")), "v2")

  mdbx_env_close(env)
})

test_that("an exclusive environment locks other processes out", {
  skip_if_no_subprocess()

  path <- seeded_db()
  env <- mdbx_env_open(path, flags = "EXCLUSIVE", map_size = test_map_size)

  result <- r_run(sprintf(
    'cat(tryCatch({
       mdbx_env_open(%s)
       "opened"
     }, error = function(e) conditionMessage(e)))',
    as_code(path)
  ))

  # A refusal from libmdbx (EAGAIN here, but the text is the platform's), not
  # some unrelated failure to start: "mdbx error" only comes from this package
  # translating a status code.
  expect_match(result, "mdbx error", fixed = TRUE)
  expect_false(grepl("opened", result, fixed = TRUE))

  mdbx_env_close(env)
  expect_identical(
    r_run(sprintf('mdbx_env_close(mdbx_env_open(%s)); cat("opened")', as_code(path))),
    "opened"
  )
})
