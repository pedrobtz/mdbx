# Named databases: independent key spaces inside one environment.

test_that("named databases are independent key spaces", {
  env <- multi_env()

  mdbx_with_write(env, function(txn) {
    files <- mdbx_dbi_open(txn, "files", create = TRUE)
    metadata <- mdbx_dbi_open(txn, "metadata", create = TRUE)

    mdbx_put(txn, "abc", "/data/abc.parquet", db = files)
    mdbx_put(txn, "abc", '{"size":1234}', db = metadata)
    mdbx_put(txn, "abc", "in the main database")
  })

  mdbx_with_read(env, function(txn) {
    files <- mdbx_dbi_open(txn, "files")
    metadata <- mdbx_dbi_open(txn, "metadata")

    # One key, three databases, three values.
    expect_identical(mdbx_get(txn, "abc", db = files), "/data/abc.parquet")
    expect_identical(mdbx_get(txn, "abc", db = metadata), '{"size":1234}')
    expect_identical(mdbx_get(txn, "abc"), "in the main database")

    expect_identical(mdbx_keys(txn, db = files), "abc")
    expect_identical(mdbx_items(txn, db = metadata)$values, '{"size":1234}')
  })

  mdbx_env_close(env)
})

test_that("deleting from one database leaves the others alone", {
  env <- multi_env()

  mdbx_with_write(env, function(txn) {
    a <- mdbx_dbi_open(txn, "a", create = TRUE)
    b <- mdbx_dbi_open(txn, "b", create = TRUE)
    mdbx_put(txn, "k", "1", db = a)
    mdbx_put(txn, "k", "2", db = b)

    expect_true(mdbx_del(txn, "k", db = a))
    expect_null(mdbx_get(txn, "k", db = a))
    expect_identical(mdbx_get(txn, "k", db = b), "2")
  })

  mdbx_env_close(env)
})

test_that("a database only exists once its creating transaction commits", {
  env <- multi_env()

  txn <- mdbx_txn_begin(env, write = TRUE)
  ghost <- mdbx_dbi_open(txn, "ghost", create = TRUE)
  mdbx_put(txn, "k", "v", db = ghost)
  mdbx_txn_abort(txn)

  # This is why the handle stores a name and not an MDBX_dbi: the dbi from that
  # transaction is poisoned, and the database was never created.
  mdbx_with_read(env, function(txn) {
    expect_error(mdbx_dbi_open(txn, "ghost"), "named database 'ghost' does not exist")
  })

  # The same handle object is simply stale, not dangerous.
  mdbx_with_read(env, function(txn) {
    expect_error(mdbx_get(txn, "k", db = ghost), "named database 'ghost' does not exist")
  })

  mdbx_env_close(env)
})

test_that("opening a database that does not exist needs create = TRUE", {
  env <- multi_env()

  mdbx_with_read(env, function(txn) {
    expect_error(mdbx_dbi_open(txn, "absent"), "named database 'absent' does not exist")
  })

  mdbx_with_write(env, function(txn) {
    expect_s3_class(mdbx_dbi_open(txn, "absent", create = TRUE), "mdbx_dbi")
  })

  # And now it opens without create.
  mdbx_with_read(env, function(txn) {
    expect_s3_class(mdbx_dbi_open(txn, "absent"), "mdbx_dbi")
  })

  mdbx_env_close(env)
})

test_that("a missing database is named, not reported as a missing key", {
  env <- multi_env()
  path <- attr(env, "path")

  # libmdbx answers this with MDBX_NOTFOUND, whose text -- "No matching
  # key/data pair found" -- describes a lookup that never happened, and reads
  # like the missing-key result mdbx_get() reports as NULL.
  message <- conditionMessage(tryCatch(
    mdbx_with_read(env, function(txn) mdbx_dbi_open(txn, "missing")),
    error = identity
  ))

  expect_match(message, "named database 'missing' does not exist", fixed = TRUE)
  expect_match(message, path, fixed = TRUE)
  expect_match(message, "pass create = TRUE inside a write transaction", fixed = TRUE)
  expect_false(grepl("NOTFOUND", message, fixed = TRUE))

  # The same in a write transaction: it is create = FALSE that decided, not
  # the mode of the transaction.
  expect_error(mdbx_with_write(env, function(txn) mdbx_dbi_open(txn, "missing")),
               "named database 'missing' does not exist")

  mdbx_env_close(env)
})

