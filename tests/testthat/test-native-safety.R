# Native handle safety: authentication, lifecycle, and what survives a panic.
#
# The entry points that dereference a native handle go through one
# authenticator each -- env_from_sexp() and txn_from_sexp() -- so most of them
# share the tests below rather than needing one apiece. What does need its own
# row is any entry point that deliberately bypasses the authenticator to stay
# state-tolerant or idempotent: mdbx_env_close(), mdbx_env_is_open(),
# mdbx_txn_abort() and mdbx_txn_state(). Those four are why this file exists;
# three of them once read a handle before checking that it was theirs.
#
# The states worth crossing, and where each is covered:
#
#   External pointer  genuine ............. every test here
#                     wrong tag ........... "identified by its tag"
#                     unrelated pointer ... "identified by its tag" (stranger)
#                     cleared pointer ..... not reachable from R: the address is
#                                           cleared only by the finalizer, which
#                                           runs on an object already
#                                           unreachable. A foreign pointer is
#                                           null too, and the tag refuses it
#                                           first.
#   Transaction       active/committed/aborted ... test-txn.R
#                     failed .............. test-txn.R, after MDBX_MAP_FULL
#                     poisoned ............ "panic in a transaction operation"
#   Owner             open ................ every test here
#                     closed/detached ..... "a transaction outliving its
#                                           environment", and test-txn.R's
#                                           simultaneous finalization
#                     poisoned ............ "panic with a live transaction"
#   Process           creator ............. every test here
#                     forked child ........ test-fork.R
#   Cleanup order     transaction first ... "panic with a live transaction"
#                     environment first ... "closing a poisoned environment"
#                     GC first ............ "leaves no transaction registered",
#                                           and test-txn.R
#
# Adding an entry point that touches a handle means placing it in that grid:
# either it uses the central authenticator and is covered, or it does not and
# needs a row.

test_that("package initialization silences the libmdbx after-fork notice", {
  skip_if_cannot_fork()

  log_file <- tempfile()
  connection <- file(log_file, open = "wt")
  sink_depth <- sink.number(type = "message")
  connection_open <- TRUE

  on.exit({
    while (sink.number(type = "message") > sink_depth) {
      sink(type = "message")
    }
    if (connection_open) {
      close(connection)
    }
  }, add = TRUE)

  sink(connection, type = "message")
  # Positive control: proves the capture below is actually wired up, so a sink
  # that silently stopped working could not make this test pass vacuously.
  message("fork-capture-control")
  job <- parallel::mcparallel(invisible(TRUE))
  result <- parallel::mccollect(job)
  sink(type = "message")
  close(connection)
  connection_open <- FALSE

  captured <- readLines(log_file, warn = FALSE)

  expect_identical(unname(result), list(TRUE))
  expect_true(any(grepl("fork-capture-control", captured, fixed = TRUE)))

  # libmdbx's after-fork hook (rthc_afterfork) logs at NOTICE: one "drown %d
  # rthc entries" line, plus a "drown env %p" line per live environment.
  # Package load lowers the global level to FATAL so none of them reach the
  # console. Assert on that signature rather than on an empty stream: other
  # lines here belong to the front-end -- Positron writes its own when forking
  # -- and silencing those is not this package's contract.
  expect_identical(grep("drown|rthc", captured, value = TRUE), character(0))
})

test_that("a guarded panic poisons its owner before becoming an R error", {
  expect_error(
    mdbx:::mdbx_test_panic_boundary_(),
    "libmdbx assertion failed: panic-boundary test"
  )

  # The panic was contained below C++, so the DLL remains callable.
  expect_identical(mdbx_version()$major, 0L)
})

