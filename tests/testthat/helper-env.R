# Throwaway paths and environments for the test suite.

# Why the suite pins map_size: libmdbx's default reserves about 13 GB of
# address space per environment. That is free in ordinary use -- it is virtual,
# and almost none of it is ever resident -- but valgrind shadows every mapping,
# so a suite that opens dozens of environments exhausts what valgrind can track
# and mdbx_env_open() starts failing with EINVAL. That is what broke the
# valgrind CI leg, with 31 errors all from mdbx_env_open(). These tests store
# kilobytes, so they ask for megabytes.
#
# The default geometry is still exercised, once, in test-env.R.
test_map_size <- 8 * 1024^2

# An unused path for an environment. These land under tempdir(), which R
# removes when the session ends, so the tests do not unlink them individually.
env_path <- function() {
  tempfile(fileext = ".mdbx")
}

# A fresh environment on a throwaway path. Not closed explicitly: closing is
# refused while a transaction is open, and ordering an auto-close against each
# test's own cleanup is more trouble than letting the finalizer do it.
local_env <- function(..., map_size = test_map_size) {
  mdbx_env_open(env_path(), ..., map_size = map_size)
}
