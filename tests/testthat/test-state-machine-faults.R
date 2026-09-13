# Lifecycle failures: a libmdbx assertion, and a transaction libmdbx has marked
# erroneous.
#
# These are short and deliberately terminal. A panic poisons the environment,
# so it ends the sequence rather than mixing into a long one; what varies is
# how the panic is reached and the order the cleanup happens in, because that
# is precisely where the defect was. Abort refused a poisoned graph and close
# refused while the transaction was still registered, so the two refused each
# other and only a GC broke the deadlock -- and the refusal, raised from
# mdbx_with_*()'s on.exit(), replaced the panic that caused it.
#
# Map exhaustion is the other half and needs no injection: it is reachable
# from the public API, and it is what made mdbx_txn_state() report "active"
# for a transaction that could do nothing but end.

test_that("a panic is survivable in every approach and cleanup order", {
  skip_on_cran()

  for (plan in fault_plans()) {
    for (gc_first in c(FALSE, TRUE)) {
      # run_mdbx_fault() names the plan and the invariant it broke.
      expect_silent(run_mdbx_fault(plan, gc_first = gc_first))
    }
  }
})

test_that("an exhausted map ends the transaction and writes nothing", {
  skip_on_cran()

  for (seed in c(1L, 20260913L)) {
    expect_silent(run_mdbx_exhaustion(seed))
  }
})
