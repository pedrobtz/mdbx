// Environment and transaction flags.
//
// libmdbx takes its flags as an OR'ed bitmask. R has no comfortable idiom for
// that, so this layer takes a character vector of the C names with the `MDBX_`
// prefix dropped -- `c("SAFE_NOSYNC", "WRITEMAP")` -- and does the OR here.
// The vocabulary lives in C++ rather than R so the bit values come from the
// vendored mdbx.h itself and cannot drift from it.

#include <cstring>
#include <string>
#include <vector>

#include "r_mdbx.h"

namespace mdbx_r {

namespace {

struct flag_entry {
  const char *name;
  unsigned bit;
  bool settable; // may be passed to mdbx_env_open()
  bool runtime;  // may be passed to mdbx_env_set_flags()
};

// Environment flags.
//
// UTTERLY_NOSYNC comes before SAFE_NOSYNC because it is a superset of it
// (SAFE_NOSYNC | 0x100000) and reporting walks this table in order.
//
// `runtime` follows mdbx.h, which says of exactly these five that the flag
// "may be changed at any time using mdbx_env_set_flags()". The rest are fixed
// at open, and libmdbx does not promise anything useful if they are changed.
//
// Three flags are reported but not settable. RDONLY and NOSUBDIR are the
// `readonly` and `subdir` arguments of mdbx_env_open(), so there would be two
// ways to say the same thing. NOSTICKYTHREADS is deliberately never set: it is
// what would lift libmdbx's one-transaction-per-thread rule, and the live
// transaction registry, the finalizer ordering and mdbx_txn_begin()'s refusal
// to open a second transaction are all built on that rule holding.
const flag_entry env_flags[] = {
    {"UTTERLY_NOSYNC", MDBX_UTTERLY_NOSYNC, true, true},
    {"SAFE_NOSYNC", MDBX_SAFE_NOSYNC, true, true},
    {"NOMETASYNC", MDBX_NOMETASYNC, true, true},
    {"WRITEMAP", MDBX_WRITEMAP, true, false},
    {"LIFORECLAIM", MDBX_LIFORECLAIM, true, true},
    {"NORDAHEAD", MDBX_NORDAHEAD, true, false},
    {"NOMEMINIT", MDBX_NOMEMINIT, true, true},
    {"EXCLUSIVE", MDBX_EXCLUSIVE, true, false},
    {"ACCEDE", MDBX_ACCEDE, true, false},
    {"VALIDATION", MDBX_VALIDATION, true, false},
    {"RDONLY", MDBX_RDONLY, false, false},
    {"NOSUBDIR", MDBX_NOSUBDIR, false, false},
    {"NOSTICKYTHREADS", MDBX_NOSTICKYTHREADS, false, false},
};

// Transaction flags accepted by mdbx_txn_begin(). RDONLY is the `write`
// argument. NOSYNC is upstream's name for the same bit the environment calls
// SAFE_NOSYNC; both names are kept as libmdbx spells them.
const flag_entry txn_flags[] = {
    {"NOSYNC", MDBX_TXN_NOSYNC, true, false},
    {"NOMETASYNC", MDBX_TXN_NOMETASYNC, true, false},
    {"TRY", MDBX_TXN_TRY, true, false},
};

// Names are validated in R, which can produce a better message than this can.
// Reaching the fallback means the two vocabularies disagree, which is a bug
// here rather than a user error.
unsigned bits_from(cpp11::strings names, const flag_entry *table, size_t size) {
  unsigned bits = 0;

  for (R_xlen_t i = 0; i < names.size(); ++i) {
    std::string name(names[i]);
    bool found = false;

    for (size_t j = 0; j < size; ++j) {
      if (name == table[j].name) {
        bits |= table[j].bit;
        found = true;
        break;
      }
    }

    if (!found)
      cpp11::stop("unknown mdbx flag '%s'", name.c_str());
  }

  return bits;
}

// A flag is present when every one of its bits is, which is what makes
// UTTERLY_NOSYNC distinguishable from the SAFE_NOSYNC it contains. Once
// UTTERLY_NOSYNC matches, SAFE_NOSYNC is suppressed: reporting both would
// describe one mode as two.
cpp11::writable::strings names_from(unsigned bits) {
  cpp11::writable::strings out;
  bool utterly = false;

  for (const flag_entry &entry : env_flags) {
    if ((bits & entry.bit) != entry.bit)
      continue;
    if (std::strcmp(entry.name, "UTTERLY_NOSYNC") == 0)
      utterly = true;
    if (utterly && std::strcmp(entry.name, "SAFE_NOSYNC") == 0)
      continue;
    out.push_back(entry.name);
  }

  return out;
}

struct sync_context {
  env_handle *handle;
  bool force;
  bool nonblock;
  int rc;
};

void sync_call(void *data) {
  sync_context *context = static_cast<sync_context *>(data);
  context->rc =
      mdbx_env_sync_ex(context->handle->env, context->force, context->nonblock);
}

void poison_sync(void *data) {
  static_cast<sync_context *>(data)->handle->poisoned = true;
}

struct flags_context {
  env_handle *handle;
  unsigned bits;
  bool on;
  int rc;
};

void get_flags_call(void *data) {
  flags_context *context = static_cast<flags_context *>(data);
  context->rc = mdbx_env_get_flags(context->handle->env, &context->bits);
}

void set_flags_call(void *data) {
  flags_context *context = static_cast<flags_context *>(data);
  context->rc = mdbx_env_set_flags(
      context->handle->env, static_cast<MDBX_env_flags_t>(context->bits),
      context->on);
}

void poison_flags(void *data) {
  static_cast<flags_context *>(data)->handle->poisoned = true;
}

} // namespace

unsigned env_flags_from_names(cpp11::strings names) {
  return bits_from(names, env_flags, sizeof env_flags / sizeof env_flags[0]);
}

unsigned txn_flags_from_names(cpp11::strings names) {
  return bits_from(names, txn_flags, sizeof txn_flags / sizeof txn_flags[0]);
}

} // namespace mdbx_r

