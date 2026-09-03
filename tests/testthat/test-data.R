test_that("a value written in one transaction is readable in the next", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, charToRaw("answer"), charToRaw("42"))
  })

  value <- mdbx_with_read(env, function(txn) {
    mdbx_get(txn, charToRaw("answer"), as = "raw")
  })

  expect_type(value, "raw")
  expect_identical(value, charToRaw("42"))
})

test_that("a missing key returns NULL, or the supplied default", {
  env <- local_env()

  mdbx_with_read(env, function(txn) {
    expect_null(mdbx_get(txn, charToRaw("absent"), as = "raw"))
    expect_identical(mdbx_get(txn, charToRaw("absent"), default = charToRaw("d"), as = "raw"),
                     charToRaw("d"))
    expect_identical(mdbx_get(txn, charToRaw("absent"), default = NA, as = "raw"), NA)
  })
})

test_that("a stored zero-length value is distinguishable from absence", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, charToRaw("empty"), raw(0))
  })

  mdbx_with_read(env, function(txn) {
    value <- mdbx_get(txn, charToRaw("empty"), as = "raw")

    # Present, and empty -- not NULL. This is the whole reason NULL can mean
    # "absent" without ambiguity.
    expect_false(is.null(value))
    expect_identical(value, raw(0))
    expect_null(mdbx_get(txn, charToRaw("never-written"), as = "raw"))
  })
})

test_that("put replaces by default and refuses when overwrite is FALSE", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    expect_true(mdbx_put(txn, charToRaw("k"), charToRaw("first")))
    expect_true(mdbx_put(txn, charToRaw("k"), charToRaw("second")))
    expect_identical(mdbx_get(txn, charToRaw("k"), as = "raw"), charToRaw("second"))

    # Existing key, overwrite = FALSE: reported, not raised, and not replaced.
    expect_false(mdbx_put(txn, charToRaw("k"), charToRaw("third"), overwrite = FALSE))
    expect_identical(mdbx_get(txn, charToRaw("k"), as = "raw"), charToRaw("second"))

    # Absent key, overwrite = FALSE: stored.
    expect_true(mdbx_put(txn, charToRaw("fresh"), charToRaw("v"), overwrite = FALSE))
  })
})

test_that("delete reports whether a record existed", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, charToRaw("k"), charToRaw("v"))

    expect_true(mdbx_del(txn, charToRaw("k")))
    expect_null(mdbx_get(txn, charToRaw("k"), as = "raw"))

    # Deleting again, and deleting something never stored, are both FALSE.
    expect_false(mdbx_del(txn, charToRaw("k")))
    expect_false(mdbx_del(txn, charToRaw("never-there")))
  })
})

test_that("writes are visible on commit and discarded on abort", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, charToRaw("keep"), charToRaw("v"))
  })

  txn <- mdbx_txn_begin(env, write = TRUE)
  mdbx_put(txn, charToRaw("discard"), charToRaw("v"))
  mdbx_put(txn, charToRaw("keep"), charToRaw("changed"))
  mdbx_txn_abort(txn)

  mdbx_with_read(env, function(txn) {
    expect_null(mdbx_get(txn, charToRaw("discard"), as = "raw"))
    expect_identical(mdbx_get(txn, charToRaw("keep"), as = "raw"), charToRaw("v"))
  })
})

test_that("arbitrary bytes round-trip, including embedded NULs", {
  env <- local_env()

  key <- as.raw(c(0x61, 0x00, 0x62, 0x00))
  value <- as.raw(0:255)

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, key, value)

    # A key is its exact bytes, so a NUL does not truncate it: "a\0b\0" and
    # "a\0b" are different keys.
    mdbx_put(txn, as.raw(c(0x61, 0x00, 0x62)), charToRaw("shorter"))
  })

  mdbx_with_read(env, function(txn) {
    expect_identical(mdbx_get(txn, key, as = "raw"), value)
    expect_identical(mdbx_get(txn, as.raw(c(0x61, 0x00, 0x62)), as = "raw"), charToRaw("shorter"))
  })
})

test_that("an empty key is a usable key", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    expect_true(mdbx_put(txn, raw(0), charToRaw("v")))
  })

  mdbx_with_read(env, function(txn) {
    expect_identical(mdbx_get(txn, raw(0), as = "raw"), charToRaw("v"))
  })
})

