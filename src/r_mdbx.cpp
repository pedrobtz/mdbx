#include <algorithm>
#include <cstdint>
#include <thread>
#include <cstring>
#include <vector>
#include <memory>
#include <string>

#include "r_mdbx.h"

#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

namespace mdbx_r {

long current_pid() {
#ifdef _WIN32
  return static_cast<long>(_getpid());
#else
  return static_cast<long>(getpid());
#endif
}

// A private tag stamped on every handle, and checked before the pointer behind
// it is dereferenced.
//
// The S3 class alone is not an identity: R code can set a class on any external
// pointer, and doing so was enough to make an entry point read arbitrary memory
// as an env_handle. R has no way to set an external pointer's tag, so this is
// unforgeable from R -- and it also tells the two handle types apart, which are
// both EXTPTRSXP and would otherwise be interchangeable.
//
// Rf_install() interns, so each call returns the same symbol and identity
// comparison is what checks it.
SEXP env_tag() { return Rf_install("mdbx_env_handle"); }
SEXP txn_tag() { return Rf_install("mdbx_txn_handle"); }

// Is this object one of ours? env_from_sexp() asks the same question and then
// insists the environment is still usable; mdbx_env_close_() and
// mdbx_env_is_open_() have to tolerate a closed one, so they check shape alone.
bool is_env_sexp(SEXP x) {
  return TYPEOF(x) == EXTPTRSXP && Rf_inherits(x, "mdbx_env") &&
         R_ExternalPtrTag(x) == env_tag();
}

// Bounds for every value that reaches a narrowing cast. R validates these too,
// but the entry points are reachable through ::: and an out-of-range
// double-to-integer conversion is undefined behaviour, so the guard belongs
// next to the cast as well.
//
// 2^53 is the largest integer a double holds exactly. Comparing against a
// destination maximum instead would be wrong: (double)PTRDIFF_MAX rounds up to
// 2^63, so `x > (double)PTRDIFF_MAX` admits exactly 2^63 into a cast that tops
// out at 2^63 - 1.
constexpr double max_exact_integer = 9007199254740992.0; // 2^53

// intptr_t and size_t stop at 2^31 - 1 on a 32-bit build, far below 2^53, so
// pointer-sized destinations need a narrower bound than the 64-bit ones.
constexpr double max_native_integer =
    sizeof(void *) >= 8 ? max_exact_integer : 2147483647.0; // 2^31 - 1

namespace {

// Number of env_handle objects alive. Maintained only so the test suite can
// assert that finalization actually reclaims handles; R's GC is single
// threaded, so a plain counter is enough.
int live_env_handles = 0;
int live_txn_handles = 0;

[[noreturn]] void stop_after_panic(const mdbx_r_panic_info &panic) {
  cpp11::stop("libmdbx assertion failed: %s (%s:%u)", panic.message,
              panic.function, panic.line);
}

} // namespace

void check(int rc) {
  if (rc != MDBX_SUCCESS)
    cpp11::stop("%s (mdbx error %d)", mdbx_strerror(rc), rc);
}

void guard(mdbx_r_guarded_function call, void *data,
           mdbx_r_poison_function poison) {
  mdbx_r_panic_info panic = {};

  if (mdbx_r_run_guarded(call, data, poison, &panic) != MDBX_R_GUARD_OK)
    stop_after_panic(panic);
}

namespace {

// ---------------------------------------------------------------------------
// Guarded libmdbx calls
//
// Each of these runs below the panic boundary, so it must stay C-shaped: plain
// structs, no destructors, no R API. The surrounding C++ does the allocation
// and error translation.
// ---------------------------------------------------------------------------

struct open_context {
  env_handle *handle;
  const char *path;
  MDBX_env_flags_t flags;
  unsigned actual_flags;
  uint64_t max_dbs;
  uint64_t max_readers;
  intptr_t map_size;
  mdbx_mode_t mode;
  int rc;
};

void open_call(void *data) {
  open_context *context = static_cast<open_context *>(data);

  context->rc = mdbx_env_create(&context->handle->env);
  if (context->rc != MDBX_SUCCESS)
    return;

  if (context->max_dbs > 0) {
    context->rc = mdbx_env_set_option(context->handle->env, MDBX_opt_max_db,
                                      context->max_dbs);
    if (context->rc != MDBX_SUCCESS)
      return;
  }

  // Sizes the reader lock table, so it has to happen before the open. Left
  // alone, libmdbx derives the ceiling from the lock file's page size.
  if (context->max_readers > 0) {
    context->rc = mdbx_env_set_option(context->handle->env,
                                      MDBX_opt_max_readers,
                                      context->max_readers);
    if (context->rc != MDBX_SUCCESS)
      return;
  }

  // Only the upper bound is set; lower bound, current size, growth step,
  // shrink threshold and page size stay at MDBX's defaults (-1 = unchanged).
  if (context->map_size > 0) {
    context->rc = mdbx_env_set_geometry(context->handle->env, -1, -1,
                                        context->map_size, -1, -1, -1);
    if (context->rc != MDBX_SUCCESS)
      return;
  }

  context->rc = mdbx_env_open(context->handle->env, context->path,
                              context->flags, context->mode);
  if (context->rc != MDBX_SUCCESS)
    return;

  // libmdbx detects the on-disk layout of an existing environment, so what it
  // ended up with is not necessarily what was asked for.
  context->rc = mdbx_env_get_flags(context->handle->env, &context->actual_flags);
}

struct close_context {
  env_handle *handle;
  int rc;
};

void close_call(void *data) {
  close_context *context = static_cast<close_context *>(data);
  context->rc = mdbx_env_close(context->handle->env);
}

struct reader_check_context {
  env_handle *handle;
  int dead;
  int rc;
};

void reader_check_call(void *data) {
  reader_check_context *context = static_cast<reader_check_context *>(data);
  context->rc = mdbx_reader_check(context->handle->env, &context->dead);
}

void poison_reader_check(void *data) {
  static_cast<reader_check_context *>(data)->handle->poisoned = true;
}

struct path_context {
  env_handle *handle;
  const char *path;
  int rc;
};

void path_call(void *data) {
  path_context *context = static_cast<path_context *>(data);
  context->rc = mdbx_env_get_path(context->handle->env, &context->path);
}

// Poison callbacks. A panic means libmdbx tripped an internal invariant, so the
// handle is marked unusable before the panic is translated into an R condition
// -- the ordering the Stage 1 boundary test pins down. One per context type,
// rather than one that reinterprets a shared first member, so that adding a
// context cannot silently corrupt the wrong field.
void poison_open(void *data) {
  static_cast<open_context *>(data)->handle->poisoned = true;
}

void poison_close(void *data) {
  static_cast<close_context *>(data)->handle->poisoned = true;
}

void poison_path(void *data) {
  static_cast<path_context *>(data)->handle->poisoned = true;
}

struct begin_context {
  env_handle *owner;
  MDBX_txn *txn;
  MDBX_txn_flags_t flags;
  int rc;
};

void begin_call(void *data) {
  begin_context *context = static_cast<begin_context *>(data);
  context->rc = mdbx_txn_begin(context->owner->env, nullptr, context->flags,
                               &context->txn);
}

struct finish_context {
  txn_handle *handle;
  bool commit;
  int rc;
};

void finish_call(void *data) {
  finish_context *context = static_cast<finish_context *>(data);
  context->rc = context->commit ? mdbx_txn_commit(context->handle->txn)
                                : mdbx_txn_abort(context->handle->txn);
}

// A panic inside a transaction poisons the environment too: libmdbx has
// detected a violated invariant, and MDBX_PANIC is documented to mean the
// environment must be shut down. Neither handle is touched again.
void poison_begin(void *data) {
  static_cast<begin_context *>(data)->owner->poisoned = true;
}

void poison_finish(void *data) {
  txn_handle *handle = static_cast<finish_context *>(data)->handle;
  handle->poisoned = true;
  if (handle->owner != nullptr)
    handle->owner->poisoned = true;
}

struct dbi_context {
  txn_handle *handle;
  const char *name; // null selects the unnamed main database
  unsigned flags;
  MDBX_dbi dbi;
  int rc;
};

void dbi_call(void *data) {
  dbi_context *context = static_cast<dbi_context *>(data);
  context->rc = mdbx_dbi_open(context->handle->txn, context->name,
                              static_cast<MDBX_db_flags_t>(context->flags),
                              &context->dbi);
}

struct get_context {
  txn_handle *handle;
  MDBX_val key;
  MDBX_val data;
  int rc;
};

void get_call(void *data) {
  get_context *context = static_cast<get_context *>(data);
  context->rc = mdbx_get(context->handle->txn, context->handle->dbi,
                         &context->key, &context->data);
}

struct put_context {
  txn_handle *handle;
  MDBX_val key;
  MDBX_val data;
  MDBX_put_flags_t flags;
  int rc;
};

void put_call(void *data) {
  put_context *context = static_cast<put_context *>(data);
  context->rc = mdbx_put(context->handle->txn, context->handle->dbi,
                         &context->key, &context->data, context->flags);
}

struct del_context {
  txn_handle *handle;
  MDBX_val key;
  int rc;
};

void del_call(void *data) {
  del_context *context = static_cast<del_context *>(data);
  // Null data deletes every value for the key, which for a database without
  // MDBX_DUPSORT is the single value it may have.
  context->rc = mdbx_del(context->handle->txn, context->handle->dbi,
                         &context->key, nullptr);
}

void poison_dbi(void *data) {
  static_cast<dbi_context *>(data)->handle->poisoned = true;
}

void poison_get(void *data) {
  static_cast<get_context *>(data)->handle->poisoned = true;
}

void poison_put(void *data) {
  static_cast<put_context *>(data)->handle->poisoned = true;
}

void poison_del(void *data) {
  static_cast<del_context *>(data)->handle->poisoned = true;
}

// A whole-database scan, done in one crossing of the R/C boundary. Looping in C
// rather than as an R loop around .Call() is the performance lesson the design
// records from the reference bindings.
//
// The cursor is opened, walked and closed entirely inside the guarded call, so
// R never sees one -- which keeps the shape of a future cursor API a genuinely
// open question rather than something this quietly decides.
//
// Bytes are collected into std::string (constructed from pointer and length, so
// embedded NULs survive) because the guarded function must not touch the R API:
// an R allocation can longjmp, and unwinding past this frame would leave the
// panic guard corrupted. The R vectors are built afterwards, outside the guard.
struct scan_context {
  txn_handle *handle;
  MDBX_cursor *cursor;
  size_t limit;
  bool want_values;
  bool reverse;
  const char *start; // null starts from whichever end `reverse` selects
  size_t start_len;
  std::vector<std::string> *keys;
  std::vector<std::string> *values;
  bool out_of_memory;
  int rc;
};

void scan_call(void *data) {
  scan_context *context = static_cast<scan_context *>(data);

  context->rc = mdbx_cursor_open(context->handle->txn, context->handle->dbi,
                                 &context->cursor);
  if (context->rc != MDBX_SUCCESS)
    return;

  // Nothing may escape this frame as a C++ exception: mdbx_r_run_guarded()
  // restores the guard chain after the call returns, and unwinding past it
  // would skip that. A bad_alloc becomes a flag the caller turns into an error.
  try {
    MDBX_val key = {nullptr, 0};
    MDBX_val value = {nullptr, 0};
    const MDBX_val from = {const_cast<char *>(context->start), context->start_len};

    // Where to begin. MDBX_SET_RANGE lands on the first key >= `start`, which
    // is what a forward walk wants; a backward one wants the last key <=
    // `start`, so it steps back once if it overshot, or starts from the end if
    // `start` is past every key.
    MDBX_cursor_op op;
    if (context->start != nullptr) {
      key = from;
      op = MDBX_SET_RANGE;
    } else {
      op = context->reverse ? MDBX_LAST : MDBX_FIRST;
    }

    bool positioning = true;

    while (context->keys->size() < context->limit) {
      int rc = mdbx_cursor_get(context->cursor, &key, &value, op);

      if (positioning && context->reverse && context->start != nullptr) {
        if (rc == MDBX_NOTFOUND) {
          rc = mdbx_cursor_get(context->cursor, &key, &value, MDBX_LAST);
        } else if (rc == MDBX_SUCCESS &&
                   mdbx_cmp(context->handle->txn, context->handle->dbi, &key,
                            &from) > 0) {
          rc = mdbx_cursor_get(context->cursor, &key, &value, MDBX_PREV);
        }
      }
      positioning = false;

      if (rc == MDBX_NOTFOUND)
        break;
      if (rc != MDBX_SUCCESS) {
        context->rc = rc;
        break;
      }

      context->keys->emplace_back(static_cast<const char *>(key.iov_base),
                                  key.iov_len);
      if (context->want_values)
        context->values->emplace_back(static_cast<const char *>(value.iov_base),
                                      value.iov_len);

      op = context->reverse ? MDBX_PREV : MDBX_NEXT;
    }
  } catch (...) {
    context->out_of_memory = true;
  }

  mdbx_cursor_close(context->cursor);
  context->cursor = nullptr;
}

void poison_scan(void *data) {
  scan_context *context = static_cast<scan_context *>(data);
  context->handle->poisoned = true;
  if (context->handle->owner != nullptr)
    context->handle->owner->poisoned = true;
}

// Statistics and environment info. Both libmdbx entry points take an optional
// transaction: with none, they report the last committed state, so a
// transaction's own uncommitted changes are invisible. Passing one scopes the
// answer to that snapshot instead, which is why both forms are exposed.
struct stat_context {
  env_handle *owner;
  MDBX_env *env;
  MDBX_txn *txn;
  MDBX_stat stat;
  int rc;
};

void stat_call(void *data) {
  stat_context *context = static_cast<stat_context *>(data);
  context->rc = mdbx_env_stat_ex(context->env, context->txn, &context->stat,
                                 sizeof(context->stat));
}

// Poisoning the environment is enough to cover its transactions too:
// txn_from_sexp() refuses a transaction whose owner is poisoned.
void poison_stat(void *data) {
  static_cast<stat_context *>(data)->owner->poisoned = true;
}

struct dbi_stat_context {
  txn_handle *handle;
  MDBX_stat stat;
  int rc;
};

void dbi_stat_call(void *data) {
  dbi_stat_context *context = static_cast<dbi_stat_context *>(data);
  context->rc = mdbx_dbi_stat(context->handle->txn, context->handle->dbi,
                              &context->stat, sizeof(context->stat));
}

void poison_dbi_stat(void *data) {
  static_cast<dbi_stat_context *>(data)->handle->poisoned = true;
}

struct info_context {
  env_handle *owner;
  MDBX_env *env;
  MDBX_txn *txn;
  MDBX_envinfo info;
  int rc;
};

void info_call(void *data) {
  info_context *context = static_cast<info_context *>(data);
  context->rc = mdbx_env_info_ex(context->env, context->txn, &context->info,
                                 sizeof(context->info));
}

void poison_info(void *data) {
  static_cast<info_context *>(data)->owner->poisoned = true;
}

// ---------------------------------------------------------------------------
// External pointer plumbing
// ---------------------------------------------------------------------------

void unregister_txn(txn_handle *handle) {
  if (handle->owner == nullptr)
    return;

  std::vector<txn_handle *> &live = handle->owner->live_txns;
  live.erase(std::remove(live.begin(), live.end(), handle), live.end());
}

// Record how a transaction ended and drop it from its environment's registry.
// Called on every path that terminates one, so that the registry holds exactly
// the transactions libmdbx still considers live.
void mark_finished(txn_handle *handle, txn_state state) {
  handle->txn = nullptr;
  handle->state = state;
  unregister_txn(handle);

  // Drop the back-reference as well. A finished transaction has no further use
  // for its environment, and finish_txn() clears the external pointer's
  // protected field to match -- so the environment can be collected while a
  // finished transaction object is still reachable. That makes this pointer
  // the one thing that could dangle, and unregister_txn() would dereference it
  // from finalize_txn(). Null is the answer to both.
  handle->owner = nullptr;
}

// Close the environment if it is still open, and detach it from the handle
// either way. `propagate` selects between the two callers: an explicit
// mdbx_close(), which should surface a failure as an R condition, and the
// finalizer, which runs during GC where raising is not an option.
void close_handle(env_handle *handle, bool propagate) {
  if (handle->env == nullptr)
    return;

  // Inherited across a fork(). Closing would release the parent's reader slot
  // and lock, from a process that never held them. Drop our copy of the pointer
  // and leave the environment to the process that owns it.
  if (handle->pid != current_pid()) {
    handle->env = nullptr;
    if (propagate)
      cpp11::stop("this mdbx environment belongs to process %ld and cannot be "
                  "closed from process %ld; it was inherited across a fork()",
                  handle->pid, current_pid());
    return;
  }

  // A panicked environment is left to the OS: re-entering libmdbx to close a
  // handle whose invariants it has already rejected is how a bad situation
  // becomes a crash.
  if (handle->poisoned) {
    handle->env = nullptr;
    return;
  }

  close_context context = {handle, MDBX_SUCCESS};
  mdbx_r_panic_info panic = {};
  mdbx_r_guard_result result =
      mdbx_r_run_guarded(close_call, &context, poison_close, &panic);

  handle->env = nullptr;

  if (!propagate)
    return;
  if (result != MDBX_R_GUARD_OK)
    stop_after_panic(panic);
  check(context.rc);
}

// Abort every transaction still registered, before the environment goes away.
//
// R does not guarantee the order in which it runs two finalizers, so when an
// environment and its transactions all become garbage in one cycle the env's
// finalizer may run first. Closing the environment would leave those handles
// dangling, and their own finalizers would then abort freed memory. Detaching
// here makes the order irrelevant: whichever runs first does the cleanup, and
// the other finds nothing to do.
void detach_txns(env_handle *handle) {
  const bool usable = handle->env != nullptr && !handle->poisoned &&
                     handle->pid == current_pid();

  for (txn_handle *txn : handle->live_txns) {
    if (usable && txn->txn != nullptr && !txn->poisoned) {
      finish_context context = {txn, false, MDBX_SUCCESS};
      mdbx_r_run_guarded(finish_call, &context, poison_finish, nullptr);
    }
    txn->txn = nullptr;
    txn->state = txn_state::aborted;
    txn->owner = nullptr;
  }

  handle->live_txns.clear();
}

void finalize_env(SEXP ptr) {
  env_handle *handle = static_cast<env_handle *>(R_ExternalPtrAddr(ptr));

  if (handle == nullptr)
    return;

  // Clear first, so a finalizer that somehow runs twice -- or an R-level close
  // racing it at shutdown -- cannot reach a freed handle.
  R_ClearExternalPtr(ptr);
  detach_txns(handle);
  close_handle(handle, false);
  delete handle;
  --live_env_handles;
}

void finalize_txn(SEXP ptr) {
  txn_handle *handle = static_cast<txn_handle *>(R_ExternalPtrAddr(ptr));

  if (handle == nullptr)
    return;

  R_ClearExternalPtr(ptr);

  // Abandoning a transaction to the GC aborts it. Only reachable while the
  // environment is still open, because detach_txns() clears handle->txn
  // whenever the environment goes first.
  if (handle->txn != nullptr && !handle->poisoned && handle->owner != nullptr &&
      handle->owner->env != nullptr && !handle->owner->poisoned &&
      handle->pid == current_pid()) {
    finish_context context = {handle, false, MDBX_SUCCESS};
    mdbx_r_run_guarded(finish_call, &context, poison_finish, nullptr);
  }

  if (handle->txn != nullptr)
    mark_finished(handle, txn_state::aborted);
  else
    unregister_txn(handle);

  delete handle;
  --live_txn_handles;
}

// Build the R object: an external pointer carrying the MDBX handle, classed
// `mdbx_env`, with the opening parameters attached as attributes.
//
// The class and attributes are set here rather than in R because modifying an
// external pointer from R risks duplicating it, and a duplicate shares the
// address without inheriting the finalizer -- the original would then close the
// environment out from under the copy.
cpp11::sexp new_env_sexp(env_handle *handle, const std::string &path,
                         bool readonly, bool subdir) {
  SEXP ptr = PROTECT(R_MakeExternalPtr(handle, env_tag(), R_NilValue));

  // r_true, not TRUE: see the note on Windows macro shadowing in r_mdbx.h.
  // Registering with onexit runs the finalizer at R shutdown as well as on GC.
  R_RegisterCFinalizerEx(ptr, finalize_env, r_true);
  ++live_env_handles;
  Rf_setAttrib(ptr, Rf_install("path"), Rf_mkString(path.c_str()));
  Rf_setAttrib(ptr, Rf_install("readonly"), Rf_ScalarLogical(readonly));
  Rf_setAttrib(ptr, Rf_install("subdir"), Rf_ScalarLogical(subdir));
  Rf_classgets(ptr, Rf_mkString("mdbx_env"));

  UNPROTECT(1);
  return ptr;
}

// Build the transaction object. The environment goes in the protected field, so
// R cannot collect the env SEXP while this transaction is reachable -- the
// parent retention the ownership model requires. It is passed to
// R_MakeExternalPtr() rather than set afterwards so there is no window in which
// the transaction exists without holding its parent.
//
// Takes ownership: past R_RegisterCFinalizerEx() the finalizer frees the
// handle, so the unique_ptr must let go at exactly that point.
cpp11::sexp new_txn_sexp(std::unique_ptr<txn_handle> handle, SEXP env_sexp,
                         bool write) {
  SEXP ptr = PROTECT(R_MakeExternalPtr(handle.get(), txn_tag(), env_sexp));

  R_RegisterCFinalizerEx(ptr, finalize_txn, r_true);
  txn_handle *raw = handle.release();
  ++live_txn_handles;
  raw->owner->live_txns.push_back(raw);

  Rf_setAttrib(ptr, Rf_install("write"), Rf_ScalarLogical(write));
  // Copied from the environment so print() can name it without reaching into
  // the protected field, which R code cannot read.
  Rf_setAttrib(ptr, Rf_install("path"),
               Rf_getAttrib(env_sexp, Rf_install("path")));
  Rf_classgets(ptr, Rf_mkString("mdbx_txn"));

  UNPROTECT(1);
  return ptr;
}

} // namespace

env_handle *env_from_sexp(SEXP x) {
  if (!is_env_sexp(x))
    cpp11::stop("expected an 'mdbx_env' object");

  env_handle *handle = static_cast<env_handle *>(R_ExternalPtrAddr(x));

  if (handle != nullptr && handle->pid != current_pid())
    cpp11::stop("this mdbx environment belongs to process %ld and cannot be "
                "used from process %ld; it was inherited across a fork(). Open "
                "the environment inside the worker instead",
                handle->pid, current_pid());

  if (handle == nullptr || handle->env == nullptr)
    cpp11::stop("this mdbx environment is closed");
  if (handle->poisoned)
    cpp11::stop("this mdbx environment is unusable after a libmdbx assertion "
                "failure");

  return handle;
}

txn_handle *txn_from_sexp(SEXP x) {
  if (TYPEOF(x) != EXTPTRSXP || !Rf_inherits(x, "mdbx_txn") ||
      R_ExternalPtrTag(x) != txn_tag())
    cpp11::stop("expected an 'mdbx_txn' object");

  txn_handle *handle = static_cast<txn_handle *>(R_ExternalPtrAddr(x));

  if (handle != nullptr && handle->pid != current_pid())
    cpp11::stop("this mdbx transaction belongs to process %ld and cannot be "
                "used from process %ld; it was inherited across a fork(). "
                "libmdbx binds a transaction to the thread that began it",
                handle->pid, current_pid());

  if (handle == nullptr)
    cpp11::stop("this mdbx transaction is no longer valid");
  if (handle->poisoned)
    cpp11::stop("this mdbx transaction is unusable after a libmdbx assertion "
                "failure");

  // Checked before the environment, so that the common mistake -- using a
  // transaction after commit or abort -- reports what actually happened.
  if (handle->txn == nullptr)
    cpp11::stop("this mdbx transaction is already %s",
                handle->state == txn_state::committed ? "committed" : "aborted");

  if (handle->owner == nullptr || handle->owner->env == nullptr)
    cpp11::stop("the environment owning this mdbx transaction is closed");
  if (handle->owner->poisoned)
    cpp11::stop("the environment owning this mdbx transaction is unusable "
                "after a libmdbx assertion failure");

  return handle;
}

} // namespace mdbx_r

