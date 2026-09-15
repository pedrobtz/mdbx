# Formal verification proposal

## Recommendation

Formal methods can materially improve confidence in `mdbx`, but the useful
verification target is the package's abstract lifecycle and transaction
protocol. Attempting to verify R, cpp11, the C++ boundary, the vendored
libmdbx implementation, and the operating system together would be a much
larger project with a poor cost-to-benefit ratio for this package.

Lean is a good fit for specifying the protocol as a small executable state
machine and proving that every permitted transition preserves its invariants.
The real R package can then be tested for conformance by executing the same
operation traces against the package and the Lean model.

This should complement, rather than replace, randomized state-machine tests,
subprocess tests, fault injection, sanitizers, and the existing testthat suite.

## Verification boundary

The Lean model should describe only externally relevant state and behaviour.
It should not reproduce libmdbx internals.

An initial model would contain:

- environment states such as open, poisoned, closed, and foreign-process;
- transaction states such as absent, read, write, failed, committed, and
  aborted;
- the committed database contents;
- a transaction-local working view;
- the registry of live transactions;
- database names and the validity of database-handle records; and
- observable results such as success, missing key, value, or structured error.

Commands would include:

- open and close an environment;
- begin a read or write transaction;
- get, put, and delete;
- list, create, and drop databases;
- commit and abort;
- inject a panic or failed transaction state; and
- attempt operations with closed, stale, malformed, or inherited handles.

A simplified Lean representation might look like this:

```lean
inductive EnvStatus
  | open
  | poisoned
  | closed
  | foreignProcess

inductive TxnStatus
  | absent
  | read
  | write
  | failed
  | committed
  | aborted

inductive Command
  | beginRead
  | beginWrite
  | get (db key : ByteArray)
  | put (db key value : ByteArray)
  | delete (db key : ByteArray)
  | commit
  | abort
  | close

def step : State -> Command -> Result (State × Observation) Error :=
  -- Executable specification of one API transition.
  sorry
```

The actual definitions should favor a small, auditable model over mirroring
the implementation line by line.

## Properties to prove

The first proof milestone should establish the following safety properties:

1. An environment has at most one live transaction.
2. A closed, poisoned, or foreign-process handle never permits a native
   operation.
3. Closing an environment with a live normal transaction is rejected.
4. Poisoned cleanup can detach package bookkeeping without re-entering the
   unsafe native environment.
5. Every successful commit or abort unregisters its transaction.
6. Aborting a transaction cannot change committed database contents.
7. Committing publishes exactly the transaction's working view.
8. Read transactions cannot change data or database structure.
9. Transaction and environment state queries agree with the model state.
10. Only the documented representation selects the main database, and a
    malformed database-handle record is rejected.
11. An inherited handle cannot change either package or database state.
12. An invalid command returns an error without corrupting otherwise valid
    state.

The central preservation theorem would have approximately this form:

```lean
theorem step_preserves_validity
    (validBefore : Valid state)
    (transition : step state command = .ok (next, observation)) :
    Valid next := by
  -- Proof by command and state cases.
  sorry
```

Separate refinement-style theorems should cover transactional data semantics,
for example that abort preserves the committed store and commit replaces it
with the working store.

## Connection to randomized testing

Proofs about the model do not establish that the R/C++ implementation follows
the model. Conformance testing supplies that missing bridge.

The proposed workflow is:

```text
generated operation trace
          |
          +-- execute against the installed R package
          |
          +-- execute against the Lean reference model
                         |
                 compare observations
```

Each trace should contain explicit operation arguments and enough metadata to
replay it. Both runners should produce a normalized observation after every
operation, including:

- whether the operation succeeded;
- the returned value, if any;
- a stable structured error class and native error code where applicable;
- observable environment and transaction status; and
- a digest or normalized representation of visible database contents.