test_that("large keys and values round-trip", {
  env <- local_env()

  big_key <- as.raw(rep(65L, 2000))
  big_value <- as.raw(rep(seq.int(0, 255), length.out = 4L * 1024L * 1024L))

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, big_key, big_value)
  })

  mdbx_with_read(env, function(txn) {
    round_tripped <- mdbx_get(txn, big_key, as = "raw")
    expect_length(round_tripped, length(big_value))
    expect_identical(round_tripped, big_value)
  })
})

test_that("the returned vector is a copy, not a view into the map", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, charToRaw("k"), charToRaw("original"))
  })

  # Read a value, then overwrite the key in a later transaction. libmdbx's
  # buffer is only valid until its transaction ends, so if this were a view the
  # earlier vector would now be garbage.
  first <- mdbx_with_read(env, function(txn) mdbx_get(txn, charToRaw("k"), as = "raw"))

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, charToRaw("k"), charToRaw("replaced"))
  })

  gc()
  expect_identical(first, charToRaw("original"))
})

test_that("serialized R objects round-trip", {
  env <- local_env()
  original <- list(a = 1:3, b = "text", c = TRUE)

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, charToRaw("obj"), serialize(original, NULL))
  })

  restored <- mdbx_with_read(env, function(txn) {
    unserialize(mdbx_get(txn, charToRaw("obj"), as = "raw"))
  })

  expect_identical(restored, original)
})

test_that("a read-only transaction refuses to modify the database", {
  env <- local_env()

  mdbx_with_read(env, function(txn) {
    expect_error(mdbx_put(txn, charToRaw("k"), charToRaw("v")), "read-only")
    expect_error(mdbx_del(txn, charToRaw("k")), "read-only")

    # Reading is still fine.
    expect_null(mdbx_get(txn, charToRaw("k"), as = "raw"))
  })
})

test_that("keys and values must be raw or a single string", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    expect_error(mdbx_put(txn, 42, "v"), "raw vector or a single string")
    expect_error(mdbx_put(txn, "k", 42), "raw vector or a single string")
    expect_error(mdbx_del(txn, 1L), "raw vector or a single string")
    expect_error(mdbx_get(txn, TRUE, as = "raw"), "raw vector or a single string")

    # A key is one key: neither a vector of them nor a missing value.
    expect_error(mdbx_get(txn, c("a", "b"), as = "raw"), "raw vector or a single string")
    expect_error(mdbx_get(txn, character(0), as = "raw"), "raw vector or a single string")
    expect_error(mdbx_get(txn, NA_character_, as = "raw"), "raw vector or a single string")

    expect_error(mdbx_put(txn, "k", "v", overwrite = NA), "TRUE or FALSE")
  })
})

test_that("a string key and its raw form are the same key", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, "shared", "written as a string")
  })

  mdbx_with_read(env, function(txn) {
    expect_identical(
      mdbx_get(txn, charToRaw("shared"), as = "raw"),
      charToRaw("written as a string")
    )
  })

  # And the reverse direction agrees too.
  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, charToRaw("other"), charToRaw("v"))
  })

  mdbx_with_read(env, function(txn) {
    expect_identical(mdbx_get(txn, "other", as = "raw"), charToRaw("v"))
  })
})

test_that("character keys are UTF-8 regardless of the string's encoding", {
  env <- local_env()

  # The same text in two encodings. charToRaw() alone would make these two
  # different keys -- 63 61 66 e9 versus 63 61 66 c3 a9 -- so a key written on
  # one platform would be unfindable on another.
  latin1 <- "caf\xe9"
  Encoding(latin1) <- "latin1"
  utf8 <- enc2utf8(latin1)

  expect_false(identical(charToRaw(latin1), charToRaw(utf8)))

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, latin1, "stored")
  })

  mdbx_with_read(env, function(txn) {
    # Found under the other encoding of the same text, and stored as UTF-8.
    expect_identical(mdbx_get(txn, utf8, as = "raw"), charToRaw("stored"))
    expect_identical(mdbx_get(txn, charToRaw(utf8), as = "raw"), charToRaw("stored"))
    expect_null(mdbx_get(txn, charToRaw(latin1), as = "raw"))
  })
})

