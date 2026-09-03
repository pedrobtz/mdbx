test_that("stat describes an empty database", {
  env <- local_env()
  stat <- mdbx_env_stat(env)

  expect_type(stat, "list")
  expect_named(stat, c("pagesize", "depth", "branch_pages", "leaf_pages",
                       "overflow_pages", "entries", "mod_txnid"))
  expect_true(all(vapply(stat, is.numeric, logical(1))))

  expect_identical(stat$entries, 0)
  expect_identical(stat$depth, 0)
  expect_true(stat$pagesize > 0)
})

test_that("entries tracks records as they are written and deleted", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    for (i in 1:10) mdbx_put(txn, sprintf("k%02d", i), "v")
  })
  expect_identical(mdbx_env_stat(env)$entries, 10)

  mdbx_with_write(env, function(txn) mdbx_del(txn, "k01"))
  expect_identical(mdbx_env_stat(env)$entries, 9)

  # Replacing a key does not add one.
  mdbx_with_write(env, function(txn) mdbx_put(txn, "k02", "other"))
  expect_identical(mdbx_env_stat(env)$entries, 9)
})

test_that("a transaction counts its own uncommitted writes", {
  env <- local_env()

  txn <- mdbx_txn_begin(env, write = TRUE)
  for (i in 1:5) mdbx_put(txn, sprintf("k%d", i), "v")

  expect_identical(mdbx_env_stat(txn)$entries, 5)

  # The environment form agrees while this thread holds the transaction: it
  # reports the live state, not the last commit, despite libmdbx's docs
  # describing the null-transaction case as the last committed snapshot.
  expect_identical(mdbx_env_stat(env)$entries, 5)

  mdbx_txn_abort(txn)

  # Aborting takes it back down, which is what proves the 5 above was the
  # uncommitted state rather than anything durable.
  expect_identical(mdbx_env_stat(env)$entries, 0)
})

test_that("statistics work while this thread holds a read transaction", {
  env <- local_env()
  mdbx_with_write(env, function(txn) mdbx_put(txn, "k", "v"))

  txn <- mdbx_txn_begin(env)

  # Passing a null transaction makes libmdbx open an internal read transaction,
  # which collides with the one held here and fails with MDBX_BAD_RSLOT. The
  # environment form reuses the live transaction instead.
  expect_identical(mdbx_env_stat(env)$entries, 1)
  expect_identical(mdbx_env_stat(env)$entries, mdbx_env_stat(txn)$entries)
  expect_identical(mdbx_env_info(env)$maxreaders, mdbx_env_info(txn)$maxreaders)

  mdbx_txn_abort(txn)
  expect_identical(mdbx_env_stat(env)$entries, 1)
})

test_that("committed writes persist in the statistics", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    for (i in 1:3) mdbx_put(txn, sprintf("j%d", i), "v")
  })

  expect_identical(mdbx_env_stat(env)$entries, 3)
  expect_true(mdbx_env_stat(env)$leaf_pages >= 1)
})

test_that("info reports geometry and reader slots", {
  map_size <- 4 * 1024^2
  env <- local_env(map_size = map_size)
  info <- mdbx_env_info(env)

  expect_type(info, "list")
  expect_true(all(vapply(info, is.numeric, logical(1))))

  # map_size sets the upper bound of the geometry, and nothing else.
  expect_identical(info$geo_upper, map_size)
  expect_true(info$geo_current <= info$geo_upper)
  expect_true(info$geo_lower <= info$geo_current)

  expect_true(info$maxreaders > 0)
  expect_true(info$numreaders >= 0)
  expect_true(info$pagesize > 0)
  expect_identical(info$pagesize, mdbx_env_stat(env)$pagesize)
})

test_that("recent_txnid advances with each commit", {
  env <- local_env()
  before <- mdbx_env_info(env)$recent_txnid

  mdbx_with_write(env, function(txn) mdbx_put(txn, "k", "v"))

  expect_true(mdbx_env_info(env)$recent_txnid > before)
})

test_that("info is available from a transaction too", {
  env <- local_env()

  mdbx_with_read(env, function(txn) {
    info <- mdbx_env_info(txn)
    expect_type(info, "list")
    expect_true(info$maxreaders > 0)
  })
})

test_that("stat and info reject anything else", {
  expect_error(mdbx_env_stat(42), "mdbx_env")
  expect_error(mdbx_env_info("nope"), "mdbx_env")
  expect_error(mdbx_env_stat(NULL), "mdbx_env")

  env <- local_env()
  mdbx_env_close(env)
  expect_error(mdbx_env_stat(env), "closed")
  expect_error(mdbx_env_info(env), "closed")
})

test_that("mdbx_version reports how the amalgamation was built", {
  build <- mdbx_version()$build

  expect_type(build, "list")
  expect_named(build, c("datetime", "target", "compiler", "options", "flags"))
  expect_true(all(vapply(build, is.character, logical(1))))

  # MDBX_BUILD_FLAGS is set in src/Makevars; seeing it here proves the
  # reported metadata describes this build rather than some other.
  expect_identical(build$flags, "R-CMD-SHLIB")

  # The compile-time safety flags the package relies on are really in effect.
  expect_match(build$options, "ENV_CHECKPID=1", fixed = TRUE)
  expect_match(build$options, "TXN_CHECKOWNER=1", fixed = TRUE)

  expect_true(nzchar(build$target))
  expect_true(nzchar(build$compiler))
})
