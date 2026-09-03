test_that("the flag vocabulary is reported as data", {
  flags <- mdbx_flags()

  expect_s3_class(flags, "data.frame")
  expect_named(flags, c("flag", "scope", "settable", "runtime"))
  expect_setequal(unique(flags$scope), c("env", "txn"))

  env_flags <- flags$flag[flags$scope == "env"]
  expect_true(all(c("SAFE_NOSYNC", "NOMETASYNC", "UTTERLY_NOSYNC", "WRITEMAP")
                  %in% env_flags))
  expect_setequal(flags$flag[flags$scope == "txn"],
                  c("NOSYNC", "NOMETASYNC", "TRY"))

  # The three that mdbx_env_open(, map_size = test_map_size) has its own arguments for, or refuses.
  expect_false(any(flags$settable[flags$flag %in%
                     c("RDONLY", "NOSUBDIR", "NOSTICKYTHREADS")]))

  # Runtime-changeable is a subset of settable, never the other way round.
  expect_true(all(flags$settable[flags$runtime]))
})

test_that("flags passed at open are in effect afterwards", {
  env <- local_env(flags = c("LIFORECLAIM", "NORDAHEAD"))

  expect_true(all(c("LIFORECLAIM", "NORDAHEAD") %in% mdbx_env_get_flags(env)))
})

test_that("get_flags reports the environment, not the call", {
  # NOSUBDIR is set by `subdir = FALSE`, which is the default.
  expect_identical(mdbx_env_get_flags(local_env()), "NOSUBDIR")

  dir_env <- mdbx_env_open(tempfile(), subdir = TRUE, map_size = test_map_size)
  expect_identical(mdbx_env_get_flags(dir_env), character(0))

  path <- tempfile(fileext = ".mdbx")
  mdbx_env_close(mdbx_env_open(path, map_size = test_map_size))
  ro <- mdbx_env_open(path, readonly = TRUE, map_size = test_map_size)
  expect_true("RDONLY" %in% mdbx_env_get_flags(ro))
})

test_that("libmdbx normalizes the sync flags, and that shows through", {
  # Measured, not documented: asking for SAFE_NOSYNC gets NOMETASYNC too,
  # because the weaker guarantee is implied by the stronger relaxation.
  safe <- mdbx_env_get_flags(local_env(flags = "SAFE_NOSYNC"))
  expect_true(all(c("SAFE_NOSYNC", "NOMETASYNC") %in% safe))

  # UTTERLY_NOSYNC is SAFE_NOSYNC plus a bit, so a naive report would name
  # both. It is one mode and is reported as one.
  utterly <- mdbx_env_get_flags(local_env(flags = "UTTERLY_NOSYNC"))
  expect_true("UTTERLY_NOSYNC" %in% utterly)
  expect_false("SAFE_NOSYNC" %in% utterly)
})

test_that("flags can be set and cleared on a live environment", {
  env <- local_env()
  expect_false("SAFE_NOSYNC" %in% mdbx_env_get_flags(env))

  mdbx_env_set_flags(env, "SAFE_NOSYNC")
  expect_true("SAFE_NOSYNC" %in% mdbx_env_get_flags(env))

  mdbx_env_set_flags(env, "SAFE_NOSYNC", on = FALSE)
  expect_false("SAFE_NOSYNC" %in% mdbx_env_get_flags(env))

  expect_null(mdbx_env_set_flags(env, "NOMEMINIT"))
})

test_that("only the runtime-changeable flags can be set on a live environment", {
  env <- local_env()

  expect_error(mdbx_env_set_flags(env, "WRITEMAP"), "when the environment is opened")
  expect_error(mdbx_env_set_flags(env, character(0)), "at least one flag")
})

test_that("flags cannot change under an open transaction", {
  env <- local_env()
  txn <- mdbx_txn_begin(env, write = TRUE)

  # libmdbx would answer MDBX_BUSY; the refusal says which transaction to end.
  expect_error(mdbx_env_set_flags(env, "SAFE_NOSYNC"), "transaction is open")

  mdbx_txn_abort(txn)
  expect_null(mdbx_env_set_flags(env, "SAFE_NOSYNC"))
})

test_that("sync reports whether there was anything to write", {
  env <- local_env(flags = "SAFE_NOSYNC")
  mdbx_with_write(env, function(txn) mdbx_put(txn, "k", "v"))

  # The commit deliberately flushed nothing, so this is the flush.
  expect_true(mdbx_env_sync(env))

  # And now there is nothing left pending.
  expect_false(mdbx_env_sync(env))
})