// Package-load initialization. Reducing logging from NOTICE to FATAL prevents
// libmdbx's pthread_atfork child hook from calling the R console after fork.
[[cpp11::register]]
void mdbx_initialize_() {
  int native_result = -1;

  mdbx_r::guard(
      [](void *data) {
        *static_cast<int *>(data) = mdbx_setup_debug(
            MDBX_LOG_FATAL, MDBX_DBG_NONE, MDBX_LOGGER_DONTCHANGE);
      },
      &native_result, nullptr);

  if (native_result < 0)
    cpp11::stop("failed to initialize libmdbx diagnostics");
}

namespace {

// How the vendored amalgamation was actually compiled into this package. Every
// field is a plain C string owned by libmdbx; a null is reported as "".
cpp11::list mdbx_build_list() {
  using namespace cpp11::literals;
  auto text = [](const char *s) { return std::string(s ? s : ""); };

  return cpp11::writable::list({"datetime"_nm = text(mdbx_build.datetime),
                                "target"_nm = text(mdbx_build.target),
                                "compiler"_nm = text(mdbx_build.compiler),
                                "options"_nm = text(mdbx_build.options),
                                "flags"_nm = text(mdbx_build.flags)});
}

} // namespace

// Stage 1 probe. Its only job is to prove that the vendored amalgamation
// compiled and linked into this package's shared object, and that the version
// we linked against is the one pinned in .agents/vendoring.md.
[[cpp11::register]]
cpp11::list mdbx_version_() {
  using namespace cpp11::literals;

  return cpp11::writable::list({
      "major"_nm = static_cast<int>(mdbx_version.major),
      "minor"_nm = static_cast<int>(mdbx_version.minor),
      "patch"_nm = static_cast<int>(mdbx_version.patch),
      "tweak"_nm = static_cast<int>(mdbx_version.tweak),
      "describe"_nm = std::string(mdbx_version.git.describe ? mdbx_version.git.describe : ""),
      "commit"_nm = std::string(mdbx_version.git.tree ? mdbx_version.git.tree : ""),
      "build"_nm = mdbx_build_list()});
}

