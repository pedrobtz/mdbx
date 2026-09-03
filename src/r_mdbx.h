#ifndef R_MDBX_H
#define R_MDBX_H

#include <string>
#include <utility>
#include <vector>

#include <cpp11.hpp>

// mdbx.h carries its own extern "C" guards and defines C++ operator overloads
// for its flag enums, so it is included directly from C++.
#include "mdbx.h"
#include "r_mdbx_hooks.h"

namespace mdbx_r {

// The process this code is running in.
//
// Every handle records the process that created it, because a fork() gives the
// child a copy of the pointer and none of what it addresses. libmdbx's own
// after-fork hook "drowns" the inherited environment, and MDBX_ENV_CHECKPID
// detects the mismatch -- but only once a call has already dereferenced the
// dead mapping, which on every operation tested crashes the child rather than
// returning an error. The check therefore has to happen above libmdbx.
long current_pid();

// R's Rboolean, spelled without the TRUE/FALSE tokens.
//
// mdbx.h includes <windows.h>, whose windef.h defines TRUE and FALSE as plain
// ints -- shadowing R's Rboolean enumerators in every translation unit that
// includes this header. C++ will not convert int to Rboolean implicitly, so
// `R_RegisterCFinalizerEx(p, f, TRUE)` compiles everywhere except Windows.
// Qualifying it as Rboolean::TRUE does not help: the macro expands there too.
// Use these constants for any R API argument of type Rboolean.
constexpr Rboolean r_true = static_cast<Rboolean>(1);
constexpr Rboolean r_false = static_cast<Rboolean>(0);

struct txn_handle;

// The object an mdbx_env external pointer addresses.
//
// `env` is the authoritative MDBX handle and becomes null exactly once, when
// the environment is closed (explicitly or by the finalizer). `poisoned` is set
// by the guard's poison callback when libmdbx panics inside an operation on
// this environment: libmdbx has then detected a violated invariant, so the
// handle must reject every later operation and its finalizer must not re-enter
// libmdbx to close it.
//
// `live_txns` holds every transaction handle that has not yet finished.
// mdbx_env_close_ex() documents that all transactions must be closed first and
// that using one afterwards is UB that "would cause a SIGSEGV", so the registry
// exists to make that unreachable from R: an explicit close refuses while it is
// non-empty, and the finalizer detaches the entries it finds. It is not a
// convenience -- without it, the order R happens to run two finalizers in would
// decide whether the session crashes.
struct env_handle {
  MDBX_env *env;
  bool poisoned;

  // The process that opened this environment. A handle reached from any other
  // process was inherited across a fork() and must not be used or closed:
  // libmdbx state, the reader slot and the lock file all belong to the parent.
  long pid;

  std::vector<txn_handle *> live_txns;
};

// A transaction ends exactly once, and which way it ended is worth reporting.
enum class txn_state { active, committed, aborted };

// The object an mdbx_txn external pointer addresses.
//
// The external pointer additionally retains its environment in the protected
// field, so the env SEXP cannot be collected while the transaction is
// reachable. `owner` is the same relationship at the C level; it is null only
// once the environment's finalizer has detached this transaction, which is why
// every use checks it.
struct txn_handle {
  MDBX_txn *txn;
  env_handle *owner;
  txn_state state;
  bool write;
  bool poisoned;

  // As for env_handle, and recorded separately so the check does not depend on
  // `owner`, which detach_txns() clears.
  long pid;

  // The database the operation in progress addresses. Set by ensure_dbi()
  // immediately before each guarded call, so the guarded code needs to know
  // nothing about names.
  MDBX_dbi dbi;

  // The unnamed (main) database, opened lazily on the first operation that
  // needs it. libmdbx exposes no constant for it, so it has to come from
  // mdbx_dbi_open().
  MDBX_dbi main_dbi;
  bool main_ready;

  // Named databases resolved in this transaction, and only this one.
  //
  // An MDBX_dbi is environment-scoped once its creating transaction commits,
  // but a handle from a transaction that *aborts* is poisoned -- reusing it
  // gives MDBX_BAD_DBI, and the database does not exist. Caching per
  // transaction means the cache cannot outlive its own validity: it dies with
  // the transaction, and the next one re-resolves by name. mdbx_dbi_open() is
  // idempotent within a transaction, so that costs a lookup, not a create.
  //
  // Handles are never closed. mdbx_dbi_close() is only safe when nothing may
  // still reference the handle, and letting the environment release them makes
  // that entire class of bug unreachable. The price is a DBI slot held until
  // the environment closes, bounded by max_dbs.
  std::vector<std::pair<std::string, MDBX_dbi>> named;
};

// Translate a non-success MDBX status into an R condition, preserving the
// original code. Statuses that are not errors -- MDBX_NOTFOUND above all --
// must be handled by the caller before reaching here.
void check(int rc);

// Run a C-compatible libmdbx call below the panic boundary in r_mdbx_hooks.cpp.
// Returns normally only if libmdbx did not panic; a panic runs `poison` and
// then becomes an R condition. `call` and `poison` must be free of C++ objects
// with destructors, because a panic reaches them through longjmp().
void guard(mdbx_r_guarded_function call, void *data,
           mdbx_r_poison_function poison);

// Fetch the handle behind an mdbx_env external pointer, erroring if the object
// is not one, has been closed, or has been poisoned by a panic. Every entry
// point that touches an environment goes through this.
env_handle *env_from_sexp(SEXP x);

// Fetch the handle behind an mdbx_txn external pointer, erroring if the object
// is not one, if the transaction has already committed or aborted, if it was
// poisoned by a panic, or if its environment is gone.
txn_handle *txn_from_sexp(SEXP x);

// Translate flag names -- the C names with the MDBX_ prefix dropped -- into the
// bitmask libmdbx takes. Defined in r_flags.cpp, which owns the vocabulary.
// Names are validated in R first; an unknown one here is a bug, not user error.
unsigned env_flags_from_names(cpp11::strings names);
unsigned txn_flags_from_names(cpp11::strings names);

} // namespace mdbx_r

#endif