A mismatch is a conformance failure even when neither side crashes. Every
failure should record the random seed and complete trace. The existing
state-machine shrinker can minimize the trace without involving Lean. The
smallest counterexample should then become a deterministic testthat regression
test.

The comparison boundary must avoid unstable text such as temporary paths,
addresses, localized messages, or platform-specific formatting.

## Repository and CI layout

The formalization should remain maintainer infrastructure and should not
become a CRAN runtime or build dependency. A possible layout is:

```text
formal/
  lakefile.toml
  lean-toolchain
  Mdbx/
    Model.lean
    Invariants.lean
    Transaction.lean
    Trace.lean
    Main.lean
```

`formal/` should be included in `.Rbuildignore`. CI can install the pinned Lean
toolchain, check every proof, build the trace oracle, and run a bounded set of
cross-implementation traces. Ordinary package CI and CRAN checks should remain
independent of Lean.

Suggested CI levels are:

- pull requests: proof checking plus a small deterministic trace corpus;
- the default branch: several fixed randomized seeds;
- scheduled builds: longer randomized campaigns and sanitizer builds; and
- releases: proof checking, the retained counterexample corpus, and an
  extended cross-platform campaign.

Pinning `lean-toolchain` and the Lake dependencies is essential so proof and
oracle behaviour do not change unexpectedly.

## What Lean would and would not prove

Lean could prove that the specified transition system satisfies its stated
invariants for all modeled command sequences. It could also provide an
executable reference implementation for generated traces.

That would not, by itself, prove:

- that the current R and C++ code implements the transition function;
- memory safety of external-pointer and finalizer code;
- correct behaviour of R garbage collection or cpp11 protection;
- safe recovery across libmdbx panic callbacks and non-local exits;
- correctness of fork, process, filesystem, or thread behaviour;
- correctness of the vendored libmdbx implementation; or
- correctness of the model as a statement of the intended public API.

Those areas still require native tests, subprocess isolation, fault injection,
sanitizers, code review, and comparison with the documented API contract. A
formal model can also be wrong, so its definitions and assumptions must be
reviewed independently of the implementation.

## Incremental adoption plan

### Phase 1: stabilize the executable specification

Implement the proposed state-machine test model in ordinary test code first.
Use it to settle command preconditions, observations, and invariants while the
feedback loop is inexpensive.

### Phase 2: formalize the core lifecycle

Translate the environment and transaction state machine into Lean. Prove
single-live-transaction, safe-close, terminal-transaction, and invalid-handle
properties. Do not model database contents yet.

### Phase 3: prove transactional data semantics

Add committed and working stores. Prove abort isolation, commit publication,
read-only behaviour, missing-key semantics, and database-name resolution.

### Phase 4: add the conformance oracle

Define a stable trace format, build a small Lean executable that consumes it,
and compare its observations with an installed-package runner in CI.

### Phase 5: retain and expand counterexamples

Make randomized campaigns replayable and shrinkable. Promote every distinct
failure to a deterministic regression test and, when appropriate, a new Lean
theorem or model precondition.

## Decision

Adopt Lean only after the executable state-machine test vocabulary is stable.
The recommended end state is a hybrid:

- Lean proves the abstract lifecycle and transactional invariants;
- randomized differential testing checks implementation conformance;
- deterministic testthat tests retain discovered regressions; and
- subprocess and native tooling exercise behaviour outside the model.

This gives substantially stronger assurance than more example-based tests
alone without turning package development into an attempt to verify the entire
native software stack.

## References

- [The Lean Language Reference](https://lean-lang.org/doc/reference/latest/)
- [Theorem Proving in Lean 4](https://lean-lang.org/theorem_proving_in_lean4/introduction.html)
- [Functional Programming in Lean](https://lean-lang.org/functional_programming_in_lean/)
- [Lean elaboration and compilation](https://lean-lang.org/doc/reference/latest/Elaboration-and-Compilation/)
- [Verifying imperative programs using `mvcgen`](https://lean-lang.org/doc/tutorials/latest/)
