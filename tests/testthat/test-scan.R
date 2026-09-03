filled_env <- function(keys, values = rep("v", length(keys))) {
  env <- local_env()
  mdbx_with_write(env, function(txn) {
    for (i in seq_along(keys)) mdbx_put(txn, keys[[i]], values[[i]])
  })
  env
}

test_that("keys come back in key order, not insertion order", {
  env <- filled_env(c("banana", "apple", "cherry"))

  mdbx_with_read(env, function(txn) {
    expect_identical(mdbx_keys(txn), c("apple", "banana", "cherry"))
  })
})

test_that("an empty database yields an empty result of the right type", {
  env <- local_env()

  mdbx_with_read(env, function(txn) {
    expect_identical(mdbx_keys(txn), character(0))
    expect_identical(mdbx_keys(txn, as = "raw"), list())

    items <- mdbx_items(txn)
    expect_identical(items$keys, character(0))
    expect_identical(items$values, character(0))
  })
})

test_that("limit takes the first n in key order", {
  env <- filled_env(sprintf("k%02d", 1:10))

  mdbx_with_read(env, function(txn) {
    expect_identical(mdbx_keys(txn, limit = 3), c("k01", "k02", "k03"))
    expect_length(mdbx_keys(txn, limit = 0), 0L)

    # A limit past the end is simply everything.
    expect_length(mdbx_keys(txn, limit = 1000), 10L)

    # NULL and Inf both mean "all of them".
    expect_identical(mdbx_keys(txn, limit = NULL), mdbx_keys(txn, limit = Inf))

    expect_length(mdbx_items(txn, limit = 4)$keys, 4L)
    expect_length(mdbx_items(txn, limit = 4)$values, 4L)
  })
})

test_that("items returns parallel keys and values", {
  env <- filled_env(c("a", "b", "c"), c("1", "2", "3"))

  mdbx_with_read(env, function(txn) {
    items <- mdbx_items(txn)

    expect_named(items, c("keys", "values"))
    expect_identical(items$keys, c("a", "b", "c"))
    expect_identical(items$values, c("1", "2", "3"))

    # The documented way to turn it into a lookup.
    lookup <- stats::setNames(items$values, items$keys)
    expect_identical(lookup[["b"]], "2")

    # Each value agrees with a direct read of its key.
    for (i in seq_along(items$keys)) {
      expect_identical(mdbx_get(txn, items$keys[[i]]), items$values[[i]])
    }
  })
})

test_that("as = raw returns the exact bytes", {
  env <- local_env()
  key <- as.raw(c(0x61, 0x00, 0x62))

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, key, serialize(list(x = 1), NULL))
  })

  mdbx_with_read(env, function(txn) {
    keys <- mdbx_keys(txn, as = "raw")
    expect_type(keys, "list")
    expect_identical(keys[[1]], key)

    items <- mdbx_items(txn, as = "raw")
    expect_identical(unserialize(items$values[[1]]), list(x = 1))
  })
})

test_that("decoding refuses keys and values that are not text", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, as.raw(c(0x61, 0x00)), "v")
  })

  mdbx_with_read(env, function(txn) {
    # Same policy as mdbx_get(): fail loudly rather than corrupt.
    expect_error(mdbx_keys(txn), "NUL byte")
    expect_error(mdbx_items(txn), "NUL byte")

    expect_length(mdbx_keys(txn, as = "raw"), 1L)
  })
})

test_that("a scan sees the transaction's own uncommitted writes", {
  env <- local_env()

  txn <- mdbx_txn_begin(env, write = TRUE)
  mdbx_put(txn, "pending", "1")

  expect_identical(mdbx_keys(txn), "pending")

  mdbx_txn_abort(txn)

  mdbx_with_read(env, function(txn) {
    expect_identical(mdbx_keys(txn), character(0))
  })
})

test_that("deleted keys leave the listing", {
  env <- filled_env(c("a", "b", "c"))

  mdbx_with_write(env, function(txn) mdbx_del(txn, "b"))

  mdbx_with_read(env, function(txn) {
    expect_identical(mdbx_keys(txn), c("a", "c"))
  })
})

test_that("a larger scan returns every record exactly once", {
  keys <- sprintf("key-%04d", 1:2000)
  env <- filled_env(keys, as.character(1:2000))

  mdbx_with_read(env, function(txn) {
    found <- mdbx_items(txn)

    expect_length(found$keys, 2000L)
    expect_identical(found$keys, sort(keys))
    expect_identical(anyDuplicated(found$keys), 0L)
    expect_identical(found$values[[1]], "1")

    # Consistent with what the statistics report.
    expect_identical(mdbx_env_stat(txn)$entries, 2000)
  })
})