test_that("every db = entry point names a missing database", {
  env <- multi_env()

  txn <- mdbx_txn_begin(env, write = TRUE)
  ghost <- mdbx_dbi_open(txn, "ghost", create = TRUE)
  mdbx_txn_abort(txn)

  # A stale handle reaches ensure_dbi(), not mdbx_dbi_open_(), so every one of
  # these is a separate path to the same refusal. Reporting "no matching
  # key/data pair" for a `db` argument contradicts mdbx_get() outright, which
  # documents a missing key as NULL rather than an error.
  missing <- "named database 'ghost' does not exist"

  mdbx_with_read(env, function(txn) {
    expect_error(mdbx_get(txn, "k", db = ghost), missing)
    expect_error(mdbx_keys(txn, db = ghost), missing)
    expect_error(mdbx_items(txn, db = ghost), missing)
    expect_error(mdbx_dbi_sequence(txn, ghost), missing)
  })

  # The write entry points resolve the name the same way, and a write
  # transaction does not create one it was not asked to create.
  mdbx_with_write(env, function(txn) {
    expect_error(mdbx_put(txn, "k", "v", db = ghost), missing)
    expect_error(mdbx_del(txn, "k", db = ghost), missing)
    expect_error(mdbx_dbi_drop(txn, ghost), missing)
  })

  expect_identical(mdbx_with_read(env, function(txn) mdbx_dbi_list(txn)), character(0))

  mdbx_env_close(env)
})

test_that("a database name is not read as a format string", {
  env <- multi_env()

  # The refusal is built with a printf-style format, and the name is a string
  # the caller chose. It has to arrive as an argument, never as the format.
  hostile <- "%s %d %n %99999f"
  message <- conditionMessage(tryCatch(
    mdbx_with_read(env, function(txn) mdbx_dbi_open(txn, hostile)),
    error = identity
  ))

  expect_match(message, hostile, fixed = TRUE)
  expect_identical(mdbx_version()$major, 0L)

  # Nor does a name outside ASCII come back mangled. Written as an escape so
  # the test file itself stays ASCII, as the rest of the suite is.
  accented <- "caf\u00e9"
  expect_error(mdbx_with_read(env, function(txn) mdbx_dbi_open(txn, accented)),
               accented, fixed = TRUE)

  mdbx_env_close(env)
})

test_that("deleting a database mid-transaction re-resolves its name", {
  env <- multi_env()

  mdbx_with_write(env, function(txn) {
    db <- mdbx_dbi_open(txn, "doomed", create = TRUE)
    mdbx_put(txn, "k", "v", db = db)
    mdbx_dbi_drop(txn, db, delete = TRUE)

    # The per-transaction cache has to forget the deleted handle: reusing the
    # spent MDBX_dbi is what this would otherwise do.
    expect_error(mdbx_get(txn, "k", db = db), "named database 'doomed' does not exist")
    expect_error(mdbx_dbi_open(txn, "doomed"), "named database 'doomed' does not exist")
    expect_identical(mdbx_dbi_list(txn), character(0))
  })

  expect_identical(mdbx_version()$major, 0L)
  mdbx_env_close(env)
})

test_that("creating a database in a read transaction names the conflict", {
  env <- multi_env()

  # libmdbx reports a bare EACCES here. mdbx_put() has always pre-empted that
  # for a write; creating a database is one too.
  message <- conditionMessage(tryCatch(
    mdbx_with_read(env, function(txn) mdbx_dbi_open(txn, "wanted", create = TRUE)),
    error = identity
  ))

  expect_match(message, "create = TRUE needs a write transaction", fixed = TRUE)
  expect_match(message, "read-only", fixed = TRUE)
  expect_false(grepl("mdbx error", message, fixed = TRUE))

  # Refused before libmdbx, so nothing was created on the way out.
  expect_identical(mdbx_with_read(env, function(txn) mdbx_dbi_list(txn)), character(0))

  # libmdbx refuses on the flag before it looks the database up, so an existing
  # database is refused too. The message must not claim creation was the point.
  mdbx_with_write(env, function(txn) mdbx_dbi_open(txn, "already", create = TRUE))
  existing <- conditionMessage(tryCatch(
    mdbx_with_read(env, function(txn) mdbx_dbi_open(txn, "already", create = TRUE)),
    error = identity
  ))
  expect_match(existing, "create = TRUE needs a write transaction", fixed = TRUE)
  expect_match(existing, "create = FALSE", fixed = TRUE)

  mdbx_env_close(env)
})

test_that("max_dbs bounds how many can exist", {
  env <- multi_env(max_dbs = 4)

  expect_error(
    mdbx_with_write(env, function(txn) {
      for (i in 1:10) mdbx_dbi_open(txn, sprintf("db%d", i), create = TRUE)
    }),
    "MDBX_DBS_FULL"
  )

  mdbx_env_close(env)
})