// Open an environment. Argument validation and defaulting happen in R; this
// receives normalized values, where a non-positive max_dbs or map_size means
// "leave the MDBX default alone".
[[cpp11::register]]
cpp11::sexp mdbx_env_open_(std::string path, bool readonly, bool subdir,
                           double max_dbs, double map_size, double max_readers,
                           int mode, cpp11::strings extra_flags) {
  // The named arguments come first, then whatever `flags` added; RDONLY and
  // NOSUBDIR are rejected in R precisely so the two cannot contradict.
  unsigned flags = MDBX_ENV_DEFAULTS | mdbx_r::env_flags_from_names(extra_flags);

  if (readonly)
    flags |= MDBX_RDONLY;
  if (!subdir)
    flags |= MDBX_NOSUBDIR;

  // Bound every value that reaches a narrowing cast below; see the notes on
  // max_exact_integer. map_size lands in an intptr_t, so it takes the
  // pointer-sized bound rather than the 64-bit one.
  if (!(max_dbs <= mdbx_r::max_exact_integer))
    cpp11::stop("max_dbs is too large: at most 2^53");
  if (!(map_size <= mdbx_r::max_native_integer))
    cpp11::stop("map_size is too large for this platform's address space");
  if (!(max_readers <= mdbx_r::max_exact_integer))
    cpp11::stop("max_readers is too large: at most 2^53");

  // The handle is allocated before the external pointer so that a failure to
  // open leaves nothing for R to reclaim; on success it is handed straight to
  // an external pointer with a finalizer.
  // Owned here until the external pointer takes it over. Both failure paths
  // below leave through a thrown R condition, so unwinding frees the handle --
  // no manual delete, and no path on which a later statement could reach a
  // freed handle.
  std::unique_ptr<mdbx_r::env_handle> handle(
      new mdbx_r::env_handle{nullptr, false, mdbx_r::current_pid()});

  mdbx_r::open_context context = {handle.get(),
                                  path.c_str(),
                                  static_cast<MDBX_env_flags_t>(flags),
                                  0,
                                  static_cast<uint64_t>(max_dbs > 0 ? max_dbs : 0),
                                  static_cast<uint64_t>(max_readers > 0 ? max_readers : 0),
                                  static_cast<intptr_t>(map_size > 0 ? map_size : 0),
                                  static_cast<mdbx_mode_t>(mode),
                                  MDBX_SUCCESS};

  mdbx_r_panic_info panic = {};
  mdbx_r_guard_result result =
      mdbx_r_run_guarded(mdbx_r::open_call, &context, mdbx_r::poison_open, &panic);

  // Poisoned mid-open: the partially built env is deliberately not closed.
  if (result != MDBX_R_GUARD_OK)
    mdbx_r::stop_after_panic(panic);

  if (context.rc != MDBX_SUCCESS) {
    // mdbx_env_create() succeeded but a later step failed; closing the handle
    // is the documented cleanup path for a created-but-unopened environment.
    if (handle->env != nullptr)
      mdbx_r::close_handle(handle.get(), false);
    mdbx_r::check(context.rc);
  }

  // Report the layout in effect rather than the argument: opening an existing
  // directory environment with the default subdir = FALSE still gets a
  // directory, and print.mdbx_env() said "single file" for it.
  const bool actual_subdir = (context.actual_flags & MDBX_NOSUBDIR) == 0;

  return mdbx_r::new_env_sexp(handle.release(), path, readonly, actual_subdir);
}