test_that("scan arguments are validated", {
  env <- local_env()

  mdbx_with_read(env, function(txn) {
    expect_error(mdbx_keys(txn, limit = -1), "non-negative")
    expect_error(mdbx_keys(txn, limit = "10"), "non-negative")
    expect_error(mdbx_keys(txn, limit = c(1, 2)), "non-negative")
    expect_error(mdbx_keys(txn, limit = NA), "non-negative")
    expect_error(mdbx_keys(txn, as = "bytes"))

    # Same narrowing-cast hazard as map_size/max_dbs; see test-env.R.
    expect_error(mdbx_keys(txn, limit = 1e20), "too large")
    expect_error(mdbx_items(txn, limit = 1e20), "too large")

    # Inf still means "all of them" rather than tripping the bound.
    expect_length(mdbx_keys(txn, limit = Inf), 0L)
  })

  expect_error(mdbx_keys(42), "mdbx_txn")
  expect_error(mdbx_items("nope"), "mdbx_txn")
})

test_that("scanning a finished transaction is an error", {
  env <- local_env()

  txn <- mdbx_txn_begin(env)
  mdbx_txn_abort(txn)

  expect_error(mdbx_keys(txn), "already aborted")
  expect_error(mdbx_items(txn), "already aborted")
})

test_that("an unbounded scan of a large database is refused", {
  env <- local_env()

  # Rather than writing a million records, lower the bar to meet the data.
  local_mocked_bindings(mdbx_scan_max = 3)

  mdbx_with_write(env, function(txn) {
    for (i in 1:5) mdbx_put(txn, sprintf("k%d", i), "v")
  })

  mdbx_with_read(env, function(txn) {
    expect_error(mdbx_keys(txn), "refused by default")
    expect_error(mdbx_keys(txn), "limit = Inf", fixed = TRUE)
    expect_error(mdbx_items(txn), "refused by default")

    # An explicit limit is honoured, guard or no guard.
    expect_length(mdbx_keys(txn, limit = 2), 2L)

    # And Inf is the documented way to say "all of them, really".
    expect_length(mdbx_keys(txn, limit = Inf), 5L)
    expect_length(mdbx_items(txn, limit = Inf)$keys, 5L)
  })
})

test_that("the guard leaves ordinary databases alone", {
  env <- filled_env(sprintf("k%02d", 1:10))

  mdbx_with_read(env, function(txn) {
    expect_length(mdbx_keys(txn), 10L)
    expect_length(mdbx_items(txn)$keys, 10L)
  })
})

# Ordered access: the patterns a cache index needs. Keys here are big-endian
# integers, because byte order is the only order libmdbx has -- a key encoded
# any other way sorts wrongly and every scan below would be meaningless.
be32 <- function(x) {
  x <- as.integer(x)
  as.raw(c(x %/% 2^24 %% 256, x %/% 2^16 %% 256, x %/% 2^8 %% 256, x %% 256))
}

indexed_env <- function(times = c(500, 100, 900, 300, 700)) {
  env <- local_env()
  mdbx_with_write(env, function(txn) {
    for (t in times) mdbx_put(txn, be32(t), sprintf("at-%d", t))
  })
  env
}

values_of <- function(x) unname(unlist(x$values))

test_that("reverse walks from the last key", {
  env <- indexed_env()

  mdbx_with_read(env, function(txn) {
    # The largest key, without reading every key to find it.
    expect_identical(values_of(mdbx_items(txn, limit = 1, reverse = TRUE, keys_as = "raw")),
                     "at-900")
    expect_identical(values_of(mdbx_items(txn, limit = 2, reverse = TRUE, keys_as = "raw")),
                     c("at-900", "at-700"))

    # Reversing the whole thing is the forward order backwards.
    forward <- values_of(mdbx_items(txn, keys_as = "raw"))
    backward <- values_of(mdbx_items(txn, reverse = TRUE, keys_as = "raw"))
    expect_identical(backward, rev(forward))
  })

  mdbx_env_close(env)
})