test_that("a panic inside stat or info poisons the environment", {
  for (info in c(FALSE, TRUE)) {
    env <- local_env()
    expect_error(mdbx:::mdbx_test_panic_stat_(env, info),
                 "libmdbx assertion failed: stat-guard test")

    # The point of poisoning: nothing may re-enter an environment whose
    # invariants have just failed. These two calls used to install no poison
    # callback at all, so a panic in them became an R error while leaving the
    # handle apparently usable.
    expect_error(mdbx_env_stat(env), "unusable after a libmdbx assertion")
    expect_error(mdbx_env_info(env), "unusable after a libmdbx assertion")
    expect_error(mdbx_txn_begin(env), "unusable after a libmdbx assertion")

    # Closing is the one thing that must still work, and it must not re-enter
    # libmdbx: the handle is dropped and the mapping left to the OS.
    expect_silent(mdbx_env_close(env))
    expect_false(mdbx_env_is_open(env))
  }
})

test_that("a handle is identified by its tag, not by its class attribute", {
  # `class<-` on an external pointer modifies it in place -- there is no copy to
  # reclass -- so each forgery below needs a handle of its own.
  env <- local_env()
  txn <- mdbx_txn_begin(env)

  # Both handle types are EXTPTRSXP, so the class was the only thing telling
  # them apart. Reclassing a transaction as an environment used to make the
  # entry point read a txn_handle as an env_handle, reporting a fabricated
  # owner pid from the wrong offset -- and mdbx_env_close() read a garbage
  # transaction count the same way.
  class(txn) <- "mdbx_env"
  expect_error(mdbx_env_stat(txn), "expected an 'mdbx_env' object")
  expect_error(mdbx_env_info(txn), "expected an 'mdbx_env' object")
  expect_error(mdbx_env_close(txn), "expected an 'mdbx_env' object")
  expect_error(mdbx_env_is_open(txn), "expected an 'mdbx_env' object")

  env2 <- local_env()
  class(env2) <- "mdbx_txn"
  expect_error(mdbx_get(env2, "k"), "expected an 'mdbx_txn' object")
  expect_error(mdbx_txn_commit(env2), "expected an 'mdbx_txn' object")

  # The state-tolerant entry points have to authenticate too, and used not to:
  # they checked the class and then read an env_handle through the txn_handle
  # layout. mdbx_txn_state() answered "aborted" for this, having read the
  # environment's pid where a txn_state belongs.
  expect_error(mdbx_txn_state(env2), "expected an 'mdbx_txn' object")
  expect_error(mdbx_txn_abort(env2), "expected an 'mdbx_txn' object")

  # R has no way to set an external pointer's tag, so a pointer from anywhere
  # else cannot be dressed up as either handle.
  stranger <- methods::new("externalptr")
  class(stranger) <- "mdbx_env"
  expect_error(mdbx_env_stat(stranger), "expected an 'mdbx_env' object")
  expect_error(mdbx_env_close(stranger), "expected an 'mdbx_env' object")

  another <- methods::new("externalptr")
  class(another) <- "mdbx_txn"
  expect_error(mdbx_txn_state(another), "expected an 'mdbx_txn' object")
  expect_error(mdbx_txn_abort(another), "expected an 'mdbx_txn' object")
  expect_error(mdbx_txn_commit(another), "expected an 'mdbx_txn' object")
  expect_error(mdbx_get(another, "k"), "expected an 'mdbx_txn' object")

  # The genuine article is unaffected.
  env3 <- local_env()
  expect_type(mdbx_env_stat(env3), "list")
  expect_true(mdbx_env_is_open(env3))

  # Including a finished transaction, which stays queryable and idempotently
  # abortable: authentication is not an excuse to forget its outcome.
  done <- mdbx_txn_begin(env3)
  mdbx_txn_abort(done)
  expect_identical(mdbx_txn_state(done), "aborted")
  expect_silent(mdbx_txn_abort(done))

  committed <- mdbx_txn_begin(env3, write = TRUE)
  mdbx_txn_commit(committed)
  expect_identical(mdbx_txn_state(committed), "committed")
  expect_silent(mdbx_txn_abort(committed))
})

