# Ordered keys, and reading back what a scan returned.
#
# Keys are big-endian integers because byte order is the only order libmdbx
# has -- a key encoded any other way sorts wrongly, and every ordered scan
# asserting on it would be meaningless.

be32 <- function(x) {
  x <- as.integer(x)
  as.raw(c(x %/% 2^24 %% 256, x %/% 2^16 %% 256, x %/% 2^8 %% 256, x %% 256))
}

indexed_env <- function(times = c(500, 100, 900, 300, 700)) {
  env <- local_env()
  mdbx_with_write(env, function(txn) {
    for (t in times) mdbx_put(txn, be32(t), sprintf("at-%d", t))
  })
  env
}

values_of <- function(x) unname(unlist(x$values))