// Idempotent: closing an already-closed environment is a no-op, so that
// on.exit(mdbx_close(env)) is safe alongside an explicit close.
[[cpp11::register]]
void mdbx_env_close_(cpp11::sexp env) {
  if (!mdbx_r::is_env_sexp(env))
    cpp11::stop("expected an 'mdbx_env' object");

  mdbx_r::env_handle *handle =
      static_cast<mdbx_r::env_handle *>(R_ExternalPtrAddr(env));

  if (handle == nullptr)
    return;

  // Refuse rather than close underneath them. mdbx_env_close_ex() documents
  // that using a transaction afterwards is UB that "would cause a SIGSEGV", and
  // silently aborting the caller's transactions would hide a real bug.
  if (!handle->live_txns.empty())
    cpp11::stop("cannot close this mdbx environment: %d transaction(s) still "
                "open; commit or abort them first",
                static_cast<int>(handle->live_txns.size()));

  mdbx_r::close_handle(handle, true);
}

[[cpp11::register]]
bool mdbx_env_is_open_(cpp11::sexp env) {
  if (!mdbx_r::is_env_sexp(env))
    cpp11::stop("expected an 'mdbx_env' object");

  mdbx_r::env_handle *handle =
      static_cast<mdbx_r::env_handle *>(R_ExternalPtrAddr(env));

  // False rather than an error: this is the predicate `if (is_open(env))`
  // guards are written against, and an environment inherited across a
  // fork() is exactly as unusable here as a closed one.
  return handle != nullptr && handle->env != nullptr && !handle->poisoned &&
         handle->pid == mdbx_r::current_pid();
}

// Reclaim reader slots left behind by processes that died holding one.
//
// mdbx_reader_check() reports MDBX_RESULT_TRUE when it found something, which
// is a success and must not reach check() -- the same convention as
// mdbx_env_sync_ex().
[[cpp11::register]]
int mdbx_env_reader_check_(cpp11::sexp env) {
  mdbx_r::reader_check_context context = {mdbx_r::env_from_sexp(env), 0,
                                          MDBX_SUCCESS};

  mdbx_r::guard(mdbx_r::reader_check_call, &context, mdbx_r::poison_reader_check);

  if (context.rc != MDBX_RESULT_TRUE)
    mdbx_r::check(context.rc);

  return context.dead;
}

// The path as libmdbx itself resolved it. Requires an open environment, which
// also makes this the entry point the close-then-use tests exercise.
[[cpp11::register]]
std::string mdbx_env_path_(cpp11::sexp env) {
  mdbx_r::path_context context = {mdbx_r::env_from_sexp(env), nullptr,
                                  MDBX_SUCCESS};

  mdbx_r::guard(mdbx_r::path_call, &context, mdbx_r::poison_path);
  mdbx_r::check(context.rc);

  return std::string(context.path ? context.path : "");
}

