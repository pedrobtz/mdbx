# Error translation, and the failure paths that are hard to reach.
#
# libmdbx statuses reach R through mdbx_r::check(). Most of that layer is
# invisible until something goes wrong, so these provoke real failures --
# a corrupted file, an unwritable directory -- and push every documented status
# code through the translator directly.

test_that("every libmdbx error code translates to a message naming it", {
  codes <- mdbx:::mdbx_test_error_codes_()
  expect_gt(length(codes), 20)

  for (name in names(codes)) {
    message <- conditionMessage(
      tryCatch(mdbx:::mdbx_test_check_(codes[[name]]), error = identity)
    )
    # libmdbx's own strerror prefixes its statuses with the symbolic name, so a
    # message that lacks it means the code fell through to a numeric fallback.
    expect_true(grepl(name, message, fixed = TRUE),
                info = sprintf("%s rendered as: %s", name, message))
    expect_match(message, sprintf("mdbx error %d", codes[[name]]), fixed = TRUE)
  }
})

test_that("success is not an error, and system errno codes still translate", {
  expect_silent(mdbx:::mdbx_test_check_(0L))

  # Not every status is an MDBX code; libmdbx passes system errno through.
  expect_match(conditionMessage(tryCatch(mdbx:::mdbx_test_check_(13L), error = identity)),
               "mdbx error 13", fixed = TRUE)
})

test_that("MDBX_RESULT_TRUE is a trap every call site has to handle itself", {
  # It is a result, not an error: strerror has no name for it, so translating
  # it yields "error -1". This asserts the trap is real, which is the reason
  # the three entry points below special-case it -- if libmdbx ever gave it a
  # name, this test would fail and the special cases could be revisited.
  result_true <- mdbx:::mdbx_test_result_true_()
  expect_identical(result_true, -1L)
  expect_match(conditionMessage(tryCatch(mdbx:::mdbx_test_check_(result_true),
                                         error = identity)),
               "error -1", fixed = TRUE)

  # Every public function that can receive it turns it into something useful.
  env <- local_env(flags = "SAFE_NOSYNC")
  mdbx_with_write(env, function(txn) mdbx_put(txn, "k", "v"))

  expect_true(mdbx_env_sync(env))    # flushed something
  expect_false(mdbx_env_sync(env))   # MDBX_RESULT_TRUE: nothing pending
  expect_identical(mdbx_env_reader_check(env), 0L)

  mdbx_env_close(env)
})

test_that("a corrupted database is reported, not crashed on", {
  path <- env_path()
  env <- mdbx_env_open(path, map_size = 8 * 1024^2)
  mdbx_with_write(env, function(txn) mdbx_put(txn, "k", "v"))
  mdbx_env_close(env)

  # Overwrite the meta pages at the head of the file.
  con <- file(path, open = "r+b")
  writeBin(as.raw(rep(0xff, 512)), con)
  close(con)

  expect_error(mdbx_env_open(path), "MDBX_CORRUPTED")

  # The R session survives it, which is the part worth asserting: libmdbx's
  # own reaction to a corrupt database would otherwise be to abort.
  expect_identical(mdbx_version()$major, 0L)
})

test_that("a file that is not a database is reported as invalid", {
  path <- env_path()

  # Size matters here. A junk file smaller than libmdbx's minimum database size
  # is treated as an empty one and re-initialised in place -- measured at 2300
  # bytes, which opens without complaint. Only a file big enough to plausibly
  # hold a database is rejected, so this writes 128 KB of nonsense.
  writeLines(rep("this is not a database", 6000), path)
  expect_gt(file.size(path), 100000)

  expect_error(mdbx_env_open(path), "MDBX_INVALID")
  expect_identical(mdbx_version()$major, 0L)
})

test_that("an unwritable location is an error, not a crash", {
  skip_on_os("windows")
  skip_if(Sys.info()[["effective_user"]] == "root", "root ignores file permissions")

  dir <- file.path(tempdir(), "mdbx-unwritable")
  dir.create(dir, showWarnings = FALSE)
  Sys.chmod(dir, "500")
  on.exit(Sys.chmod(dir, "700"), add = TRUE)

  expect_error(mdbx_env_open(file.path(dir, "denied.mdbx")), "mdbx error 13")
})

test_that("a panic is contained and named rather than ending the session", {
  # The guard boundary itself is covered in test-native-safety.R; this asserts
  # the same path reports through the same translator as everything else.
  expect_error(mdbx:::mdbx_test_panic_boundary_(), "libmdbx assertion failed")
  expect_identical(mdbx_version()$major, 0L)
})
