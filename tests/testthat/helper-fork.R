# Whether this R session can actually fork().
#
# Windows has no fork(), and some IDE front-ends refuse it even on Unix --
# Positron raises "Can't fork the R session", because forking a session that
# owns a UI connection is unsafe. Fork behaviour is a real part of this
# package's contract, so those tests skip rather than fail when the session
# cannot host them; they still run under Rscript, R CMD check, and CI.
#
# The probe is a fork, because no front-end-independent predicate exists. It
# runs at most once per session.
can_fork <- local({
  cached <- NULL

  function() {
    if (!is.null(cached)) {
      return(cached)
    }

    cached <<- .Platform$OS.type != "windows" &&
      isTRUE(tryCatch(
        {
          job <- parallel::mcparallel(TRUE)
          identical(unname(parallel::mccollect(job)), list(TRUE))
        },
        error = function(e) FALSE
      ))

    cached
  }
})

skip_if_cannot_fork <- function() {
  skip_if_not(can_fork(), "this R session cannot fork()")
}

# Run `f` in a forked child and bring back its value, or its error message.
in_fork <- function(f) {
  job <- parallel::mcparallel(
    tryCatch(f(), error = function(e) paste("ERROR:", conditionMessage(e)))
  )
  parallel::mccollect(job)[[1]]
}

local_seeded_env <- function() {
  env <- mdbx_env_open(tempfile(fileext = ".mdbx"), map_size = test_map_size)
  mdbx_with_write(env, function(txn) mdbx_put(txn, "k", "v"))
  env
}