// Begin a transaction. Read-only unless `write`, and never nested: MDBX
// supports nested write transactions, but they are out of scope for 0.1.0.
[[cpp11::register]]
cpp11::sexp mdbx_txn_begin_(cpp11::sexp env, bool write,
                            cpp11::strings extra_flags) {
  mdbx_r::env_handle *owner = mdbx_r::env_from_sexp(env);

  // libmdbx binds a transaction to the thread that starts it, so one
  // environment supports a single transaction per thread -- and R is
  // single-threaded, so that means one at a time. libmdbx spells this one rule
  // four ways depending on the pair involved (MDBX_BAD_RSLOT for read+read,
  // MDBX_TXN_OVERLAPPING for a mixed pair, MDBX_BUSY for write+write), so it is
  // reported here instead. Revisit if MDBX_NOSTICKYTHREADS is ever set, which
  // is what lifts the restriction.
  if (!owner->live_txns.empty())
    cpp11::stop("this mdbx environment already has an open transaction; commit "
                "or abort it before beginning another (libmdbx allows one "
                "transaction per environment per thread)");

  std::unique_ptr<mdbx_r::txn_handle> handle(
      new mdbx_r::txn_handle{nullptr, owner, mdbx_r::txn_state::active, write,
                             false, mdbx_r::current_pid(), 0, false});

  unsigned flags = (write ? MDBX_TXN_READWRITE : MDBX_TXN_RDONLY) |
                   mdbx_r::txn_flags_from_names(extra_flags);

  mdbx_r::begin_context context = {owner, nullptr,
                                   static_cast<MDBX_txn_flags_t>(flags),
                                   MDBX_SUCCESS};

  mdbx_r::guard(mdbx_r::begin_call, &context, mdbx_r::poison_begin);
  mdbx_r::check(context.rc);

  handle->txn = context.txn;
  return mdbx_r::new_txn_sexp(std::move(handle), env, write);
}

namespace {

// Commit and abort share everything but a flag and which state they record.
//
// The subtle part is ownership of the native handle. mdbx_txn_commit_ex()
// documents that any result other than MDBX_THREAD_MISMATCH terminates the
// transaction and invalidates the handle -- failures included, because a commit
// that cannot complete is aborted instead. So the handle is cleared whenever
// libmdbx kept it, and retained only on MDBX_THREAD_MISMATCH, where the
// transaction is explicitly still alive and still ours.
void finish_txn(cpp11::sexp txn, bool commit) {
  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);

  mdbx_r::finish_context context = {handle, commit, MDBX_SUCCESS};
  mdbx_r::guard(mdbx_r::finish_call, &context, mdbx_r::poison_finish);

  if (context.rc == MDBX_THREAD_MISMATCH)
    mdbx_r::check(context.rc);

  mdbx_r::mark_finished(handle, commit && context.rc == MDBX_SUCCESS
                                    ? mdbx_r::txn_state::committed
                                    : mdbx_r::txn_state::aborted);

  // mdbx_txn_commit_ex() documents MDBX_RESULT_TRUE as "transaction was
  // aborted since it should be aborted due to previous errors". It is a
  // failure for the caller -- nothing was written -- but it is not an error
  // code, so mdbx_strerror() renders it as the useless "error -1".
  // Release the environment. Until this point the protected field kept the env
  // SEXP alive so a transaction could never outlive it; now that the
  // transaction is over, holding on would pin the memory map and its file
  // descriptors for as long as the caller kept the finished object.
  R_SetExternalPtrProtected(txn, R_NilValue);

  if (context.rc == MDBX_RESULT_TRUE)
    cpp11::stop("this mdbx transaction was rolled back instead of committed: an "
                "earlier operation in it failed, which leaves the whole "
                "transaction unusable. No changes were written");

  mdbx_r::check(context.rc);
}

} // namespace

// Not idempotent, unlike abort: committing twice is a logic error, and the
// second call cannot do what the caller believes it does.
[[cpp11::register]]
void mdbx_txn_commit_(cpp11::sexp txn) { finish_txn(txn, true); }

// Idempotent, so that on.exit(mdbx_abort(txn)) is safe next to an explicit
// commit -- which is exactly how mdbx_with_write() uses it.
[[cpp11::register]]
void mdbx_txn_abort_(cpp11::sexp txn) {
  if (TYPEOF(txn) != EXTPTRSXP || !Rf_inherits(txn, "mdbx_txn"))
    cpp11::stop("expected an 'mdbx_txn' object");

  mdbx_r::txn_handle *handle =
      static_cast<mdbx_r::txn_handle *>(R_ExternalPtrAddr(txn));

  if (handle == nullptr || handle->txn == nullptr)
    return;

  finish_txn(txn, false);
}

[[cpp11::register]]
std::string mdbx_txn_state_(cpp11::sexp txn) {
  if (TYPEOF(txn) != EXTPTRSXP || !Rf_inherits(txn, "mdbx_txn"))
    cpp11::stop("expected an 'mdbx_txn' object");

  mdbx_r::txn_handle *handle =
      static_cast<mdbx_r::txn_handle *>(R_ExternalPtrAddr(txn));

  if (handle == nullptr)
    return "invalid";
  if (handle->poisoned)
    return "poisoned";

  switch (handle->state) {
  case mdbx_r::txn_state::active:
    return "active";
  case mdbx_r::txn_state::committed:
    return "committed";
  default:
    return "aborted";
  }
}

// The transaction's MVCC snapshot id. Requires an active transaction, which
// also makes it the entry point the use-after-commit tests exercise.
[[cpp11::register]]
double mdbx_txn_id_(cpp11::sexp txn) {
  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);
  return static_cast<double>(mdbx_txn_id(handle->txn));
}

namespace {

// Borrow a raw vector's bytes as an MDBX_val. Nothing is copied: the vector
// stays alive for the duration of the call that uses this.
MDBX_val val_from_raw(SEXP x) {
  MDBX_val value;
  value.iov_base = RAW(x);
  value.iov_len = static_cast<size_t>(XLENGTH(x));
  return value;
}

// Copy an MDBX_val out into a fresh raw vector.
//
// This copy is mandatory, not caution: mdbx_get() documents that the memory it
// returns is owned by the database and "valid only until a subsequent update
// operation, or the end of the transaction", and that writing through it can
// corrupt the database. R objects outlive transactions, so nothing may point
// into the map.
cpp11::sexp raw_from_val(const MDBX_val &value) {
  cpp11::sexp out(Rf_allocVector(RAWSXP, static_cast<R_xlen_t>(value.iov_len)));

  if (value.iov_len > 0)
    std::memcpy(RAW(out), value.iov_base, value.iov_len);

  return out;
}

// The main database handle, opened on first use and reused for the rest of the
// transaction.
// Point handle->dbi at the database this operation addresses, opening it in
// this transaction if it has not been resolved here yet. `name` is null for the
// unnamed main database.
MDBX_dbi ensure_dbi(mdbx_r::txn_handle *handle, const std::string *name) {
  if (name == nullptr) {
    if (handle->main_ready) {
      handle->dbi = handle->main_dbi;
      return handle->dbi;
    }
  } else {
    for (const auto &entry : handle->named) {
      if (entry.first == *name) {
        handle->dbi = entry.second;
        return handle->dbi;
      }
    }
  }

  mdbx_r::dbi_context context = {handle, name ? name->c_str() : nullptr,
                                 MDBX_DB_DEFAULTS, 0, MDBX_SUCCESS};

  mdbx_r::guard(mdbx_r::dbi_call, &context, mdbx_r::poison_dbi);
  mdbx_r::check(context.rc);

  if (name == nullptr) {
    handle->main_dbi = context.dbi;
    handle->main_ready = true;
  } else {
    handle->named.emplace_back(*name, context.dbi);
  }

  handle->dbi = context.dbi;
  return handle->dbi;
}

// The database named by an R argument: character(0) means the main database.
MDBX_dbi ensure_dbi(mdbx_r::txn_handle *handle, cpp11::strings db) {
  if (db.size() == 0)
    return ensure_dbi(handle, nullptr);

  const std::string name(db[0]);
  return ensure_dbi(handle, &name);
}

mdbx_r::txn_handle *writable_txn(cpp11::sexp txn) {
  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);

  // libmdbx would report MDBX_EACCESS; name the actual problem.
  if (!handle->write)
    cpp11::stop("this mdbx transaction is read-only; begin one with "
                "write = TRUE to modify the database");

  return handle;
}

} // namespace

// Look a key up. Returns NULL for a key that is not present -- MDBX_NOTFOUND is
// an expected outcome, not an error -- which is distinguishable from a stored
// zero-length value, since that comes back as raw(0).
[[cpp11::register]]
cpp11::sexp mdbx_get_(cpp11::sexp txn, cpp11::sexp key, cpp11::strings db) {
  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);

  mdbx_r::get_context context = {handle, val_from_raw(key), {nullptr, 0},
                                 MDBX_SUCCESS};
  ensure_dbi(handle, db);

  mdbx_r::guard(mdbx_r::get_call, &context, mdbx_r::poison_get);

  if (context.rc == MDBX_NOTFOUND)
    return cpp11::sexp(R_NilValue);

  mdbx_r::check(context.rc);
  return raw_from_val(context.data);
}

