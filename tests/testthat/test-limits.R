# Boundaries: the largest and smallest things the API accepts, and what happens
# just past them.
#
# These exist partly because of what an external review found: three
# double-to-integer casts were fed unchecked values, and the sanitizer CI leg
# never noticed because no test had ever passed an out-of-range number. A
# sanitizer only sees code the suite executes, so the boundaries have to be
# walked deliberately.

roomy_env <- function() {
  mdbx_env_open(env_path(), map_size = 64 * 1024^2)
}

test_that("large keys and values round-trip byte-exactly", {
  env <- roomy_env()

  # Exactly the largest key this database will take. Asking beats guessing: a
  # hardcoded 4000 bytes passed on macOS (16 KB pages, ceiling 8166) and failed
  # on Linux CI (4 KB pages, ceiling 2022).
  key <- strrep("k", mdbx_limits(env)$keysize_max)
  value <- strrep("v", 2e6)

  mdbx_with_write(env, function(txn) mdbx_put(txn, key, value))

  mdbx_with_read(env, function(txn) {
    expect_identical(mdbx_get(txn, key), value)
    # A value this size lives in overflow pages rather than inline.
    expect_true(mdbx_env_stat(txn)$overflow_pages > 0)
  })

  mdbx_env_close(env)
})

test_that("an oversized key is refused, and the transaction survives it", {
  env <- roomy_env()

  # One byte past the ceiling, rather than a number chosen to be safely huge.
  huge <- strrep("k", mdbx_limits(env)$keysize_max + 1)

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, "before", "1")

    expect_error(mdbx_put(txn, huge, "v"), "mdbx error")

    # The rejection is libmdbx declining one operation, not the transaction
    # breaking: writes on either side of it still land.
    mdbx_put(txn, "after", "2")
  })

  expect_identical(mdbx_with_read(env, function(txn) mdbx_keys(txn)),
                   c("after", "before"))

  mdbx_env_close(env)
})

test_that("a value larger than the map ends the whole transaction", {
  env <- mdbx_env_open(env_path(), map_size = 1024^2)

  # Unlike an oversized key, exhausting the map is not a survivable failure:
  # libmdbx marks the transaction unusable and rolls it back.
  txn <- mdbx_txn_begin(env, write = TRUE)
  mdbx_put(txn, "before", "1")

  expect_error(mdbx_put(txn, "k", paste(rep("v", 4e6), collapse = "")),
               "MDBX_MAP_FULL")

  # Every later operation is refused, including ones that would otherwise work.
  expect_error(mdbx_put(txn, "after", "2"), "MDBX_BAD_TXN")

  # And the commit says so, in words. libmdbx reports this as MDBX_RESULT_TRUE,
  # which is a result rather than an error code, so passing it to strerror()
  # yields the useless "error -1" -- which is what this used to say.
  message <- conditionMessage(tryCatch(mdbx_txn_commit(txn), error = identity))
  expect_match(message, "rolled back instead of committed")
  expect_match(message, "No changes were written")
  expect_false(grepl("error -1", message, fixed = TRUE))

  expect_identical(mdbx_txn_state(txn), "aborted")

  # Nothing from that transaction landed, not even the write that succeeded.
  expect_identical(mdbx_with_read(env, function(txn) mdbx_keys(txn)), character(0))

  # The environment itself is fine.
  mdbx_with_write(env, function(txn) mdbx_put(txn, "k", "small"))
  expect_identical(mdbx_with_read(env, function(txn) mdbx_get(txn, "k")), "small")

  mdbx_env_close(env)
})

test_that("numeric arguments that would overflow a native cast are refused", {
  path <- env_path()

  # 2^53 is the largest integer a double holds exactly; past it the C++ cast
  # would be undefined behaviour rather than an error.
  expect_error(mdbx_env_open(path, max_dbs = 1e20), "too large")
  expect_error(mdbx_env_open(path, map_size = 1e20), "too large")
  expect_error(mdbx_env_open(path, max_readers = 1e20), "too large")

  # 2^63 is the value a `x > (double) PTRDIFF_MAX` guard wrongly admits,
  # because PTRDIFF_MAX rounds *up* to 2^63 as a double.
  expect_error(mdbx_env_open(path, map_size = 2^63), "too large")

  env <- local_env()
  mdbx_with_read(env, function(txn) {
    expect_error(mdbx_keys(txn, limit = 1e20), "too large")
    expect_error(mdbx_items(txn, limit = 1e20), "too large")
  })

  # The internal entry points guard independently: they are reachable via :::,
  # and an out-of-range cast is undefined behaviour wherever it happens.
  expect_error(mdbx:::mdbx_env_open_(path, FALSE, FALSE, 1e20, 0, 0, 420L,
                                     character(0)), "too large")
  mdbx_with_read(env, function(txn) {
    expect_error(mdbx:::mdbx_scan_(txn, 1e20, FALSE, character(0), NULL, FALSE), "too large")
  })
})

test_that("the reader table can be sized beyond the default", {
  env <- mdbx_env_open(env_path(), map_size = 8 * 1024^2, max_readers = 1000)

  # libmdbx rounds up to fill the lock page, so ask for at least what we asked.
  expect_true(mdbx_env_info(env)$maxreaders >= 1000)

  mdbx_env_close(env)

  # Bounds: libmdbx rejects 0 and anything past MDBX_READERS_LIMIT.
  expect_error(mdbx_env_open(env_path(), max_readers = 0), "positive number")
  expect_error(mdbx_env_open(env_path(), max_readers = 32768), "at most 32767")
  expect_error(mdbx_env_open(env_path(), max_readers = "many"), "positive number")
})

