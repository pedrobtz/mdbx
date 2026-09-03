test_that("linked libmdbx matches the vendored pin", {
  # Guards against a partial or stale vendor tree: the version reported here
  # comes from the amalgamation actually compiled into the shared object.
  # The pin is recorded in .agents/vendoring.md.
  v <- mdbx_version()

  expect_identical(v$major, 0L)
  expect_identical(v$minor, 14L)
  expect_identical(v$patch, 3L)
  expect_identical(v$describe, "v0.14.3-0-g251562b2")
})
