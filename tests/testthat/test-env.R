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

test_that("a second open on the same path in one process is refused by name", {
  path <- env_path()

  env <- mdbx_env_open(path, map_size = test_map_size)

  # libmdbx forbids this, and reports it as whatever its lock file failed with
  # -- EAGAIN on macOS. The refusal has to name the conflict instead, whatever
  # the second call's other arguments say.
  expect_error(mdbx_env_open(path, map_size = test_map_size),
               "already open in this process")
  expect_error(mdbx_env_open(path, readonly = TRUE, map_size = test_map_size),
               "already open in this process")
  expect_error(mdbx_env_open(path, flags = "ACCEDE", map_size = test_map_size),
               "already open in this process")

  # The first handle is untouched by the refusals.
  expect_true(mdbx_env_is_open(env))
  mdbx_with_write(env, function(txn) mdbx_put(txn, "k", "v"))

  # And the path is free again the moment it closes.
  mdbx_env_close(env)
  reopened <- mdbx_env_open(path, map_size = test_map_size)
  expect_identical(mdbx_with_read(reopened, function(txn) mdbx_get(txn, "k")), "v")
  mdbx_env_close(reopened)
})

test_that("an open that fails does not reserve the path", {
  # Registration happens only once libmdbx has accepted the open. A failure
  # that registered anyway would lock the path out for the session.
  dir <- tempfile()
  path <- file.path(dir, "nested", "cache.mdbx")

  # Fails inside libmdbx: the parent directories do not exist yet.
  expect_error(mdbx_env_open(path, map_size = test_map_size), "mdbx error")

  dir.create(dirname(path), recursive = TRUE)
  env <- mdbx_env_open(path, map_size = test_map_size)
  on.exit(mdbx_env_close(env), add = TRUE)
  expect_true(mdbx_env_is_open(env))
})

test_that("a close refused for an open transaction keeps the path taken", {
  path <- env_path()

  env <- mdbx_env_open(path, map_size = test_map_size)
  txn <- mdbx_txn_begin(env, write = TRUE)

  # The refusal happens before anything is detached, so the environment is
  # still open and the path still belongs to it.
  expect_error(mdbx_env_close(env), "still open")
  expect_error(mdbx_env_open(path, map_size = test_map_size),
               "already open in this process")

  mdbx_txn_abort(txn)
  mdbx_env_close(env)

  reopened <- mdbx_env_open(path, map_size = test_map_size)
  on.exit(mdbx_env_close(reopened), add = TRUE)
  expect_true(mdbx_env_is_open(reopened))
})

test_that("a directory-layout environment is refused the same way", {
  dir <- file.path(tempdir(), sprintf("dup-%d", sample.int(1e6, 1)))

  env <- mdbx_env_open(dir, subdir = TRUE, map_size = test_map_size)
  expect_error(mdbx_env_open(dir, map_size = test_map_size),
               "already open in this process")

  mdbx_env_close(env)
  mdbx_env_close(mdbx_env_open(dir, map_size = test_map_size))
})

test_that("two spellings of one path are one environment", {
  # The registry compares strings, so env_key() canonicalises them first.
  # Without it each of these reaches libmdbx and fails on the lock file.
  dir <- tempfile("spell-")
  dir.create(dir)
  path <- file.path(dir, "c.mdbx")

  env <- mdbx_env_open(path, map_size = test_map_size)
  on.exit(mdbx_env_close(env), add = TRUE)

  expect_error(mdbx_env_open(file.path(dir, ".", "c.mdbx"), map_size = test_map_size),
               "already open in this process")
  expect_error(mdbx_env_open(file.path(dir, "..", basename(dir), "c.mdbx"),
                             map_size = test_map_size),
               "already open in this process")

  # And relative to the directory itself.
  old <- setwd(dir)
  on.exit(setwd(old), add = TRUE, after = FALSE)
  expect_error(mdbx_env_open("c.mdbx", map_size = test_map_size),
               "already open in this process")
  expect_error(mdbx_env_open("./c.mdbx", map_size = test_map_size),
               "already open in this process")
})

