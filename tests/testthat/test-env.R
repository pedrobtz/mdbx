test_that("the default geometry is a large reservation, not a large file", {
  # The rest of the suite pins map_size so that valgrind can shadow the
  # mappings (see helper-env.R); this is the one place the libmdbx default is
  # exercised. It reserves tens of GB of address space while the file itself
  # stays tiny -- virtual, not resident, and not on disk.
  path <- env_path()
  env <- mdbx_env_open(path)

  info <- mdbx_env_info(env)
  expect_true(info$geo_upper > 1024^3)
  expect_true(info$geo_current < info$geo_upper)
  expect_true(file.size(path) < info$geo_upper)

  mdbx_env_close(env)
})

test_that("an environment opens, reports itself, and closes", {
  path <- env_path()

  env <- mdbx_env_open(path, map_size = test_map_size)

  expect_s3_class(env, "mdbx_env")
  expect_true(mdbx_env_is_open(env))
  expect_true(file.exists(path))

  # Single-file layout is the default, so the path is the data file itself.
  expect_false(dir.exists(path))

  expect_output(print(env), "<mdbx_env>", fixed = TRUE)
  expect_output(print(env), "read-write")
  expect_output(print(env), "single file")
  expect_output(print(env), "open")

  mdbx_env_close(env)

  expect_false(mdbx_env_is_open(env))
  expect_output(print(env), "closed")
})

test_that("subdir = TRUE uses the libmdbx directory layout", {
  path <- env_path()

  env <- mdbx_env_open(path, subdir = TRUE, map_size = test_map_size)
  on.exit(mdbx_env_close(env), add = TRUE)

  expect_true(dir.exists(path))
  expect_true(file.exists(file.path(path, "mdbx.dat")))
  expect_output(print(env), "directory")
})

test_that("an environment can be reopened at the same path", {
  path <- env_path()

  first <- mdbx_env_open(path, map_size = test_map_size)
  mdbx_env_close(first)

  second <- mdbx_env_open(path, create = FALSE, map_size = test_map_size)
  on.exit(mdbx_env_close(second), add = TRUE)

  expect_true(mdbx_env_is_open(second))
  expect_identical(basename(mdbx:::mdbx_env_path_(second)), basename(path))
})

test_that("an existing environment can be opened read-only", {
  path <- env_path()

  writable <- mdbx_env_open(path, map_size = test_map_size)
  mdbx_env_close(writable)

  env <- mdbx_env_open(path, readonly = TRUE, map_size = test_map_size)
  on.exit(mdbx_env_close(env), add = TRUE)

  expect_true(mdbx_env_is_open(env))
  expect_output(print(env), "read-only")
})

test_that("a missing environment is refused when it may not be created", {
  path <- env_path()

  expect_error(mdbx_env_open(path, create = FALSE), "create = FALSE", fixed = TRUE)
  expect_error(mdbx_env_open(path, readonly = TRUE), "readonly = TRUE", fixed = TRUE)

  # Neither attempt may leave anything behind.
  expect_false(file.exists(path))
})

test_that("an existing directory is not an existing environment", {
  # file.exists() is TRUE for a bare directory, and libmdbx detects the
  # directory layout and creates a database inside it -- so `create = FALSE`
  # used to create one anyway. An environment exists only if mdbx.dat does.
  dir <- file.path(tempdir(), sprintf("empty-%d", sample.int(1e6, 1)))
  dir.create(dir)

  expect_error(mdbx_env_open(dir, create = FALSE), "create = FALSE", fixed = TRUE)
  expect_error(mdbx_env_open(dir, readonly = TRUE), "readonly = TRUE", fixed = TRUE)
  expect_length(list.files(dir), 0L)

  # Once one exists there, both are satisfied.
  mdbx_env_close(mdbx_env_open(dir, subdir = TRUE))
  expect_true(file.exists(file.path(dir, "mdbx.dat")))
  mdbx_env_close(mdbx_env_open(dir, create = FALSE))
})

test_that("the layout reported is the one in use, not the one requested", {
  dir <- file.path(tempdir(), sprintf("layout-%d", sample.int(1e6, 1)))
  mdbx_env_close(mdbx_env_open(dir, subdir = TRUE))

  # Reopened with the default subdir = FALSE, but libmdbx detects the directory
  # layout -- so the object must not claim to be a single file.
  reopened <- mdbx_env_open(dir)
  expect_true(attr(reopened, "subdir"))
  expect_output(print(reopened), "directory")
  mdbx_env_close(reopened)

  single <- local_env()
  expect_false(attr(single, "subdir"))
  expect_output(print(single), "single file")
})

test_that("libmdbx failures surface as R conditions carrying the code", {
  path <- file.path(tempfile(), "nested", "cache.mdbx")

  # The parent directories do not exist, so this fails inside libmdbx rather
  # than in the R-level checks above.
  expect_error(mdbx_env_open(path), "mdbx error")
})

test_that("closing is idempotent", {
  path <- env_path()

  env <- mdbx_env_open(path, map_size = test_map_size)

  expect_silent(mdbx_env_close(env))
  expect_silent(mdbx_env_close(env))
  expect_false(mdbx_env_is_open(env))
})