test_that("a transaction outliving its environment reports what happened", {
  # The owner-closed row of the grid above. Closing is refused while a
  # transaction is live, so the only way here is to finish the transaction
  # first -- and the object then has to keep reporting its own outcome rather
  # than blaming the environment that has since gone.
  env <- local_env()

  aborted <- mdbx_txn_begin(env)
  mdbx_txn_abort(aborted)

  committed <- mdbx_txn_begin(env, write = TRUE)
  mdbx_txn_commit(committed)

  mdbx_env_close(env)

  expect_identical(mdbx_txn_state(aborted), "aborted")
  expect_identical(mdbx_txn_state(committed), "committed")

  # The use-after-finish message is the useful one: it names what the caller
  # did, not the environment's later fate.
  expect_error(mdbx_get(aborted, "k"), "already aborted")
  expect_error(mdbx_get(committed, "k"), "already committed")

  expect_silent(mdbx_txn_abort(aborted))
  expect_error(mdbx_txn_commit(committed), "already committed")

  gc()
  gc()
  expect_identical(mdbx_txn_state(aborted), "aborted")
  expect_identical(mdbx_version()$major, 0L)
})

test_that("a panic in a transaction operation poisons the environment too", {
  env <- local_env()
  txn <- mdbx_txn_begin(env)

  # Every transaction-backed poison callback but the scan's used to mark the
  # transaction alone. The finalizer then skipped the native abort a poisoned
  # handle must not make, unregistered itself, and left the environment
  # believing it had no transactions -- so its close handed libmdbx one that
  # was never ended.
  expect_error(mdbx:::mdbx_test_panic_get_(txn), "libmdbx assertion failed")

  expect_identical(mdbx_txn_state(txn), "poisoned")
  expect_false(mdbx_env_is_open(env))
  expect_error(mdbx_env_stat(env), "unusable after a libmdbx assertion")
})

test_that("a poisoned environment keeps its path claimed, closed or not", {
  # close_handle() deliberately never hands a poisoned environment back to
  # libmdbx, so the lock file stays held for the life of the process. The
  # registry entry went away on close all the same, and the next open sailed
  # past it into libmdbx -- which failed on the lock file with a bare errno
  # (`mdbx error 35` on macOS), or on a platform whose lock blocks instead of
  # failing, hung the session. That is precisely what the registry is for.
  path <- env_path()
  env <- mdbx_env_open(path, map_size = test_map_size)
  expect_error(mdbx:::mdbx_test_panic_stat_(env, FALSE), "libmdbx assertion failed")

  # Poisoned but still held: "use the existing handle" would be impossible
  # advice, since every operation on it refuses.
  message <- conditionMessage(tryCatch(
    mdbx_env_open(path, map_size = test_map_size), error = identity
  ))
  expect_match(message, "libmdbx assertion failure", fixed = TRUE)
  expect_false(grepl("use the existing handle", message, fixed = TRUE))
  expect_false(grepl("mdbx error", message, fixed = TRUE))

  # And after the close that drops the handle entirely, when nothing is left to
  # find in the registry at all.
  mdbx_env_close(env)
  after <- conditionMessage(tryCatch(
    mdbx_env_open(path, map_size = test_map_size), error = identity
  ))
  expect_match(after, "libmdbx assertion failure", fixed = TRUE)
  expect_false(grepl("mdbx error", after, fixed = TRUE))

  # A different environment is unaffected: it is the path that is claimed, not
  # the ability to open environments.
  other <- mdbx_env_open(env_path(), map_size = test_map_size)
  expect_true(mdbx_env_is_open(other))
  mdbx_env_close(other)
})

