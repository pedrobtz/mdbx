# Generated sequences that also produce malformed objects and forged handles.
#
# The core profile asks whether valid operations agree with the model. This one
# asks the other half: that an invalid one is refused, changes nothing, and
# leaves the transaction usable. That third clause is the one that matters --
# a damaged mdbx_dbi used to return a plausible value from the main database,
# which is a refusal that did not refuse.
#
# Reclassing a handle the sequence still holds is not generated here.
# `class<-` on an external pointer modifies it in place, so it would destroy
# the fixture rather than test it; test-native-safety.R covers that with
# handles built to be spent.

test_that("malformed objects and forged handles are refused, and change nothing", {
  skip_on_cran()

  for (seed in state_machine_seeds()) {
    expect_silent(run_mdbx_sequence(seed, steps = state_machine_steps(50L),
                                    profile = "adversarial"))
  }
})
