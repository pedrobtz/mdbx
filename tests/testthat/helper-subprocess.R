# Genuinely separate R processes.
#
# Concurrency in libmdbx is between processes, not threads: one environment
# supports a single transaction per thread, so nothing in a single R session can
# exercise "many readers, one writer". These helpers run code in a fresh R
# process against the same database file.
#
# fork() is no use here -- an inherited environment is refused by design (see
# test-fork.R) -- so this spawns Rscript and loads the installed package.

# The library mdbx is installed into, or NA when it is not installed at all.
#
# devtools::load_all() puts the source directory on the search path without
# installing it, and a subprocess cannot library() that. An installed package
# has Meta/package.rds; a source directory does not, which is the discriminator.
mdbx_installed_lib <- local({
  cached <- NULL

  function() {
    if (!is.null(cached)) {
      return(cached)
    }

    path <- tryCatch(find.package("mdbx"), error = function(e) NA_character_)
    cached <<- if (!is.na(path) &&
                   file.exists(file.path(path, "Meta", "package.rds"))) {
      dirname(path)
    } else {
      NA_character_
    }

    cached
  }
})

skip_if_no_subprocess <- function() {
  skip_if(is.na(mdbx_installed_lib()),
          "mdbx is not installed in a library; these run under R CMD check")
}

# Run `code` in a fresh R process with mdbx loaded, and return everything it
# printed. Blocking, so the caller's own transactions are still open while it
# runs -- which is what makes the concurrency assertions concurrent.
r_run <- function(code) {
  script <- tempfile(fileext = ".R")

  writeLines(
    c(
      sprintf(".libPaths(%s)",
              paste(deparse(c(mdbx_installed_lib(), .libPaths())), collapse = "")),
      "suppressMessages(library(mdbx))",
      code
    ),
    script
  )

  output <- suppressWarnings(system2(
    file.path(R.home("bin"), "Rscript"),
    c("--vanilla", shQuote(script)),
    stdout = TRUE,
    stderr = TRUE
  ))

  paste(output, collapse = "\n")
}

# A literal for interpolation into subprocess code.
as_code <- function(x) paste(deparse(x), collapse = "")