test_that("sync is invisible but returns its answer", {
  env <- local_env()

  expect_invisible(mdbx_env_sync(env))
  expect_type(withVisible(mdbx_env_sync(env))$value, "logical")
})

test_that("a read-only environment cannot be synced", {
  path <- tempfile(fileext = ".mdbx")
  mdbx_env_close(mdbx_env_open(path, map_size = test_map_size))

  env <- mdbx_env_open(path, readonly = TRUE, map_size = test_map_size)
  expect_error(mdbx_env_sync(env), "read-only")
})

test_that("data written without syncing still survives an orderly close", {
  path <- tempfile(fileext = ".mdbx")
  env <- mdbx_env_open(path, flags = "SAFE_NOSYNC", map_size = test_map_size)

  mdbx_with_write(env, function(txn) mdbx_put(txn, "kept", "yes"))
  mdbx_env_close(env)

  # Closing flushes; only a crash loses these.
  reopened <- mdbx_env_open(path, map_size = test_map_size)
  expect_identical(mdbx_with_read(reopened, function(txn) mdbx_get(txn, "kept")), "yes")
  mdbx_env_close(reopened)
})

test_that("a transaction can relax durability for itself alone", {
  env <- local_env()

  txn <- mdbx_txn_begin(env, write = TRUE, flags = "NOSYNC")
  mdbx_put(txn, "k", "v")
  mdbx_txn_commit(txn)

  expect_identical(mdbx_with_read(env, function(txn) mdbx_get(txn, "k")), "v")

  # The environment itself is untouched by a per-transaction flag.
  expect_false("SAFE_NOSYNC" %in% mdbx_env_get_flags(env))
})

test_that("transaction flags are rejected on a read transaction", {
  env <- local_env()

  expect_error(mdbx_txn_begin(env, flags = "NOSYNC"), "write transactions only")
  expect_error(mdbx_txn_begin(env, write = FALSE, flags = "TRY"),
               "write transactions only")
})

test_that("misspelled and misplaced flags say what to do instead", {
  path <- tempfile(fileext = ".mdbx")

  expect_error(mdbx_env_open(path, flags = "MDBX_SAFE_NOSYNC"),
               "MDBX_ prefix is not part of the name", fixed = TRUE)
  expect_error(mdbx_env_open(path, flags = "RDONLY"), "readonly = TRUE", fixed = TRUE)
  expect_error(mdbx_env_open(path, flags = "NOSUBDIR"), "subdir = FALSE", fixed = TRUE)
  expect_error(mdbx_env_open(path, flags = "NOSTICKYTHREADS"),
               "one-transaction-per-thread")
  expect_error(mdbx_env_open(path, flags = "BOGUS"), "valid names are")

  env <- local_env()
  expect_error(mdbx_txn_begin(env, write = TRUE, flags = "WRITEMAP"),
               "environment flag")

  # Nothing was created by any of the rejected calls.
  expect_false(file.exists(path))
})

test_that("flag arguments are validated", {
  path <- tempfile(fileext = ".mdbx")

  expect_error(mdbx_env_open(path, flags = 1L), "character vector")
  expect_error(mdbx_env_open(path, flags = NA_character_), "character vector")
  expect_error(mdbx_env_open(path, flags = list("SAFE_NOSYNC")), "character vector")

  # NULL and the empty vector both mean "no flags", and repeats are harmless.
  expect_identical(mdbx_env_get_flags(local_env(flags = NULL)), "NOSUBDIR")
  expect_identical(mdbx_env_get_flags(local_env(flags = character(0))), "NOSUBDIR")
  expect_true("NOMETASYNC" %in%
                mdbx_env_get_flags(local_env(flags = c("NOMETASYNC", "NOMETASYNC"))))
})

test_that("flag functions reject anything that is not an open environment", {
  expect_error(mdbx_env_get_flags(42), "mdbx_env")
  expect_error(mdbx_env_sync("nope"), "mdbx_env")

  env <- local_env()
  mdbx_env_close(env)
  expect_error(mdbx_env_get_flags(env), "closed")
  expect_error(mdbx_env_set_flags(env, "SAFE_NOSYNC"), "closed")
  expect_error(mdbx_env_sync(env), "closed")
})