test_that("a panic raised by the close itself claims the path too", {
  # The close path recorded a poisoned key only for a handle that arrived
  # poisoned. A panic raised *by* mdbx_env_close() skipped that branch entirely:
  # unregister_env() had already given the path up, libmdbx may or may not have
  # released the file, and nothing was left to say so.
  path <- env_path()
  env <- mdbx_env_open(path, map_size = test_map_size)

  # Armed at this environment, not at "the next close": close_call is reached
  # from finalizers too, so a GC between arming and closing would otherwise hand
  # the panic to an environment an earlier test abandoned.
  mdbx:::mdbx_test_arm_close_panic_(env)
  gc()
  expect_error(mdbx_env_close(env), "libmdbx assertion failed")

  # The handle is spent either way.
  expect_false(mdbx_env_is_open(env))

  message <- conditionMessage(tryCatch(
    mdbx_env_open(path, map_size = test_map_size), error = identity
  ))
  expect_match(message, "libmdbx assertion failure", fixed = TRUE)
  expect_false(grepl("mdbx error", message, fixed = TRUE))

  # Other paths are untouched, so the claim is the path's and not the process's.
  other <- mdbx_env_open(env_path(), map_size = test_map_size)
  expect_true(mdbx_env_is_open(other))
  mdbx_env_close(other)
})

test_that("an environment abandoned to the collector does not eat an armed panic", {
  # The regression the arming change prevents: a global flag is consumed by
  # whichever close runs first, and the suite leaves environments for the
  # collector by design. Arm at one, collect others, and the armed one must
  # still be the one that panics.
  path <- env_path()
  env <- mdbx_env_open(path, map_size = test_map_size)

  # Abandoned without closing, exactly as local_env() does throughout the suite.
  invisible(mdbx_env_open(env_path(), map_size = test_map_size))
  invisible(mdbx_env_open(env_path(), map_size = test_map_size))

  mdbx:::mdbx_test_arm_close_panic_(env)
  gc()
  gc()

  expect_error(mdbx_env_close(env), "libmdbx assertion failed")
})

test_that("an armed close panic is dropped when the close never reaches it", {
  # panic_close_target is a raw handle pointer, and close_handle() returns
  # before close_call on three paths -- already closed, inherited across a fork,
  # and poisoned. Left armed, it outlives the handle the finalizer frees, and
  # the next env_handle the allocator puts at that address compares equal to it:
  # an unrelated environment would raise a fabricated panic on close and have
  # its path claimed for the session.
  env <- mdbx_env_open(env_path(), map_size = test_map_size)
  mdbx:::mdbx_test_arm_close_panic_(env)

  # Poison it, so the close takes the branch that returns before close_call.
  expect_error(mdbx:::mdbx_test_panic_stat_(env, FALSE), "libmdbx assertion failed")
  mdbx_env_close(env)
  rm(env)
  gc()
  gc()

  # Nothing is armed any more, so ordinary environments close normally.
  for (i in 1:5) {
    other <- mdbx_env_open(env_path(), map_size = test_map_size)
    expect_silent(mdbx_env_close(other))
    expect_false(mdbx_env_is_open(other))
  }
})

test_that("a panic raised by the open claims the path it may have taken", {
  # Nothing pointed at the half-built environment once the unique_ptr let go of
  # the handle struct, so if libmdbx had taken the lock file before it panicked
  # it held it with no handle and no registry entry naming it. The key is not on
  # the handle at that point either, which is why both spellings are claimed.
  path <- env_path()

  mdbx:::mdbx_test_arm_open_panic_()
  expect_error(mdbx_env_open(path, map_size = test_map_size),
               "libmdbx assertion failed")

  message <- conditionMessage(tryCatch(
    mdbx_env_open(path, map_size = test_map_size), error = identity
  ))
  expect_match(message, "libmdbx assertion failure", fixed = TRUE)
  expect_false(grepl("mdbx error", message, fixed = TRUE))

  other <- mdbx_env_open(env_path(), map_size = test_map_size)
  expect_true(mdbx_env_is_open(other))
  mdbx_env_close(other)
})