test_that("every named-database write names a read-only transaction", {
  env <- multi_env()
  mdbx_with_write(env, function(txn) mdbx_dbi_open(txn, "here", create = TRUE))

  # mdbx_put() and mdbx_del() have always pre-empted libmdbx's bare EACCES for
  # this. These three are writes too, and did not.
  mdbx_with_read(env, function(txn) {
    db <- mdbx_dbi_open(txn, "here")
    readonly <- "this mdbx transaction is read-only"

    expect_error(mdbx_dbi_drop(txn, db), readonly)
    expect_error(mdbx_dbi_drop(txn, db, delete = TRUE), readonly)
    expect_error(mdbx_dbi_sequence(txn, db, 1), readonly)

    # And the create = TRUE refusal, which names the flag rather than the
    # operation, because libmdbx checks it before looking the database up.
    expect_error(mdbx_dbi_open(txn, "new", create = TRUE),
                 "create = TRUE needs a write transaction")

    # Nothing was done on the way out of any of them.
    expect_identical(mdbx_dbi_list(txn), "here")
  })

  mdbx_env_close(env)
})

test_that("a handle cannot be used against a different environment", {
  one <- multi_env()
  two <- multi_env()

  handle <- mdbx_with_write(one, function(txn) mdbx_dbi_open(txn, "shared", create = TRUE))

  # Re-resolving by name would otherwise address a same-named database in the
  # other environment, silently.
  mdbx_with_read(two, function(txn) {
    expect_error(mdbx_get(txn, "k", db = handle), "belongs to the environment")
  })

  mdbx_env_close(one)
  mdbx_env_close(two)
})

test_that("a database can be emptied or deleted", {
  env <- multi_env()

  mdbx_with_write(env, function(txn) {
    db <- mdbx_dbi_open(txn, "scratch", create = TRUE)
    mdbx_put(txn, "k", "v", db = db)
    mdbx_dbi_drop(txn, db)
    expect_identical(mdbx_keys(txn, db = db), character(0))
  })

  # Emptied, but still there.
  mdbx_with_read(env, function(txn) expect_s3_class(mdbx_dbi_open(txn, "scratch"), "mdbx_dbi"))

  mdbx_with_write(env, function(txn) {
    mdbx_dbi_drop(txn, mdbx_dbi_open(txn, "scratch"), delete = TRUE)
  })

  mdbx_with_read(env, function(txn) {
    expect_error(mdbx_dbi_open(txn, "scratch"), "named database 'scratch' does not exist")
  })

  mdbx_env_close(env)
})

test_that("a listing shows what this transaction did, before it commits", {
  env <- multi_env()

  # The documentation used to say the reverse of each of these.
  mdbx_with_write(env, function(txn) {
    mdbx_dbi_open(txn, "made", create = TRUE)
    expect_identical(mdbx_dbi_list(txn), "made")
  })

  mdbx_with_write(env, function(txn) {
    mdbx_dbi_drop(txn, mdbx_dbi_open(txn, "made"), delete = TRUE)
    expect_identical(mdbx_dbi_list(txn), character(0))
  })

  # What other transactions see is settled by the commit or abort, not before
  # it -- so an uncommitted creation is invisible outside its own transaction,
  # and so is an uncommitted deletion.
  txn <- mdbx_txn_begin(env, write = TRUE)
  mdbx_dbi_open(txn, "pending", create = TRUE)
  expect_identical(mdbx_dbi_list(txn), "pending")
  mdbx_txn_abort(txn)

  expect_identical(mdbx_with_read(env, function(txn) mdbx_dbi_list(txn)), character(0))

  mdbx_with_write(env, function(txn) mdbx_dbi_open(txn, "kept", create = TRUE))

  doomed <- mdbx_txn_begin(env, write = TRUE)
  mdbx_dbi_drop(doomed, mdbx_dbi_open(doomed, "kept"), delete = TRUE)
  expect_identical(mdbx_dbi_list(doomed), character(0))
  mdbx_txn_abort(doomed)

  # The abort put it back.
  expect_identical(mdbx_with_read(env, function(txn) mdbx_dbi_list(txn)), "kept")

  mdbx_env_close(env)
})

test_that("named databases are visible as keys of the main database", {
  # libmdbx stores them there, so this is the layout showing through rather
  # than a leak -- worth pinning down so it is not mistaken for a bug later.
  env <- multi_env()

  mdbx_with_write(env, function(txn) {
    mdbx_dbi_open(txn, "alpha", create = TRUE)
    mdbx_put(txn, "own-key", "v")
  })

  mdbx_with_read(env, function(txn) {
    expect_setequal(mdbx_keys(txn), c("alpha", "own-key"))
  })

  mdbx_env_close(env)
})