// Store a value. Returns FALSE, rather than raising, when overwrite is FALSE
// and the key is already present: the caller asked for that outcome, so it is
// an answer rather than a failure.
[[cpp11::register]]
bool mdbx_put_(cpp11::sexp txn, cpp11::sexp key, cpp11::sexp value,
               bool overwrite, cpp11::strings db) {
  mdbx_r::txn_handle *handle = writable_txn(txn);

  mdbx_r::put_context context = {
      handle, val_from_raw(key), val_from_raw(value),
      static_cast<MDBX_put_flags_t>(overwrite ? MDBX_UPSERT : MDBX_NOOVERWRITE),
      MDBX_SUCCESS};
  ensure_dbi(handle, db);

  mdbx_r::guard(mdbx_r::put_call, &context, mdbx_r::poison_put);

  if (context.rc == MDBX_KEYEXIST)
    return false;

  mdbx_r::check(context.rc);
  return true;
}

// Delete a key. Returns whether a record existed, so deleting an absent key is
// FALSE rather than an error.
[[cpp11::register]]
bool mdbx_del_(cpp11::sexp txn, cpp11::sexp key, cpp11::strings db) {
  mdbx_r::txn_handle *handle = writable_txn(txn);

  mdbx_r::del_context context = {handle, val_from_raw(key), MDBX_SUCCESS};
  ensure_dbi(handle, db);

  mdbx_r::guard(mdbx_r::del_call, &context, mdbx_r::poison_del);

  if (context.rc == MDBX_NOTFOUND)
    return false;

  mdbx_r::check(context.rc);
  return true;
}

namespace {

// libmdbx counts and sizes are uint64. R has no 64-bit integer, so they come
// across as double: exact for every value below 2^53, which is far beyond any
// realistic page count or database size.
inline double as_num(uint64_t value) { return static_cast<double>(value); }

cpp11::list stat_list(const MDBX_stat &stat) {
  using namespace cpp11::literals;

  return cpp11::writable::list({"pagesize"_nm = as_num(stat.ms_psize),
                                "depth"_nm = as_num(stat.ms_depth),
                                "branch_pages"_nm = as_num(stat.ms_branch_pages),
                                "leaf_pages"_nm = as_num(stat.ms_leaf_pages),
                                "overflow_pages"_nm = as_num(stat.ms_overflow_pages),
                                "entries"_nm = as_num(stat.ms_entries),
                                "mod_txnid"_nm = as_num(stat.ms_mod_txnid)});
}

// A curated subset of MDBX_envinfo. The struct also carries meta-page
// signatures, boot ids, per-operation page counters and sync timings, all of
// which are diagnostics for libmdbx itself rather than for callers.
cpp11::list info_list(const MDBX_envinfo &info) {
  using namespace cpp11::literals;

  return cpp11::writable::list(
      {"geo_lower"_nm = as_num(info.mi_geo.lower),
       "geo_upper"_nm = as_num(info.mi_geo.upper),
       "geo_current"_nm = as_num(info.mi_geo.current),
       "geo_shrink"_nm = as_num(info.mi_geo.shrink),
       "geo_grow"_nm = as_num(info.mi_geo.grow),
       "mapsize"_nm = as_num(info.mi_mapsize),
       "file_size"_nm = as_num(info.mi_dxb_fsize),
       "last_pgno"_nm = as_num(info.mi_last_pgno),
       "recent_txnid"_nm = as_num(info.mi_recent_txnid),
       "latter_reader_txnid"_nm = as_num(info.mi_latter_reader_txnid),
       "maxreaders"_nm = as_num(info.mi_maxreaders),
       "numreaders"_nm = as_num(info.mi_numreaders),
       "pagesize"_nm = as_num(info.mi_dxb_pagesize),
       "sys_pagesize"_nm = as_num(info.mi_sys_pagesize)});
}

cpp11::list run_stat(mdbx_r::env_handle *owner, MDBX_txn *txn) {
  mdbx_r::stat_context context = {owner, owner->env, txn, {}, MDBX_SUCCESS};

  mdbx_r::guard(mdbx_r::stat_call, &context, mdbx_r::poison_stat);
  mdbx_r::check(context.rc);

  return stat_list(context.stat);
}

cpp11::list run_info(mdbx_r::env_handle *owner, MDBX_txn *txn) {
  mdbx_r::info_context context = {owner, owner->env, txn, {}, MDBX_SUCCESS};

  mdbx_r::guard(mdbx_r::info_call, &context, mdbx_r::poison_info);
  mdbx_r::check(context.rc);

  return info_list(context.info);
}

// The transaction this thread already holds on the environment, if any.
//
// Passing a null transaction makes libmdbx start an internal read transaction
// of its own, which collides with one this thread is already holding and fails
// with MDBX_BAD_RSLOT. Reusing the live transaction avoids the collision, and
// makes the environment and transaction forms report the same thing -- which
// is what the documentation has always claimed they do.
MDBX_txn *current_txn(mdbx_r::env_handle *handle) {
  for (mdbx_r::txn_handle *txn : handle->live_txns) {
    if (txn->txn != nullptr)
      return txn->txn;
  }
  return nullptr;
}

} // namespace

[[cpp11::register]]
cpp11::list mdbx_env_stat_(cpp11::sexp env) {
  mdbx_r::env_handle *handle = mdbx_r::env_from_sexp(env);
  return run_stat(handle, current_txn(handle));
}

[[cpp11::register]]
cpp11::list mdbx_txn_stat_(cpp11::sexp txn, cpp11::strings db) {
  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);

  if (db.size() == 0)
    return run_stat(handle->owner, handle->txn);

  // A named database has its own B-tree, so mdbx_env_stat_ex() -- which
  // describes the main one -- is the wrong question to ask about it.
  ensure_dbi(handle, db);

  mdbx_r::dbi_stat_context context = {handle, {}, MDBX_SUCCESS};
  mdbx_r::guard(mdbx_r::dbi_stat_call, &context, mdbx_r::poison_dbi_stat);
  mdbx_r::check(context.rc);

  return stat_list(context.stat);
}

[[cpp11::register]]
cpp11::list mdbx_env_info_(cpp11::sexp env) {
  mdbx_r::env_handle *handle = mdbx_r::env_from_sexp(env);
  return run_info(handle, current_txn(handle));
}

[[cpp11::register]]
cpp11::list mdbx_txn_info_(cpp11::sexp txn) {
  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);
  return run_info(handle->owner, handle->txn);
}

namespace {

cpp11::sexp raw_from_string(const std::string &bytes) {
  cpp11::sexp out(Rf_allocVector(RAWSXP, static_cast<R_xlen_t>(bytes.size())));

  if (!bytes.empty())
    std::memcpy(RAW(out), bytes.data(), bytes.size());

  return out;
}

cpp11::list list_of_raws(const std::vector<std::string> &items) {
  cpp11::writable::list out(static_cast<R_xlen_t>(items.size()));

  for (size_t i = 0; i < items.size(); ++i)
    out[static_cast<R_xlen_t>(i)] = raw_from_string(items[i]);

  return out;
}

} // namespace

// Walk the database in key order, returning keys and optionally values as
// lists of raw vectors. `limit` is the maximum number of records to return; a
// *negative* value means no limit. Zero must stay distinguishable from "all",
// so it cannot double as the sentinel.
[[cpp11::register]]
cpp11::list mdbx_scan_(cpp11::sexp txn, double limit, bool values,
                       cpp11::strings db, cpp11::sexp start, bool reverse) {
  // See mdbx_env_open_(): out-of-range double->integer is undefined behaviour,
  // and this is reachable through :::. The destination is a size_t.
  if (!(limit <= mdbx_r::max_native_integer))
    cpp11::stop("limit is too large for this platform");

  using namespace cpp11::literals;

  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);
  ensure_dbi(handle, db);

  std::vector<std::string> keys;
  std::vector<std::string> vals;

  // `start` is a raw vector or NULL; the bytes stay alive for the guarded call
  // because the SEXP is protected by the caller's argument list.
  const bool has_start = TYPEOF(start) == RAWSXP;

  mdbx_r::scan_context context = {
      handle,
      nullptr,
      limit < 0 ? static_cast<size_t>(-1) : static_cast<size_t>(limit),
      values,
      reverse,
      has_start ? reinterpret_cast<const char *>(RAW(start)) : nullptr,
      has_start ? static_cast<size_t>(Rf_xlength(start)) : 0,
      &keys,
      &vals,
      false,
      MDBX_SUCCESS};

  mdbx_r::guard(mdbx_r::scan_call, &context, mdbx_r::poison_scan);

  if (context.out_of_memory)
    cpp11::stop("ran out of memory collecting keys; use `limit` to read fewer");

  mdbx_r::check(context.rc);

  return cpp11::writable::list(
      {"keys"_nm = list_of_raws(keys),
       "values"_nm = values ? list_of_raws(vals) : cpp11::list()});
}