test_that("a panic with a live transaction can still be cleaned up", {
  env <- local_env()
  txn <- mdbx_txn_begin(env)

  expect_error(mdbx:::mdbx_test_panic_stat_(env, FALSE), "libmdbx assertion failed")

  # Both handles report the panic rather than a lifecycle state that is no
  # longer true of either.
  expect_identical(mdbx_txn_state(txn), "poisoned")
  expect_false(mdbx_env_is_open(env))

  # Neither of these may re-enter libmdbx, and neither may refuse. Refusing is
  # what made a panic unrecoverable: abort was rejected because the environment
  # was poisoned, and close was rejected because the transaction was still
  # registered, so only dropping both references and forcing a GC released it.
  expect_silent(mdbx_txn_abort(txn))
  expect_silent(mdbx_env_close(env))
  expect_false(mdbx_env_is_open(env))

  # Once cleaned up it reads as ended rather than as poisoned: the transaction
  # is over, and "aborted" is what the caller needs to know about its writes.
  expect_identical(mdbx_txn_state(txn), "aborted")

  # Idempotent, and stable across the finalizers that run later.
  expect_silent(mdbx_txn_abort(txn))
  expect_silent(mdbx_env_close(env))
  gc()
  gc()
  expect_identical(mdbx_txn_state(txn), "aborted")
  expect_identical(mdbx_version()$major, 0L)
})

test_that("both poison paths leave the same state after cleanup", {
  # Found by the fault plans in test-state-machine-faults.R. An environment
  # panic leaves the transaction's own flag clear and poisons only the owner,
  # which cleanup then detaches; a transaction-level panic sets the flag on the
  # transaction itself, where nothing clears it. Reading the flag before the
  # lifecycle state made the first case report "aborted" and the second
  # "poisoned" after the identical cleanup.
  for (panic in list(
    function(env, txn) mdbx:::mdbx_test_panic_stat_(env, FALSE),
    function(env, txn) mdbx:::mdbx_test_panic_get_(txn)
  )) {
    env <- local_env()
    txn <- mdbx_txn_begin(env, write = TRUE)

    expect_error(panic(env, txn), "libmdbx assertion failed")
    expect_identical(mdbx_txn_state(txn), "poisoned")

    expect_silent(mdbx_txn_abort(txn))
    expect_identical(mdbx_txn_state(txn), "aborted")
    expect_silent(mdbx_env_close(env))
  }

  expect_identical(mdbx_version()$major, 0L)
})

test_that("closing a poisoned environment detaches its transactions", {
  env <- local_env()
  txn <- mdbx_txn_begin(env)

  expect_error(mdbx:::mdbx_test_panic_stat_(env, FALSE), "libmdbx assertion failed")

  # Closing goes first this time, so the detaching is the close's own work
  # rather than something the abort already did.
  expect_silent(mdbx_env_close(env))

  # detach_txns() ended it, so it reads as aborted rather than still live.
  expect_identical(mdbx_txn_state(txn), "aborted")
  expect_silent(mdbx_txn_abort(txn))
  expect_identical(mdbx_version()$major, 0L)
})

test_that("cleanup after a panic does not replace the panic", {
  env <- local_env()

  # mdbx_with_*() end their transaction from on.exit(). While abort refused a
  # poisoned graph, that refusal was raised on the way out and became the
  # condition the caller saw -- destroying the only message that said what
  # libmdbx had actually found.
  message <- conditionMessage(tryCatch(
    mdbx_with_read(env, function(txn) mdbx:::mdbx_test_panic_stat_(env, FALSE)),
    error = identity
  ))

  expect_match(message, "libmdbx assertion failed", fixed = TRUE)
  expect_false(grepl("unusable after a libmdbx assertion", message, fixed = TRUE))

  expect_silent(mdbx_env_close(env))
  expect_identical(mdbx_version()$major, 0L)
})

test_that("a panic leaves no transaction registered against the environment", {
  gc()
  before <- mdbx:::mdbx_txn_live_count_()

  local({
    env <- local_env()
    txn <- mdbx_txn_begin(env, write = TRUE)
    expect_error(mdbx:::mdbx_test_panic_get_(txn), "libmdbx assertion failed")
    mdbx_txn_abort(txn)
    mdbx_env_close(env)
  })

  gc()
  gc()
  expect_identical(mdbx:::mdbx_txn_live_count_(), before)
})