test_that("using a closed environment is an error, not a crash", {
  path <- env_path()

  env <- mdbx_env_open(path, map_size = test_map_size)
  mdbx_env_close(env)

  expect_error(mdbx:::mdbx_env_path_(env), "closed")

  # The session survived, so the rest of the DLL is still callable.
  expect_identical(mdbx_version()$major, 0L)
})

test_that("non-environment objects are rejected", {
  expect_error(mdbx_env_is_open(42), "mdbx_env")
  expect_error(mdbx_env_close("not an environment"), "mdbx_env")
  expect_error(mdbx:::mdbx_env_path_(NULL), "mdbx_env")
})

test_that("an abandoned environment is closed by garbage collection", {
  path <- env_path()

  gc()
  before <- mdbx:::mdbx_env_live_count_()

  local({
    env <- mdbx_env_open(path, map_size = test_map_size)
    expect_true(mdbx_env_is_open(env))
  })

  # The only reference is gone; the finalizer must reclaim the handle.
  gc()
  gc()

  expect_identical(mdbx:::mdbx_env_live_count_(), before)
})

test_that("an explicitly closed environment is not double-closed by the finalizer", {
  path <- env_path()

  gc()
  before <- mdbx:::mdbx_env_live_count_()

  local({
    env <- mdbx_env_open(path, map_size = test_map_size)
    mdbx_env_close(env)
  })

  gc()
  gc()

  expect_identical(mdbx:::mdbx_env_live_count_(), before)
  expect_identical(mdbx_version()$major, 0L)
})

test_that("geometry and named-database options are accepted", {
  path <- env_path()

  env <- mdbx_env_open(path, max_dbs = 8, map_size = 4 * 1024^2)
  on.exit(mdbx_env_close(env), add = TRUE)

  expect_true(mdbx_env_is_open(env))
})

test_that("arguments are validated before reaching libmdbx", {
  path <- env_path()

  expect_error(mdbx_env_open(character(0)), "single non-empty string")
  expect_error(mdbx_env_open(NA_character_), "single non-empty string")
  expect_error(mdbx_env_open(""), "single non-empty string")
  expect_error(mdbx_env_open(1), "single non-empty string")

  expect_error(mdbx_env_open(path, readonly = NA), "TRUE or FALSE")
  expect_error(mdbx_env_open(path, create = "yes"), "TRUE or FALSE")
  expect_error(mdbx_env_open(path, subdir = c(TRUE, FALSE)), "TRUE or FALSE")

  expect_error(mdbx_env_open(path, max_dbs = 0), "positive number")
  expect_error(mdbx_env_open(path, map_size = -1), "positive number")
  expect_error(mdbx_env_open(path, map_size = Inf), "positive number")

  # Out-of-range values must be refused in R, not cast. A double-to-integer
  # conversion whose source is outside the destination range is undefined
  # behaviour in C++, and these are reachable from ordinary calls -- one extra
  # zero on map_size or max_dbs is enough. UBSan cannot catch what no test
  # runs, so these are the coverage that makes the sanitizer leg able to see a
  # regression here.
  expect_error(mdbx_env_open(path, max_dbs = 1e20), "too large")
  expect_error(mdbx_env_open(path, map_size = 1e20), "too large")

  # 2^63 is the specific value a naive `x > (double) PTRDIFF_MAX` guard lets
  # through, because PTRDIFF_MAX rounds up to 2^63 as a double.
  expect_error(mdbx_env_open(path, map_size = 2^63), "too large")

  # The boundary itself is accepted by the check; libmdbx then decides.
  expect_error(mdbx_env_open(path, map_size = 2^53), "mdbx error")

  expect_false(file.exists(path))
})

test_that("discrete environment arguments must be whole numbers", {
  path <- tempfile(fileext = ".mdbx")

  # Truncating a fraction is a wrong answer dressed as a success: max_dbs = 4.9
  # would quietly reserve four.
  expect_error(mdbx_env_open(path, max_dbs = 4.5), "whole number")
  expect_error(mdbx_env_open(path, map_size = 1048576.5), "whole number")
  expect_error(mdbx_env_open(path, max_readers = 8.25), "whole number")

  expect_false(file.exists(path))
})

test_that("sizes that could not survive the cast are refused", {
  path <- tempfile(fileext = ".mdbx")

  # Every one of these reaches a narrowing cast natively; out of range, that is
  # undefined behaviour rather than an error.
  expect_error(mdbx_env_open(path, max_dbs = 1e20), "too large")
  expect_error(mdbx_env_open(path, map_size = 2^63), "too large")
  expect_error(mdbx_env_open(path, map_size = Inf), "single positive number")
  expect_error(mdbx_env_open(path, max_dbs = NaN), "single positive number")

  # The native entry point guards its own casts too: ::: reaches it directly.
  expect_error(
    mdbx:::mdbx_env_open_(path, FALSE, FALSE, 1e20, 0, 0, 436L, character()),
    "too large"
  )

  expect_false(file.exists(path))
})