test_that("a refusal names the spelling the open handle was created under", {
  # Matching on the canonical key means the caller can be refused over a path
  # they did not write. The one they did write is no use on its own.
  dir <- tempfile("spell-")
  dir.create(dir)
  path <- file.path(dir, "c.mdbx")

  env <- mdbx_env_open(path, map_size = test_map_size)
  on.exit(mdbx_env_close(env), add = TRUE)

  message <- conditionMessage(tryCatch(
    mdbx_env_open(file.path(dir, ".", "c.mdbx"), map_size = test_map_size),
    error = identity
  ))
  expect_match(message, file.path(dir, ".", "c.mdbx"), fixed = TRUE)
  expect_match(message, sprintf("as '%s'", path), fixed = TRUE)

  # The same spelling twice says it once, with no "as" clause to puzzle over.
  same <- conditionMessage(tryCatch(
    mdbx_env_open(path, map_size = test_map_size), error = identity
  ))
  expect_false(grepl(", as '", same, fixed = TRUE))
})

test_that("a symlinked directory is the same environment", {
  skip_on_os("windows")

  dir <- tempfile("real-")
  dir.create(dir)
  link <- tempfile("link-")
  skip_if_not(file.symlink(dir, link), "could not create a symlink")

  env <- mdbx_env_open(file.path(dir, "c.mdbx"), map_size = test_map_size)
  on.exit(mdbx_env_close(env), add = TRUE)

  expect_error(mdbx_env_open(file.path(link, "c.mdbx"), map_size = test_map_size),
               "already open in this process")
})

test_that("a subdir environment and its data file are the same environment", {
  # With subdir = TRUE the environment is the directory and its data lives in
  # mdbx.dat; that file is a second, perfectly ordinary spelling of it.
  dir <- tempfile("sub-")

  env <- mdbx_env_open(dir, subdir = TRUE, map_size = test_map_size)
  on.exit(mdbx_env_close(env), add = TRUE)

  expect_error(mdbx_env_open(file.path(dir, "mdbx.dat"), map_size = test_map_size),
               "already open in this process")

  # A trailing slash is the same directory, as basename() and dirname() read it.
  expect_error(mdbx_env_open(paste0(dir, "/"), subdir = TRUE, map_size = test_map_size),
               "already open in this process")

  # And the other way round: the data file first, then the directory.
  other <- tempfile("sub-")
  dir.create(other)
  first <- mdbx_env_open(file.path(other, "mdbx.dat"), map_size = test_map_size)
  on.exit(mdbx_env_close(first), add = TRUE)
  expect_error(mdbx_env_open(other, subdir = TRUE, map_size = test_map_size),
               "already open in this process")
})

test_that("subdir decides the layout only when nothing is there yet", {
  # `subdir` says what to *create*; an environment that already exists has a
  # layout of its own. Letting the argument decide regardless would key
  # subdir = TRUE against an existing single-file environment as a directory
  # that cannot exist, and this open would miss the registry.
  path <- env_path()

  env <- mdbx_env_open(path, map_size = test_map_size)
  on.exit(mdbx_env_close(env), add = TRUE)
  expect_false(attr(env, "subdir"))

  expect_error(mdbx_env_open(path, subdir = TRUE, map_size = test_map_size),
               "already open in this process")
})

test_that("the registry of open paths does not grow", {
  # A leaked entry refuses a reopen libmdbx would have allowed, and nothing
  # else would show it -- mdbx_env_live_count_() counts handles, not paths.
  #
  # gc() first, as the live-handle tests below do: environments other tests
  # abandoned are still registered until their finalizers run, and the baseline
  # has to be taken once they have.
  gc()
  before <- mdbx:::mdbx_env_open_count_()

  for (i in 1:5) {
    env <- mdbx_env_open(env_path(), map_size = test_map_size)
    expect_identical(mdbx:::mdbx_env_open_count_(), before + 1L)
    mdbx_env_close(env)
    expect_identical(mdbx:::mdbx_env_open_count_(), before)
  }

  # Including the ones nobody closed, and the ones that never opened.
  local(invisible(mdbx_env_open(env_path(), map_size = test_map_size)))
  expect_error(mdbx_env_open(file.path(tempfile(), "no", "where.mdbx")), "mdbx error")

  gc()
  gc()

  expect_identical(mdbx:::mdbx_env_open_count_(), before)
})

test_that("an environment collected without an explicit close frees its path", {
  path <- env_path()

  # The registry entry is dropped by whichever of close and finalization
  # happens first, so a handle abandoned to the GC must not hold the path.
  local({
    abandoned <- mdbx_env_open(path, map_size = test_map_size)
    invisible(NULL)
  })
  gc()

  env <- mdbx_env_open(path, map_size = test_map_size)
  on.exit(mdbx_env_close(env), add = TRUE)
  expect_true(mdbx_env_is_open(env))
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
    mdbx:::mdbx_env_open_(path, path, FALSE, FALSE, 1e20, 0, 0, 436L, character()),
    "too large"
  )

  expect_false(file.exists(path))
})