// Internal test hook, as for environments: live transaction handles, so the
// suite can assert that GC reclaims abandoned ones.
[[cpp11::register]]
int mdbx_txn_live_count_() { return mdbx_r::live_txn_handles; }

// Internal test hook: how many transactions the environment still considers
// open. Proves the registry that keeps env close from segfaulting stays exact.
[[cpp11::register]]
int mdbx_env_txn_count_(cpp11::sexp env) {
  return static_cast<int>(mdbx_r::env_from_sexp(env)->live_txns.size());
}

// Internal test hook: how many environment handles have been allocated and not
// yet finalized. Used to assert that GC reclaims abandoned environments.
[[cpp11::register]]
int mdbx_env_live_count_() { return mdbx_r::live_env_handles; }

// The size limits libmdbx computes for a given page size.
//
// No panic guard: these are arithmetic on a page size, touching neither an
// environment nor a transaction. An unusable page size is reported as -1
// rather than asserted, which is checked for below. A page size of zero means
// "the default for this system".
[[cpp11::register]]
cpp11::list mdbx_limits_(double pagesize) {
  using namespace cpp11::literals;

  // `pagesize` arrives as a plain double and lands in an intptr_t, so Inf, NaN
  // and anything past the pointer range must be stopped before the cast.
  if (!(pagesize <= mdbx_r::max_native_integer))
    cpp11::stop("page size is too large for this platform");

  const intptr_t ps = static_cast<intptr_t>(pagesize > 0 ? pagesize : 0);
  const MDBX_db_flags_t flags = MDBX_DB_DEFAULTS;

  const intptr_t key_max = mdbx_limits_keysize_max(ps, flags);
  const intptr_t val_max = mdbx_limits_valsize_max(ps, flags);
  const intptr_t db_min = mdbx_limits_dbsize_min(ps);
  const intptr_t db_max = mdbx_limits_dbsize_max(ps);
  const intptr_t txn_max = mdbx_limits_txnsize_max(ps);

  if (key_max < 0 || val_max < 0 || db_min < 0 || db_max < 0 || txn_max < 0)
    cpp11::stop("%.0f is not a usable page size for libmdbx", pagesize);

  return cpp11::writable::list(
      {"pagesize"_nm = as_num(ps > 0 ? static_cast<uint64_t>(ps)
                                     : mdbx_default_pagesize()),
       "keysize_min"_nm = as_num(static_cast<uint64_t>(mdbx_limits_keysize_min(flags))),
       "keysize_max"_nm = as_num(static_cast<uint64_t>(key_max)),
       "valsize_min"_nm = as_num(static_cast<uint64_t>(mdbx_limits_valsize_min(flags))),
       "valsize_max"_nm = as_num(static_cast<uint64_t>(val_max)),
       "dbsize_min"_nm = as_num(static_cast<uint64_t>(db_min)),
       "dbsize_max"_nm = as_num(static_cast<uint64_t>(db_max)),
       "txnsize_max"_nm = as_num(static_cast<uint64_t>(txn_max))});
}

// Open a named database, creating it if asked. Errors here rather than at
// first use, so a mistyped name is reported where it was written.
//
// The handle is deliberately not handed back to R: it is cached against this
// transaction and re-resolved by name in every later one. A dbi obtained in a
// transaction that goes on to abort is poisoned, so an R object holding the
// number could hand out an invalid handle.
[[cpp11::register]]
void mdbx_dbi_open_(cpp11::sexp txn, std::string name, bool create) {
  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);

  mdbx_r::dbi_context context = {
      handle, name.c_str(),
      static_cast<unsigned>(create ? MDBX_CREATE : MDBX_DB_DEFAULTS), 0,
      MDBX_SUCCESS};

  mdbx_r::guard(mdbx_r::dbi_call, &context, mdbx_r::poison_dbi);
  mdbx_r::check(context.rc);

  for (auto &entry : handle->named) {
    if (entry.first == name) {
      entry.second = context.dbi;
      return;
    }
  }
  handle->named.emplace_back(name, context.dbi);
}

namespace {

struct drop_context {
  mdbx_r::txn_handle *handle;
  bool del;
  int rc;
};

void drop_call(void *data) {
  drop_context *context = static_cast<drop_context *>(data);
  context->rc =
      mdbx_drop(context->handle->txn, context->handle->dbi, context->del);
}

void poison_drop(void *data) {
  static_cast<drop_context *>(data)->handle->poisoned = true;
}

} // namespace

namespace {

struct sequence_context {
  mdbx_r::txn_handle *handle;
  uint64_t result;
  uint64_t increment;
  int rc;
};

void sequence_call(void *data) {
  sequence_context *context = static_cast<sequence_context *>(data);
  context->rc = mdbx_dbi_sequence(context->handle->txn, context->handle->dbi,
                                  &context->result, context->increment);
}

void poison_sequence(void *data) {
  static_cast<sequence_context *>(data)->handle->poisoned = true;
}

} // namespace

// Read, and optionally advance, a database's sequence counter.
[[cpp11::register]]
double mdbx_dbi_sequence_(cpp11::sexp txn, cpp11::strings db, double increment) {
  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);
  ensure_dbi(handle, db);

  // Read before deciding, so the range check below happens while nothing has
  // been mutated: erroring after a successful increment would leave the counter
  // advanced by an amount the caller never received.
  sequence_context context = {handle, 0, 0, MDBX_SUCCESS};
  mdbx_r::guard(sequence_call, &context, poison_sequence);
  mdbx_r::check(context.rc);

  const double current = static_cast<double>(context.result);

  if (increment <= 0)
    return current;

  // The counter is 64-bit in libmdbx but reaches R as a double, which stops
  // holding consecutive integers past 2^53 -- two successive increments there
  // return the same number. A sequence documented as unique must refuse to
  // continue rather than hand out duplicates.
  if (!(increment <= mdbx_r::max_exact_integer) ||
      current > mdbx_r::max_exact_integer - increment)
    cpp11::stop("this sequence stands at %.0f, and reserving %.0f more would "
                "pass 2^53, the largest integer R's numeric type holds "
                "exactly. Past that point the counter would hand out duplicate "
                "values, so it stops here",
                current, increment);

  context.increment = static_cast<uint64_t>(increment);
  context.result = 0;
  context.rc = MDBX_SUCCESS;
  mdbx_r::guard(sequence_call, &context, poison_sequence);

  // libmdbx reports its own 64-bit overflow as MDBX_RESULT_TRUE, which check()
  // would render as the meaningless "mdbx error -1". Unreachable while the 2^53
  // bound above holds, but it is the documented status and costs nothing.
  if (context.rc == MDBX_RESULT_TRUE)
    cpp11::stop("this sequence cannot be increased by %.0f without overflowing "
                "its 64-bit counter", increment);
  mdbx_r::check(context.rc);

  return static_cast<double>(context.result);
}

// Empty a database, or delete it outright.
[[cpp11::register]]
void mdbx_dbi_drop_(cpp11::sexp txn, cpp11::strings db, bool del) {
  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);
  ensure_dbi(handle, db);

  drop_context context = {handle, del, MDBX_SUCCESS};
  mdbx_r::guard(drop_call, &context, poison_drop);
  mdbx_r::check(context.rc);

  // A deleted database's handle is spent; forget it so anything later in this
  // transaction re-resolves by name instead of reusing it.
  if (del && db.size() > 0) {
    const std::string name(db[0]);
    auto &named = handle->named;
    for (size_t i = 0; i < named.size(); ++i) {
      if (named[i].first == name) {
        named.erase(named.begin() + static_cast<std::ptrdiff_t>(i));
        break;
      }
    }
  }
}