test_that("the db argument is validated", {
  env <- multi_env()

  mdbx_with_read(env, function(txn) {
    expect_error(mdbx_get(txn, "k", db = "files"), "mdbx_dbi")
    expect_error(mdbx_keys(txn, db = 42), "mdbx_dbi")
    expect_error(mdbx_dbi_open(txn, c("a", "b")), "single non-empty string")
    expect_error(mdbx_dbi_open(txn, "a", create = NA), "TRUE or FALSE")
  })

  # NULL keeps addressing the main database, which is the default everywhere.
  mdbx_with_write(env, function(txn) mdbx_put(txn, "k", "v", db = NULL))
  expect_identical(mdbx_with_read(env, function(txn) mdbx_get(txn, "k", db = NULL)), "v")

  mdbx_env_close(env)
})

test_that("the handle prints as itself", {
  env <- multi_env()
  db <- mdbx_with_write(env, function(txn) mdbx_dbi_open(txn, "printed", create = TRUE))

  expect_output(print(db), "mdbx_dbi")
  expect_output(print(db), "printed")

  mdbx_env_close(env)
})

test_that("the named databases can be listed", {
  env <- multi_env()

  mdbx_with_read(env, function(txn) expect_identical(mdbx_dbi_list(txn), character(0)))

  mdbx_with_write(env, function(txn) {
    mdbx_dbi_open(txn, "files", create = TRUE)
    mdbx_dbi_open(txn, "metadata", create = TRUE)
    mdbx_put(txn, "not-a-database", "v")
  })

  mdbx_with_read(env, function(txn) {
    # The main database is not listed, having no name, and an ordinary key of
    # the main database is not mistaken for one.
    expect_setequal(mdbx_dbi_list(txn), c("files", "metadata"))
    expect_length(mdbx_dbi_list(txn, as = "raw"), 2L)
    expect_true(is.raw(mdbx_dbi_list(txn, as = "raw")[[1]]))
  })

  # A database created by a transaction that aborts is never listed.
  txn <- mdbx_txn_begin(env, write = TRUE)
  mdbx_dbi_open(txn, "ghost", create = TRUE)
  expect_true("ghost" %in% mdbx_dbi_list(txn))
  mdbx_txn_abort(txn)

  mdbx_with_read(env, function(txn) expect_false("ghost" %in% mdbx_dbi_list(txn)))

  mdbx_env_close(env)
})

test_that("statistics can describe one database or the whole environment", {
  env <- multi_env()

  mdbx_with_write(env, function(txn) {
    x <- mdbx_dbi_open(txn, "x", create = TRUE)
    mdbx_dbi_open(txn, "y", create = TRUE)
    for (i in 1:7) mdbx_put(txn, sprintf("k%d", i), "v", db = x)
    mdbx_put(txn, "a", "1")
    mdbx_put(txn, "b", "2")
  })

  mdbx_with_read(env, function(txn) {
    x <- mdbx_dbi_open(txn, "x")
    y <- mdbx_dbi_open(txn, "y")

    expect_identical(mdbx_env_stat(txn, db = x)$entries, 7)
    expect_identical(mdbx_env_stat(txn, db = y)$entries, 0)

    # The main database holds its own two keys plus an entry per named
    # database, so four -- and the environment-wide count adds x's seven.
    expect_length(mdbx_keys(txn), 4L)
    expect_identical(mdbx_env_stat(txn)$entries, 11)

    # Both forms return the same shape.
    expect_named(mdbx_env_stat(txn, db = x), names(mdbx_env_stat(txn)))
  })

  mdbx_env_close(env)
})

