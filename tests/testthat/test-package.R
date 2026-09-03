test_that("package namespace loads", {
  # Trivial while the package is pure R. From stage 1 onward this is the
  # cheapest check that the vendored libmdbx build linked and loaded.
  expect_true(isNamespaceLoaded("mdbx"))
})