// The flag vocabulary, as data. R validates against this, and mdbx_flags()
// shows it to the user; neither hardcodes a name or a bit.
[[cpp11::register]]
cpp11::list mdbx_flags_() {
  using namespace cpp11::literals;

  cpp11::writable::strings flag, scope;
  cpp11::writable::logicals settable, runtime;

  for (const mdbx_r::flag_entry &entry : mdbx_r::env_flags) {
    flag.push_back(entry.name);
    scope.push_back("env");
    settable.push_back(entry.settable);
    runtime.push_back(entry.runtime);
  }

  for (const mdbx_r::flag_entry &entry : mdbx_r::txn_flags) {
    flag.push_back(entry.name);
    scope.push_back("txn");
    settable.push_back(entry.settable);
    runtime.push_back(entry.runtime);
  }

  return cpp11::writable::list({"flag"_nm = flag, "scope"_nm = scope,
                                "settable"_nm = settable,
                                "runtime"_nm = runtime});
}

// Every flag actually in effect, including the ones mdbx_env_open() sets from
// its own arguments -- this reports the environment, not the call that made it.
[[cpp11::register]]
cpp11::strings mdbx_env_get_flags_(cpp11::sexp env) {
  mdbx_r::flags_context context = {mdbx_r::env_from_sexp(env), 0, false,
                                   MDBX_SUCCESS};

  mdbx_r::guard(mdbx_r::get_flags_call, &context, mdbx_r::poison_flags);
  mdbx_r::check(context.rc);

  return mdbx_r::names_from(context.bits);
}

[[cpp11::register]]
void mdbx_env_set_flags_(cpp11::sexp env, cpp11::strings flags, bool on) {
  mdbx_r::env_handle *handle = mdbx_r::env_from_sexp(env);

  // libmdbx serializes flag changes on a mutex and returns MDBX_BUSY when
  // called from within a write transaction. Refusing here says why, and keeps
  // the rule the rest of the package follows: lifecycle changes happen between
  // transactions, never during one.
  if (!handle->live_txns.empty())
    cpp11::stop("cannot change flags while a transaction is open on this mdbx "
                "environment; commit or abort it first");

  mdbx_r::flags_context context = {handle, mdbx_r::env_flags_from_names(flags),
                                   on, MDBX_SUCCESS};

  mdbx_r::guard(mdbx_r::set_flags_call, &context, mdbx_r::poison_flags);
  mdbx_r::check(context.rc);
}

// Returns TRUE if there was unsynced data and it was written, FALSE if there
// was nothing pending. MDBX_RESULT_TRUE (-1) reports the latter and is a
// success, so it must not reach check().
[[cpp11::register]]
bool mdbx_env_sync_(cpp11::sexp env, bool force, bool nonblock) {
  mdbx_r::sync_context context = {mdbx_r::env_from_sexp(env), force, nonblock,
                                  MDBX_SUCCESS};

  mdbx_r::guard(mdbx_r::sync_call, &context, mdbx_r::poison_sync);

  if (context.rc == MDBX_RESULT_TRUE)
    return false;

  mdbx_r::check(context.rc);
  return true;
}