test_that("a database carries a sequence counter", {
  env <- multi_env()

  mdbx_with_write(env, function(txn) {
    ids <- mdbx_dbi_open(txn, "ids", create = TRUE)

    # Reserving returns the value before the increment, so ids never repeat.
    expect_identical(mdbx_dbi_sequence(txn, ids, 1), 0)
    expect_identical(mdbx_dbi_sequence(txn, ids, 1), 1)
    expect_identical(mdbx_dbi_sequence(txn, ids, 10), 2)

    # Reading does not advance it.
    expect_identical(mdbx_dbi_sequence(txn, ids), 12)
    expect_identical(mdbx_dbi_sequence(txn, ids), 12)
  })

  # It persists, and each database has its own.
  mdbx_with_write(env, function(txn) {
    expect_identical(mdbx_dbi_sequence(txn, mdbx_dbi_open(txn, "ids")), 12)
    expect_identical(mdbx_dbi_sequence(txn, mdbx_dbi_open(txn, "other", create = TRUE)), 0)
    expect_identical(mdbx_dbi_sequence(txn), 0)
  })

  mdbx_with_read(env, function(txn) {
    # Advancing the counter is a write; libmdbx would report a bare EACCES.
    expect_error(mdbx_dbi_sequence(txn, mdbx_dbi_open(txn, "ids"), 1),
                 "this mdbx transaction is read-only")
    expect_error(mdbx_dbi_sequence(txn, NULL, -1), "between 0 and")

    # Reading it is not, and stays available.
    expect_identical(mdbx_dbi_sequence(txn, mdbx_dbi_open(txn, "ids")), 12)
    expect_identical(mdbx_dbi_sequence(txn, mdbx_dbi_open(txn, "ids"), 0), 12)
  })

  mdbx_env_close(env)
})

test_that("an increment rolls back with its transaction", {
  env <- multi_env()
  mdbx_with_write(env, function(txn) mdbx_dbi_open(txn, "seq", create = TRUE))

  txn <- mdbx_txn_begin(env, write = TRUE)
  expect_identical(mdbx_dbi_sequence(txn, mdbx_dbi_open(txn, "seq"), 5), 0)
  mdbx_txn_abort(txn)

  mdbx_with_read(env, function(txn) {
    expect_identical(mdbx_dbi_sequence(txn, mdbx_dbi_open(txn, "seq")), 0)
  })

  mdbx_env_close(env)
})

test_that("a sequence refuses to hand out values it cannot represent", {
  env <- local_env(max_dbs = 4)

  mdbx_with_write(env, function(txn) {
    db <- mdbx_dbi_open(txn, "ids", create = TRUE)

    # The counter is 64-bit in libmdbx but reaches R as a double, which stops
    # holding consecutive integers past 2^53. Reserving right up to the edge is
    # still exact, so it is allowed.
    expect_identical(mdbx_dbi_sequence(txn, db, 2^53 - 2), 0)
    expect_identical(mdbx_dbi_sequence(txn, db, 1), 2^53 - 2)
    expect_identical(mdbx_dbi_sequence(txn, db), 2^53 - 1)

    # One more would return 2^53 and then 2^53 again: two callers, one id.
    expect_error(mdbx_dbi_sequence(txn, db, 2), "hand out duplicate values")

    # And the refusal happens before the increment, so the counter is exactly
    # where it was -- no reservation is silently consumed by a failed call.
    expect_identical(mdbx_dbi_sequence(txn, db), 2^53 - 1)
  })

  mdbx_env_close(env)
})

test_that("a sequence increment must be a whole number", {
  env <- local_env(max_dbs = 4)

  mdbx_with_write(env, function(txn) {
    db <- mdbx_dbi_open(txn, "ids", create = TRUE)

    # Truncating silently made `increment = 0.5` a no-op that still looked
    # like a successful reservation.
    expect_error(mdbx_dbi_sequence(txn, db, 0.5), "whole number")
    expect_error(mdbx_dbi_sequence(txn, db, 1.9), "whole number")
    expect_error(mdbx_dbi_sequence(txn, db, Inf), "between 0 and")
    expect_error(mdbx_dbi_sequence(txn, db, NA_real_), "between 0 and")
    expect_error(mdbx_dbi_sequence(txn, db, 2^54), "between 0 and")

    expect_identical(mdbx_dbi_sequence(txn, db), 0)
  })

  mdbx_env_close(env)
})

test_that("a named database opens under the default environment settings", {
  # libmdbx reserves no dbi slots by default, so this used to need an explicit
  # max_dbs before mdbx_dbi_open() would work at all.
  path <- tempfile(fileext = ".mdbx")
  env <- mdbx_env_open(path)
  on.exit(unlink(c(path, paste0(path, "-lck"))), add = TRUE)

  names <- mdbx_with_write(env, function(txn) {
    for (name in c("a", "b", "c")) {
      mdbx_put(txn, "k", "v", db = mdbx_dbi_open(txn, name, create = TRUE))
    }
    mdbx_dbi_list(txn)
  })
  expect_identical(names, c("a", "b", "c"))

  # NULL still means "take libmdbx's default", which reserves none.
  env_none <- mdbx_env_open(tempfile(fileext = ".mdbx"), max_dbs = NULL)
  expect_error(
    mdbx_with_write(env_none, function(txn) mdbx_dbi_open(txn, "a", create = TRUE)),
    "MDBX_DBS_FULL"
  )
  mdbx_env_close(env_none)

  mdbx_env_close(env)
})