namespace {

struct list_context {
  mdbx_r::txn_handle *handle;
  std::vector<std::string> *names;
  bool out_of_memory;
  int rc;
};

// libmdbx declares the visitor noexcept, so an allocation failure has to become
// a flag rather than an exception -- the same shape as the scan callback.
int list_visit(void *ctx, const MDBX_txn *, const MDBX_val *name,
               MDBX_db_flags_t, const struct MDBX_stat *,
               MDBX_dbi) MDBX_CXX17_NOEXCEPT {
  list_context *context = static_cast<list_context *>(ctx);
  try {
    context->names->emplace_back(static_cast<const char *>(name->iov_base),
                                 name->iov_len);
  } catch (...) {
    context->out_of_memory = true;
    return MDBX_ENOMEM;
  }
  return 0;
}

void list_call(void *data) {
  list_context *context = static_cast<list_context *>(data);
  context->rc = mdbx_enumerate_tables(context->handle->txn, list_visit, context);
}

void poison_list(void *data) {
  static_cast<list_context *>(data)->handle->poisoned = true;
}

} // namespace

// The named databases that exist in this transaction's view.
//
// Names are bytes to libmdbx, so they come back as raw vectors and R decodes
// them -- the same contract as keys.
[[cpp11::register]]
cpp11::list mdbx_dbi_list_(cpp11::sexp txn) {
  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);

  std::vector<std::string> names;
  list_context context = {handle, &names, false, MDBX_SUCCESS};

  mdbx_r::guard(list_call, &context, poison_list);

  if (context.out_of_memory)
    cpp11::stop("ran out of memory listing databases");

  mdbx_r::check(context.rc);

  cpp11::writable::list out(static_cast<R_xlen_t>(names.size()));
  for (size_t i = 0; i < names.size(); ++i) {
    cpp11::writable::raws item(static_cast<R_xlen_t>(names[i].size()));
    std::memcpy(RAW(item), names[i].data(), names[i].size());
    out[static_cast<R_xlen_t>(i)] = item;
  }
  return out;
}

// Internal test hook: push a status code through the error translator.
//
// The bug this exists to prevent: libmdbx has result codes that are not error
// codes -- MDBX_RESULT_TRUE above all, returned by mdbx_env_sync_ex(),
// mdbx_reader_check() and mdbx_txn_commit_ex() to mean something specific and
// successful. mdbx_strerror() has no name for them, so translating one yields
// the useless "error -1". Every call site must intercept those before check();
// the test suite uses this hook to assert both halves of that.
[[cpp11::register]]
void mdbx_test_check_(int rc) { mdbx_r::check(rc); }

// The status codes the translator is expected to render by name, as libmdbx
// itself defines them -- no numeric literals in the test.
[[cpp11::register]]
cpp11::integers mdbx_test_error_codes_() {
  using namespace cpp11::literals;

  cpp11::writable::integers out;
  cpp11::writable::strings names;

  const struct { const char *name; int code; } table[] = {
      {"MDBX_KEYEXIST", MDBX_KEYEXIST},
      {"MDBX_NOTFOUND", MDBX_NOTFOUND},
      {"MDBX_CORRUPTED", MDBX_CORRUPTED},
      {"MDBX_PANIC", MDBX_PANIC},
      {"MDBX_VERSION_MISMATCH", MDBX_VERSION_MISMATCH},
      {"MDBX_INVALID", MDBX_INVALID},
      {"MDBX_MAP_FULL", MDBX_MAP_FULL},
      {"MDBX_DBS_FULL", MDBX_DBS_FULL},
      {"MDBX_READERS_FULL", MDBX_READERS_FULL},
      {"MDBX_TXN_FULL", MDBX_TXN_FULL},
      {"MDBX_PAGE_FULL", MDBX_PAGE_FULL},
      {"MDBX_UNABLE_EXTEND_MAPSIZE", MDBX_UNABLE_EXTEND_MAPSIZE},
      {"MDBX_INCOMPATIBLE", MDBX_INCOMPATIBLE},
      {"MDBX_BAD_RSLOT", MDBX_BAD_RSLOT},
      {"MDBX_BAD_TXN", MDBX_BAD_TXN},
      {"MDBX_BAD_VALSIZE", MDBX_BAD_VALSIZE},
      {"MDBX_BAD_DBI", MDBX_BAD_DBI},
      {"MDBX_PROBLEM", MDBX_PROBLEM},
      {"MDBX_BUSY", MDBX_BUSY},
      {"MDBX_EBADSIGN", MDBX_EBADSIGN},
      {"MDBX_WANNA_RECOVERY", MDBX_WANNA_RECOVERY},
      {"MDBX_EKEYMISMATCH", MDBX_EKEYMISMATCH},
      {"MDBX_TOO_LARGE", MDBX_TOO_LARGE},
      {"MDBX_THREAD_MISMATCH", MDBX_THREAD_MISMATCH},
      {"MDBX_TXN_OVERLAPPING", MDBX_TXN_OVERLAPPING},
      {"MDBX_DANGLING_DBI", MDBX_DANGLING_DBI},
  };

  for (const auto &entry : table) {
    out.push_back(entry.code);
    names.push_back(entry.name);
  }
  out.attr("names") = names;
  return out;
}

// The one code that must never reach the translator, named rather than spelled
// as a literal in the tests.
[[cpp11::register]]
int mdbx_test_result_true_() { return MDBX_RESULT_TRUE; }

// Internal test hook: prove MDBX_TXN_CHECKOWNER actually fires, rather than
// trusting that the compile flag is enough.
//
// libmdbx binds a transaction to the thread that began it, and R is
// single-threaded, so the only way to reach that check from the suite is to
// call libmdbx from a thread of our own. The thread touches nothing but the
// MDBX handle: no R API, which is undefined off the main thread, and no panic
// guard, whose jump buffer belongs to this one.
//
// mdbx_txn_commit_ex() frees the transaction on every result except
// MDBX_THREAD_MISMATCH, so anything else leaves our handle dangling and has to
// be recorded before returning -- the test asserts on the code either way.
[[cpp11::register]]
int mdbx_test_thread_mismatch_(cpp11::sexp txn) {
  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);
  MDBX_txn *raw = handle->txn;
  int rc = MDBX_SUCCESS;

  std::thread worker([raw, &rc]() { rc = mdbx_txn_commit(raw); });
  worker.join();

  if (rc != MDBX_THREAD_MISMATCH)
    mdbx_r::mark_finished(handle, mdbx_r::txn_state::aborted);

  return rc;
}

// Internal test hook: the numeric code libmdbx uses for a cross-thread misuse,
// so the test asserts against libmdbx's own constant rather than a literal.
[[cpp11::register]]
int mdbx_thread_mismatch_code_() { return MDBX_THREAD_MISMATCH; }

// Internal regression hook: drive a panic through the guards that
// mdbx_env_stat() and mdbx_env_info() install, and prove the environment comes
// back poisoned. Those two used to pass no poison callback at all, so an
// assertion inside them became an R error while leaving the handle apparently
// usable -- and its finalizer would then call libmdbx again on an environment
// whose invariants had just failed.
//
// It uses the real contexts and the real poison callbacks; exercising a copy
// of them would prove nothing about the entry points.
namespace {

void panic_immediately(void *) {
  mdbx_r_panic("stat-guard test", "panic_immediately", 1);
}

} // namespace

[[cpp11::register]]
void mdbx_test_panic_stat_(cpp11::sexp env, bool info) {
  mdbx_r::env_handle *handle = mdbx_r::env_from_sexp(env);

  if (info) {
    mdbx_r::info_context context = {handle, handle->env, nullptr, {},
                                    MDBX_SUCCESS};
    mdbx_r::guard(panic_immediately, &context, mdbx_r::poison_info);
  } else {
    mdbx_r::stat_context context = {handle, handle->env, nullptr, {},
                                    MDBX_SUCCESS};
    mdbx_r::guard(panic_immediately, &context, mdbx_r::poison_stat);
  }
}

// Internal regression hook. It deliberately enters the panic path and checks
// that the C-side poison callback ran before the panic crossed into C++.
[[cpp11::register]]
void mdbx_test_panic_boundary_() {
  mdbx_r_panic_info panic = {};
  int poisoned = 0;
  mdbx_r_guard_result result = mdbx_r_test_panic_boundary(&poisoned, &panic);

  if (result != MDBX_R_GUARD_PANIC)
    cpp11::stop("internal panic-boundary test did not observe a panic");
  if (!poisoned)
    cpp11::stop("internal panic-boundary test did not poison its owner");

  cpp11::stop("libmdbx assertion failed: %s (%s:%u)", panic.message,
              panic.function, panic.line);
}