test_that("stale reader slots can be reclaimed", {
  env <- local_env()

  # Nothing has died, so there is nothing to reclaim -- but the call must work
  # and report honestly rather than erroring.
  expect_identical(mdbx_env_reader_check(env), 0L)
  expect_invisible(mdbx_env_reader_check(env))

  # It is still zero while this process holds a live reader, because that slot
  # belongs to a process that is very much alive.
  mdbx_with_read(env, function(txn) {
    expect_identical(mdbx_env_reader_check(env), 0L)
  })

  mdbx_env_close(env)
  expect_error(mdbx_env_reader_check(env), "closed")
  expect_error(mdbx_env_reader_check(42), "mdbx_env")
})

test_that("file mode controls who can read a new database", {
  skip_on_os("windows")

  private <- env_path()
  mdbx_env_close(mdbx_env_open(private, map_size = 8 * 1024^2, mode = "0600"))
  expect_identical(format(as.octmode(file.info(private)$mode)), "600")

  # An octmode object is accepted as readily as the string.
  other <- env_path()
  mdbx_env_close(mdbx_env_open(other, map_size = 8 * 1024^2,
                               mode = as.octmode("600")))
  expect_identical(format(as.octmode(file.info(other)$mode)), "600")

  # The default is libmdbx's 0664, which the usual umask trims to 0644 --
  # world-readable, which is the reason `mode` is worth having.
  default <- env_path()
  mdbx_env_close(mdbx_env_open(default, map_size = 8 * 1024^2))
  expect_true(format(as.octmode(file.info(default)$mode)) %in% c("644", "664"))
})

test_that("mode is validated rather than guessed at", {
  path <- env_path()

  # A bare number is ambiguous: 600 is not 0600.
  expect_error(mdbx_env_open(path, mode = 600), "octal digits")
  expect_error(mdbx_env_open(path, mode = "0999"), "octal digits")
  expect_error(mdbx_env_open(path, mode = "rw-------"), "octal digits")
  expect_error(mdbx_env_open(path, mode = c("0600", "0644")), "octal digits")
  expect_error(mdbx_env_open(path, mode = NA_character_), "octal digits")

  expect_false(file.exists(path))
})

test_that("libmdbx reports its own size limits", {
  limits <- mdbx_limits()

  expect_named(limits, c("pagesize", "keysize_min", "keysize_max", "valsize_min",
                         "valsize_max", "dbsize_min", "dbsize_max", "txnsize_max"))
  expect_true(all(vapply(limits, is.numeric, logical(1))))

  # An empty key and an empty value are both legal, which is what a zero
  # minimum means -- and test-data.R relies on it.
  expect_identical(limits$keysize_min, 0)
  expect_identical(limits$valsize_min, 0)
  expect_true(limits$keysize_max > limits$keysize_min)
  expect_true(limits$dbsize_max > limits$dbsize_min)
})

test_that("the key limit tracks the page size", {
  # The numbers libmdbx computes, which is why hardcoding one is a portability
  # bug: the same code meets a 2022-byte ceiling on Linux and 8166 on macOS.
  expect_identical(mdbx_limits(4096)$keysize_max, 2022)
  expect_identical(mdbx_limits(16384)$keysize_max, 8166)
  expect_true(mdbx_limits(65536)$keysize_max > mdbx_limits(16384)$keysize_max)

  # A value is bounded by the map rather than the page, so it does not move.
  expect_identical(mdbx_limits(4096)$valsize_max, mdbx_limits(16384)$valsize_max)
})

test_that("limits can be asked of an environment or a transaction", {
  env <- local_env()
  pagesize <- mdbx_env_stat(env)$pagesize

  expect_identical(mdbx_limits(env), mdbx_limits(pagesize))
  mdbx_with_read(env, function(txn) {
    expect_identical(mdbx_limits(txn)$keysize_max, mdbx_limits(pagesize)$keysize_max)
  })

  # And the reported ceiling is the real one, in both directions.
  ceiling <- mdbx_limits(env)$keysize_max
  mdbx_with_write(env, function(txn) {
    expect_silent(mdbx_put(txn, strrep("k", ceiling), "v"))
    expect_error(mdbx_put(txn, strrep("j", ceiling + 1), "v"), "MDBX_BAD_VALSIZE")
  })

  mdbx_env_close(env)
})

test_that("an unusable page size is refused", {
  expect_error(mdbx_limits(1234), "not a usable page size")
  expect_error(mdbx_limits(-1), "single positive number")
  expect_error(mdbx_limits("4096"), "single page size")
  expect_error(mdbx_limits(c(4096, 8192)), "single page size")
})

test_that("a page size that could not survive the cast is refused in R", {
  # Every one of these used to reach a static_cast<intptr_t>, which is
  # undefined behaviour the moment the value does not fit.
  expect_error(mdbx_limits(Inf), "single positive number")
  expect_error(mdbx_limits(NaN), "single positive number")
  expect_error(mdbx_limits(NA_real_), "single positive number")
  expect_error(mdbx_limits(1e300), "too large")
  expect_error(mdbx_limits(2^63), "too large")
  expect_error(mdbx_limits(4096.5), "whole number")

  # And the native entry point guards its own cast, since ::: reaches it
  # without passing through mdbx_limits().
  expect_error(mdbx:::mdbx_limits_(Inf), "too large")
  expect_error(mdbx:::mdbx_limits_(2^63), "too large")
})