test_that("a value written as a string still reads back as raw", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, "k", "text")
  })

  mdbx_with_read(env, function(txn) {
    value <- mdbx_get(txn, "k", as = "raw")

    # MDBX records no type, so there is nothing to decode back from.
    expect_type(value, "raw")
    expect_identical(rawToChar(value), "text")
  })
})

test_that("data operations reject finished transactions and non-transactions", {
  env <- local_env()

  txn <- mdbx_txn_begin(env, write = TRUE)
  mdbx_put(txn, charToRaw("k"), charToRaw("v"))
  mdbx_txn_commit(txn)

  expect_error(mdbx_get(txn, charToRaw("k"), as = "raw"), "already committed")
  expect_error(mdbx_put(txn, charToRaw("k"), charToRaw("v")), "already committed")
  expect_error(mdbx_del(txn, charToRaw("k")), "already committed")

  expect_error(mdbx_get(42, charToRaw("k"), as = "raw"), "mdbx_txn")
  expect_error(mdbx_put("nope", charToRaw("k"), charToRaw("v")), "mdbx_txn")
})

test_that("many keys in one transaction all round-trip", {
  env <- local_env()
  keys <- sprintf("key-%04d", 1:500)

  mdbx_with_write(env, function(txn) {
    for (k in keys) {
      mdbx_put(txn, charToRaw(k), charToRaw(toupper(k)))
    }
  })

  mdbx_with_read(env, function(txn) {
    values <- vapply(keys, function(k) rawToChar(mdbx_get(txn, charToRaw(k), as = "raw")), "")
    expect_identical(unname(values), toupper(keys))
  })
})

test_that("values are decoded as text by default", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, "greeting", "hello")
    mdbx_put(txn, "empty", "")
  })

  mdbx_with_read(env, function(txn) {
    # The round trip a string writer expects: put a string, get a string.
    expect_identical(mdbx_get(txn, "greeting"), "hello")
    expect_type(mdbx_get(txn, "greeting"), "character")

    expect_identical(mdbx_get(txn, "empty"), "")

    # Still the bytes when asked for them.
    expect_identical(mdbx_get(txn, "greeting", as = "raw"), charToRaw("hello"))

    # Absence is unaffected by decoding, and the default is never decoded.
    expect_null(mdbx_get(txn, "absent"))
    expect_identical(mdbx_get(txn, "absent", default = 42), 42)
  })
})

test_that("decoding non-text values fails loudly rather than corrupting them", {
  env <- local_env()

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, "object", serialize(list(a = 1), NULL))
    mdbx_put(txn, "nul", as.raw(c(0x61, 0x00, 0x62)))
    mdbx_put(txn, "invalid", as.raw(c(0xff, 0xfe)))
  })

  mdbx_with_read(env, function(txn) {
    # serialize() output contains NUL bytes, so the default read refuses.
    expect_error(mdbx_get(txn, "object"), "NUL byte")
    expect_error(mdbx_get(txn, "nul"), "NUL byte")

    # Bytes that are not valid UTF-8 are refused rather than mangled.
    expect_error(mdbx_get(txn, "invalid"), "valid UTF-8")

    # Every message points at the way to read it correctly.
    expect_error(mdbx_get(txn, "object"), 'as = "raw"')

    # And that way works.
    expect_identical(unserialize(mdbx_get(txn, "object", as = "raw")), list(a = 1))
    expect_identical(mdbx_get(txn, "nul", as = "raw"), as.raw(c(0x61, 0x00, 0x62)))
  })
})

test_that("decoded text keeps its UTF-8 encoding", {
  env <- local_env()

  latin1 <- "caf\xe9"
  Encoding(latin1) <- "latin1"
  utf8 <- enc2utf8(latin1)

  mdbx_with_write(env, function(txn) {
    mdbx_put(txn, "accented", latin1)
  })

  mdbx_with_read(env, function(txn) {
    value <- mdbx_get(txn, "accented")

    # Marked UTF-8, not left as the session's native encoding -- otherwise this
    # would come back wrong on a non-UTF-8 locale.
    expect_identical(Encoding(value), "UTF-8")
    expect_identical(value, utf8)
    expect_identical(nchar(value), 4L)
  })
})

test_that("as is validated", {
  env <- local_env()

  mdbx_with_read(env, function(txn) {
    expect_error(mdbx_get(txn, "k", as = "bytes"))
    expect_error(mdbx_get(txn, "k", as = 1))
  })
})