test_that("start seeks, and does not require an exact match", {
  env <- indexed_env()

  mdbx_with_read(env, function(txn) {
    # Forwards: the first key at or after the mark.
    expect_identical(values_of(mdbx_items(txn, start = be32(300), keys_as = "raw")),
                     c("at-300", "at-500", "at-700", "at-900"))
    expect_identical(values_of(mdbx_items(txn, start = be32(301), keys_as = "raw")),
                     c("at-500", "at-700", "at-900"))

    # Backwards: the last key at or before it, which means stepping back when
    # the seek overshoots.
    expect_identical(values_of(mdbx_items(txn, start = be32(600), reverse = TRUE, keys_as = "raw")),
                     c("at-500", "at-300", "at-100"))
    expect_identical(values_of(mdbx_items(txn, start = be32(500), reverse = TRUE, keys_as = "raw")),
                     c("at-500", "at-300", "at-100"))

    # Past either end.
    expect_length(mdbx_items(txn, start = be32(1000), keys_as = "raw")$keys, 0L)
    expect_identical(values_of(mdbx_items(txn, start = be32(1000), reverse = TRUE, keys_as = "raw")),
                     c("at-900", "at-700", "at-500", "at-300", "at-100"))
    expect_length(mdbx_items(txn, start = be32(1), reverse = TRUE, keys_as = "raw")$keys, 0L)
  })

  mdbx_env_close(env)
})

test_that("start makes iteration resumable in chunks", {
  env <- indexed_env(seq(100, 2000, by = 100))

  seen <- character(0)
  from <- NULL
  mdbx_with_read(env, function(txn) {
    repeat {
      chunk <- mdbx_items(txn, limit = 3, start = from, keys_as = "raw")
      if (length(chunk$keys) == 0) break
      # Skip the key the previous chunk ended on, which `start` includes.
      keep <- if (is.null(from)) seq_along(chunk$keys) else seq_along(chunk$keys)[-1]
      seen <<- c(seen, values_of(chunk)[keep])
      if (length(chunk$keys) < 3) break
      from <<- chunk$keys[[length(chunk$keys)]]
    }
  })

  expect_length(seen, 20L)
  expect_identical(seen[1], "at-100")
  expect_identical(seen[20], "at-2000")
  expect_identical(anyDuplicated(seen), 0L)
})

test_that("keys and values can be decoded differently", {
  env <- indexed_env()

  mdbx_with_read(env, function(txn) {
    # The case an index always has: binary keys, text values.
    items <- mdbx_items(txn, limit = 1, keys_as = "raw")
    expect_true(is.raw(items$keys[[1]]))
    expect_type(items$values, "character")

    # Both raw, and both character, still work.
    expect_true(is.raw(mdbx_items(txn, limit = 1, as = "raw")$values[[1]]))
    expect_error(mdbx_items(txn, limit = 1), "NUL byte")
  })

  mdbx_env_close(env)
})

test_that("ordered scans are validated", {
  env <- indexed_env()

  mdbx_with_read(env, function(txn) {
    expect_error(mdbx_keys(txn, reverse = NA), "TRUE or FALSE")
    expect_error(mdbx_items(txn, start = 42), "raw vector or a single string")
    expect_error(mdbx_items(txn, keys_as = "bytes"))
  })

  mdbx_env_close(env)
})

test_that("`start` does not exempt a scan from the unbounded guard", {
  env <- indexed_env()

  mdbx_with_read(env, function(txn) {
    local_mocked_bindings(mdbx_scan_max = 1)

    # A start key positions the cursor; it bounds one end of the walk and
    # nothing else, so the whole database can still come back. An empty start
    # is the plain case: it begins before every key.
    expect_error(mdbx_keys(txn, as = "raw"), "refused by default")
    expect_error(mdbx_keys(txn, start = raw(0), as = "raw"), "refused by default")
    expect_error(mdbx_keys(txn, start = be32(1), as = "raw"), "refused by default")
    expect_error(mdbx_items(txn, start = be32(1), keys_as = "raw"), "refused by default")

    # An explicit limit is what lifts it, `start` or no `start`.
    expect_length(mdbx_keys(txn, start = be32(1), limit = 2, as = "raw"), 2L)
    expect_length(mdbx_keys(txn, start = be32(1), limit = Inf, as = "raw"), 5L)
  })

  mdbx_env_close(env)
})

test_that("the unbounded guard counts the database being scanned", {
  env <- local_env(max_dbs = 4)

  small <- mdbx_with_write(env, function(txn) {
    db <- mdbx_dbi_open(txn, "small", create = TRUE)
    mdbx_put(txn, "only", "1", db = db)
    for (k in letters) mdbx_put(txn, k, k)
    db
  })

  mdbx_with_read(env, function(txn) {
    local_mocked_bindings(mdbx_scan_max = 10)

    # The main database is over the ceiling, the named one is not. Counting the
    # main one for both would refuse a one-record scan.
    expect_error(mdbx_keys(txn), "refused by default")
    expect_identical(mdbx_keys(txn, db = small), "only")
  })

  mdbx_env_close(env)
})
