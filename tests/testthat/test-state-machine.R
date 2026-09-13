# Generated operation sequences, checked against the reference model.
#
# These supplement the focused tests rather than replacing them. Each focused
# test states one contract; these explore the combinations of contracts, which
# is where the reviewed bugs actually lived -- a panic *and* a live
# transaction, a damaged record *and* a native convention that reads
# character(0) as "the main database".
#
# skip_on_cran() is deliberate, and not about runtime: the whole core corpus
# takes well under a second. It is about platform variance. This package's
# limits genuinely differ by page size -- test-limits.R records a key size that
# passed on macOS and failed elsewhere -- so a generated sequence that walks
# into a boundary can pass everywhere it is developed and fail on one CRAN
# machine, turning a discovery tool into a release blocker. They run in CI,
# where the platforms are known.
#
# Any failure here should be reduced to an ordinary named test before it is
# considered fixed. A seed is a way to find a bug, not a way to guard one:
# ?mdbx_dbi_drop's sequence-reset note and its test in test-dbi.R came from
# these sequences, and the test is what protects it now.

test_that("generated operation sequences match the reference model", {
  skip_on_cran()

  for (seed in state_machine_seeds()) {
    # run_mdbx_sequence() raises with the seed, step and full trace, so a
    # failure names itself rather than becoming assertion roulette.
    expect_silent(run_mdbx_sequence(seed, steps = state_machine_steps(), profile = "core"))
  }
})

test_that("a sequence leaves no environment or transaction behind", {
  skip_on_cran()

  gc()
  envs_before <- mdbx:::mdbx_env_open_count_()
  txns_before <- mdbx:::mdbx_txn_live_count_()

  run_mdbx_sequence(20260913L, steps = 80L, profile = "core")

  gc()
  gc()
  expect_identical(mdbx:::mdbx_env_open_count_(), envs_before)
  expect_identical(mdbx:::mdbx_txn_live_count_(), txns_before)
})

test_that("the same seed generates the same sequence", {
  skip_on_cran()

  # Reproducibility is what makes a reported seed worth anything: without it a
  # failure trace describes a run nobody can repeat.
  #
  # Compared with the fixture's directory stripped out. Each run gets its own
  # temporary directory, so the absolute paths differ by construction while the
  # spelling each command chose -- which is the generated decision -- does not.
  # Either separator: tempfile() returns backslashes on Windows, and only the
  # components file.path() added below the fixture directory use "/". Matching
  # "/" alone left the random directory name in the comparison there.
  strip_dir <- function(trace) {
    vapply(trace, function(command) {
      if (!is.null(command$path)) {
        command$path <- sub(".*[\\/]state-[^\\/]+[\\/]", "", command$path)
      }
      format_command(command)
    }, "")
  }

  first <- run_mdbx_sequence(4099L, steps = 40L, profile = "core")
  second <- run_mdbx_sequence(4099L, steps = 40L, profile = "core")

  expect_identical(strip_dir(first), strip_dir(second))
})
