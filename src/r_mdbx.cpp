#include <algorithm>
#include <cctype>
#include <cstdint>
#include <thread>
#include <cstdio>
#include <cstring>
#include <vector>
#include <memory>
#include <string>

#include "r_mdbx.h"

#ifdef _WIN32
#include <process.h>
#else
#include <sys/stat.h>
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

// The same question for transactions, and for the same reason.
//
// The S3 class is not an identity: `class(env) <- "mdbx_txn"` is enough to
// hand an env_handle to code that will read it as a txn_handle. The two
// structs are both EXTPTRSXP and neither layout is a prefix of the other, so
// that is type confusion -- mdbx_txn_state() answered "aborted" for it, having
// read the environment's pid where a txn_state belongs. Only the tag, which R
// cannot set, tells them apart.
bool is_txn_sexp(SEXP x) {
  return TYPEOF(x) == EXTPTRSXP && Rf_inherits(x, "mdbx_txn") &&
         R_ExternalPtrTag(x) == txn_tag();
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

// Every environment this process currently has open.
//
// libmdbx documents opening an environment more than once from a single
// process as an error, and reports it as whatever the lock file's own failure
// happened to be -- EAGAIN on macOS, and not necessarily that on another
// platform. Neither the code nor the message says what went wrong, so the
// conflict is detected here instead and named before libmdbx is reached.
//
// Entries are added once an open has succeeded and removed as soon as the
// handle's environment is closed, by either the explicit close or the
// finalizer, so a path reappears the moment reopening it would work -- with
// the one exception poisoned_keys below records.
std::vector<env_handle *> open_envs;

// The keys of environments a libmdbx panic poisoned and that were then
// detached without being closed.
//
// close_handle() deliberately does not hand a poisoned environment back to
// libmdbx: re-entering it to close a handle whose invariants it has already
// rejected is how a bad situation becomes a crash. Nothing else releases the
// lock file, the reader slot or the file descriptors either, so they stay held
// until the process ends -- and the path stays unopenable for just as long.
//
// The handle that used to say so is gone by then, freed by the finalizer, so
// the fact has to outlive it. A key is a string and does. Without this an open
// aimed at that path passes the registry and reaches libmdbx, which fails on
// the lock file with a bare errno -- `mdbx error 35` on macOS -- or, on a
// platform whose lock blocks rather than fails, hangs the session. That is the
// exact failure the registry exists to make unreachable.
// Recorded with the pid that poisoned them, for the same reason find_open_env()
// filters by one: a forked child holds none of the parent's libmdbx state and
// none of its locks, so a path the parent lost is one the child may open.
struct poisoned_path {
  std::string identity;
  std::string path;
  long pid;
};

std::vector<poisoned_path> poisoned_keys;

bool keys_match(const std::string &identity, const std::string &path,
                const env_keys &wanted) {
  // Identity first, and only when both sides have one: it is the answer that
  // sees through a hard link. The path catches what identity cannot, which is
  // an incumbent whose data file has since been unlinked or replaced -- either
  // way libmdbx still holds the lock file named after that path.
  if (!identity.empty() && !wanted.identity.empty() &&
      identity == wanted.identity)
    return true;
  return !path.empty() && path == wanted.path;
}

bool key_is_poisoned(const env_keys &wanted) {
  const long pid = current_pid();
  for (const poisoned_path &entry : poisoned_keys) {
    if (entry.pid == pid && keys_match(entry.identity, entry.path, wanted))
      return true;
  }
  return false;
}

void retain_poisoned_keys(const std::string &identity, const std::string &path) {
  if (identity.empty() && path.empty())
    return;
  poisoned_keys.push_back(poisoned_path{identity, path, current_pid()});
}

void retain_poisoned_handle(const env_handle *handle) {
  retain_poisoned_keys(handle->key, handle->path_key);
}

void register_env(env_handle *handle) { open_envs.push_back(handle); }

void unregister_env(env_handle *handle) {
  open_envs.erase(std::remove(open_envs.begin(), open_envs.end(), handle),
                  open_envs.end());
}

// The open handle matching `wanted`, or null. See env_keys_for() for what makes
// two spellings of one environment arrive here as the same key.
//
// Entries inherited across a fork() are skipped: the vector is copied into the
// child along with everything else, but the environments it names belong to
// the parent, and the child is entitled to open them itself.
env_handle *find_open_env(const env_keys &wanted) {
  for (env_handle *handle : open_envs) {
    if (handle->pid == current_pid() &&
        keys_match(handle->key, handle->path_key, wanted))
      return handle;
  }
  return nullptr;
}

// The file's identity as the filesystem knows it, or false if it has none --
// which for our purposes means it does not exist.
#ifdef _WIN32
bool file_identity(const std::string &path, std::string &out) {
  // R hands paths over as UTF-8, which the ...A entry points would read in the
  // active code page instead.
  const int wide_size =
      MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
  if (wide_size <= 0)
    return false;

  std::vector<wchar_t> wide(static_cast<size_t>(wide_size));
  if (MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, wide.data(),
                          wide_size) <= 0)
    return false;

  // No access is requested: the metadata below needs a handle, not a readable
  // file, and asking for nothing cannot disturb the open libmdbx already holds
  // on an incumbent environment. BACKUP_SEMANTICS lets the same call answer for
  // a directory, which a misspelled single-file path can name.
  HANDLE file = CreateFileW(
      wide.data(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (file == INVALID_HANDLE_VALUE)
    return false;

  BY_HANDLE_FILE_INFORMATION info;
  const BOOL ok = GetFileInformationByHandle(file, &info);
  CloseHandle(file);
  if (!ok)
    return false;

  // A file index of zero means the filesystem does not keep one -- FAT and
  // exFAT do not, and some network redirectors do not either. Reporting it as
  // an identity would give every file on such a volume the same key, and the
  // first environment opened there would refuse every later one as itself.
  // Say there is no identity instead and let the caller key by path: that is
  // no worse than this function not existing, which is what it was before.
  if (info.nFileIndexHigh == 0 && info.nFileIndexLow == 0)
    return false;

  char buffer[80];
  std::snprintf(buffer, sizeof buffer, "id:%lu:%lu:%lu",
                static_cast<unsigned long>(info.dwVolumeSerialNumber),
                static_cast<unsigned long>(info.nFileIndexHigh),
                static_cast<unsigned long>(info.nFileIndexLow));
  out = buffer;
  return true;
}
#else
bool file_identity(const std::string &path, std::string &out) {
  struct stat info;
  if (stat(path.c_str(), &info) != 0)
    return false;

  char buffer[80];
  std::snprintf(buffer, sizeof buffer, "id:%ju:%ju",
                static_cast<uintmax_t>(info.st_dev),
                static_cast<uintmax_t>(info.st_ino));
  out = buffer;
  return true;
}
#endif

} // namespace

// How an environment is known to the open registry, given the spelling of its
// data file that env_key() in R/env.R worked out.
//
// Two names for one environment have to land on the same key, because opening
// an environment twice in a process does not fail -- it hangs. libmdbx
// coordinates through a lock file named after the path, so a second name gets a
// second lock file and then blocks on a lock the first open holds, in this same
// single-threaded process, which therefore can never reach the call that would
// release it.
//
// Canonicalising the spelling is not enough for that. normalizePath() resolves
// `.`, `..` and symlinks, but a hard link is not a spelling of another path: it
// is an equal name for one inode, and no amount of string work relates the two.
// So the key is the file's identity where the filesystem can supply it --
// (device, inode) on POSIX, (volume, file index) on Windows -- and the
// canonical spelling only where it cannot, which is a data file that does not
// exist yet.
//
// So both are kept, and a match on either is a match. Identity alone is not
// enough, because it is not stable against the file going away: unlink an open
// environment's data file and stat() can no longer answer for that path, so an
// open aimed at it would miss an incumbent keyed by identity and reach libmdbx
// -- which still holds the lock file named after the path, and blocks on it
// forever in this same single-threaded process. The lock file is named after
// the path, so the path has to be a key.
//
// Matching on the path as well is right even when the file really has been
// replaced rather than merely unlinked: the replacement would share the
// incumbent's lock file, which is a genuine conflict and not a false one.
//
// A filesystem that keeps no file index -- FAT and exFAT do not, and nor do
// some network redirectors -- supplies no identity at all, and there the path
// key is the only one. That is exactly the keying this had before identity:
// equal for equal spellings, blind to links, which those filesystems do not
// have anyway.
//
// Identity is not knowable before the file exists, so an environment created by
// its own open is keyed from the spelling for the registry check and re-keyed
// from the file once the open has made one. The key is compared, never shown --
// the refusal prints the paths the caller and the incumbent wrote.
env_keys env_keys_for(const std::string &spelling) {
  env_keys keys;
  std::string identity;
  if (file_identity(spelling, identity))
    keys.identity = identity;
  keys.path = "path:" + spelling;
  return keys;
}

namespace {

[[noreturn]] void stop_after_panic(const mdbx_r_panic_info &panic) {
  cpp11::stop("libmdbx assertion failed: %s (%s:%u)", panic.message,
              panic.function, panic.line);
}

} // namespace

namespace {

// The MDBX status codes that have a symbolic name, and it.
//
// mdbx_strerror() already prefixes its own statuses with the name, but only
// inside the message -- and libmdbx passes system errno values through
// untouched, which have no MDBX name at all. The table is what lets a
// condition carry the name as a field instead, so that handling MDBX_BUSY does
// not mean matching English text.
struct error_entry {
  const char *name;
  int code;
};

const error_entry error_table[] = {
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

const char *error_name(int rc) {
  for (const auto &entry : error_table) {
    if (entry.code == rc)
      return entry.name;
  }
  return nullptr;
}

// "MDBX_BUSY" -> "mdbx_busy", the condition's most specific class.
std::string subclass_of(const char *name) {
  std::string out(name);
  for (char &c : out)
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return out;
}

} // namespace

void check(int rc) {
  if (rc == MDBX_SUCCESS)
    return;

  using namespace cpp11::literals;

  const char *name = error_name(rc);

  // The message is unchanged: it is what a user reads, and the tests and the
  // documentation both quote it. The code and the name are additions.
  char message[512];
  std::snprintf(message, sizeof(message), "%s (mdbx error %d)",
                mdbx_strerror(rc), rc);

  cpp11::writable::list condition(
      {"message"_nm = std::string(message), "call"_nm = cpp11::sexp(R_NilValue),
       "code"_nm = rc,
       "name"_nm = name ? cpp11::writable::strings({std::string(name)})
                        : cpp11::writable::strings({NA_STRING})});

  cpp11::writable::strings classes;
  if (name != nullptr)
    classes.push_back(subclass_of(name));
  classes.push_back("mdbx_error");
  classes.push_back("error");
  classes.push_back("condition");
  condition.attr("class") = classes;

  // Signalled through base::stop() rather than Rf_error(), so the structured
  // fields survive: cpp11::stop() formats a string and loses them. cpp11
  // routes the call through R_UnwindProtect, so the R jump resumes at the
  // .Call() boundary with C++ destructors run.
  cpp11::package("base")["stop"](condition);

  cpp11::stop("%s", message); // not reached; base::stop() does not return
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

// Test-only fault injection: make the next guarded open or close raise a
// libmdbx panic.
//
// Both panics are otherwise unreachable from R -- libmdbx has to violate an
// invariant inside mdbx_env_open() or mdbx_env_close() for real -- and both
// leave this package holding an environment whose path it must go on claiming.
// A regression test needs to reach them, so the flags exist; each is consumed
// by the call it fires, and nothing outside the suite ever sets one.
bool panic_next_open = false;

// Aimed at one environment rather than armed for "the next close".
//
// A global flag is eaten by whichever close_call runs first, and close_call is
// reached from the environment finalizer as well as from mdbx_env_close() -- so
// any GC between arming and closing hands the panic to an unrelated environment
// the suite had abandoned, poisons it, claims its path, and leaves the intended
// close to return normally. The suite abandons environments constantly by
// design, and R may collect at any allocation.
env_handle *panic_close_target = nullptr;

} // namespace

void arm_open_panic() { panic_next_open = true; }

void arm_close_panic(env_handle *handle) { panic_close_target = handle; }

namespace {

void open_call(void *data) {
  open_context *context = static_cast<open_context *>(data);

  if (panic_next_open) {
    panic_next_open = false;
    mdbx_r_panic("open-guard test", "open_call", 1);
  }

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

  if (panic_close_target != nullptr && context->handle == panic_close_target) {
    panic_close_target = nullptr;
    mdbx_r_panic("close-guard test", "close_call", 1);
  }

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
//
// Every transaction-backed poison callback goes through this. Poisoning only
// the transaction used to leave the environment believing itself healthy: the
// transaction's finalizer skips the native abort a poisoned handle must not
// make, unregisters itself, and the next mdbx_env_close() then hands libmdbx
// an environment whose transaction it never ended -- the exact UB the live
// transaction registry exists to make unreachable.
void poison_txn(txn_handle *handle) {
  handle->poisoned = true;
  if (handle->owner != nullptr)
    handle->owner->poisoned = true;
}

void poison_begin(void *data) {
  static_cast<begin_context *>(data)->owner->poisoned = true;
}

void poison_finish(void *data) {
  poison_txn(static_cast<finish_context *>(data)->handle);
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
  poison_txn(static_cast<dbi_context *>(data)->handle);
}

void poison_get(void *data) {
  poison_txn(static_cast<get_context *>(data)->handle);
}

void poison_put(void *data) {
  poison_txn(static_cast<put_context *>(data)->handle);
}

void poison_del(void *data) {
  poison_txn(static_cast<del_context *>(data)->handle);
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
  poison_txn(static_cast<scan_context *>(data)->handle);
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
  mdbx_r::poison_txn(static_cast<dbi_stat_context *>(data)->handle);
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

  // Every path below detaches the environment from the handle, so the path it
  // occupied is free from here on however this call ends.
  unregister_env(handle);

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
  //
  // Which means libmdbx never learns to release the lock file, and the path
  // stays taken for the life of the process. unregister_env() above has already
  // given it up, so record the key separately -- see poisoned_keys.
  if (handle->poisoned) {
    retain_poisoned_handle(handle);
    handle->env = nullptr;
    return;
  }

  close_context context = {handle, MDBX_SUCCESS};
  mdbx_r_panic_info panic = {};
  mdbx_r_guard_result result =
      mdbx_r_run_guarded(close_call, &context, poison_close, &panic);

  // A panic raised by the close itself, rather than one that arrived before it.
  // libmdbx's state is then unknown -- it may have released the file, it may
  // not, and there is no second call that could make it certain, because
  // calling back into a panicked libmdbx is the thing this package will not do.
  // unregister_env() has already given the path up, so claim it: reporting it
  // free is the answer that ends in a bare errno or a hang. Unconditional,
  // because the finalizer reaches here too and a GC-time panic loses the path
  // just as thoroughly as an explicit close does.
  if (result != MDBX_R_GUARD_OK)
    retain_poisoned_handle(handle);

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

// A name for this particular open, distinct from every other open this process
// makes. It travels env -> txn -> mdbx_dbi, so that a database handle can be
// matched against the environment it was opened in.
//
// The path cannot do that job. An environment can be closed, its files deleted
// and another created at the same path, and a database handle from before that
// must not go on addressing the same-named database in the replacement -- they
// have nothing to do with each other. A counter is enough to tell them apart:
// handles do not survive fork() and are never serialised, so the token only has
// to be unique among the opens of one process.
std::string next_env_token() {
  static uint64_t counter = 0;

  char buffer[32];
  std::snprintf(buffer, sizeof buffer, "%llu",
                static_cast<unsigned long long>(++counter));
  return buffer;
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
  Rf_setAttrib(ptr, Rf_install("token"),
               Rf_mkString(next_env_token().c_str()));
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
  // Both copied from the environment so R code can reach them without the
  // protected field, which it cannot read: the path so print() can name the
  // environment, the token so db_name() can recognise it.
  Rf_setAttrib(ptr, Rf_install("path"),
               Rf_getAttrib(env_sexp, Rf_install("path")));
  Rf_setAttrib(ptr, Rf_install("token"),
               Rf_getAttrib(env_sexp, Rf_install("token")));
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
  if (!is_txn_sexp(x))
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
cpp11::sexp mdbx_env_open_(std::string path, std::string spelling, bool readonly,
                           bool subdir, double max_dbs, double map_size,
                           double max_readers, int mode,
                           cpp11::strings extra_flags) {
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

  // libmdbx would report the lock file's own failure -- EAGAIN, MDBX_BUSY or
  // whatever the platform raises -- none of which says what happened. Name it.
  //
  // The incumbent's own spelling goes in the message when it differs from the
  // one being refused: the caller matched it on the canonical key, so without
  // it they are told that a path they did not write is already open.
  const mdbx_r::env_keys keys = mdbx_r::env_keys_for(spelling);

  // Poisoned and already detached: libmdbx still holds the file and nothing
  // will ever make it let go, so say that rather than let the open reach the
  // lock file. No handle survives to be offered as the alternative.
  if (mdbx_r::key_is_poisoned(keys))
    cpp11::stop("mdbx environment '%s' cannot be opened: a libmdbx assertion "
                "failure left an earlier handle for it unusable, and libmdbx "
                "still holds the file for as long as this process lives. Start "
                "a new R session to reach it again",
                path.c_str());

  if (mdbx_r::env_handle *incumbent = mdbx_r::find_open_env(keys)) {
    // Poisoned but still held. "Use the existing handle" would be impossible
    // advice -- every operation on it refuses -- and closing it does not free
    // the path either, so neither half of the ordinary refusal applies.
    if (incumbent->poisoned)
      cpp11::stop("mdbx environment '%s' cannot be opened: a libmdbx assertion "
                  "failure left the handle this process holds for it unusable, "
                  "and libmdbx still holds the file for as long as this process "
                  "lives. Start a new R session to reach it again",
                  path.c_str());

    if (incumbent->path == path)
      cpp11::stop("mdbx environment '%s' is already open in this process; use "
                  "the existing handle, or close it before opening it again",
                  path.c_str());
    cpp11::stop("mdbx environment '%s' is already open in this process, as "
                "'%s'; use the existing handle, or close it before opening it "
                "again",
                path.c_str(), incumbent->path.c_str());
  }

  // The handle is allocated before the external pointer so that a failure to
  // open leaves nothing for R to reclaim; on success it is handed straight to
  // an external pointer with a finalizer.
  // Owned here until the external pointer takes it over. Both failure paths
  // below leave through a thrown R condition, so unwinding frees the handle --
  // no manual delete, and no path on which a later statement could reach a
  // freed handle.
  std::unique_ptr<mdbx_r::env_handle> handle(
      new mdbx_r::env_handle{nullptr, false, mdbx_r::current_pid()});

  // Keyed before the open rather than after it, so that every way out of this
  // function can claim the path. The cleanup close below runs on a handle whose
  // keys would otherwise still be empty, and if that close panics it has
  // nothing to record. Re-keyed on success, where the identity finally exists.
  handle->key = keys.identity;
  handle->path_key = keys.path;
  handle->path = path;

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

  // Poisoned mid-open: the partially built env is deliberately not closed, and
  // the unique_ptr below frees only the handle struct -- so if libmdbx took the
  // lock file before it panicked, it holds it for the life of the process with
  // nothing left pointing at it.
  //
  // Claim the path on the way out, under the keys computed before the attempt
  // and under the identity the data file it may just have created now yields --
  // creating the file changes which identity a later open computes.
  if (result != MDBX_R_GUARD_OK) {
    mdbx_r::retain_poisoned_keys(keys.identity, keys.path);
    mdbx_r::retain_poisoned_keys(mdbx_r::env_keys_for(spelling).identity,
                                 std::string());
    mdbx_r::stop_after_panic(panic);
  }

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

  // Re-keyed now rather than keeping the one the check above was made with: an
  // environment this call created had no identity until the open put its data
  // file on disk. The path key does not change.
  handle->key = mdbx_r::env_keys_for(spelling).identity;

  // Registered only once the external pointer exists, so that a failure to
  // build it cannot leave the registry holding an address nothing will free.
  mdbx_r::env_handle *raw = handle.release();
  cpp11::sexp env = mdbx_r::new_env_sexp(raw, path, readonly, actual_subdir);
  mdbx_r::register_env(raw);

  return env;
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

  // The fork check comes first, before anything below touches the handle.
  //
  // A child that inherited this environment can do nothing with it, so the
  // refusal it gets should say that -- not the live-transaction complaint below,
  // which would tell it to commit or abort transactions every entry point
  // refuses it by pid. And detaching first would be worse than a bad message:
  // detach_txns() rewrites the transaction handles in this process's copy, so
  // the child's own later mdbx_txn_abort() would find a handle already marked
  // finished and return silently, instead of naming the fork the way every
  // other entry point does.
  if (handle->pid != mdbx_r::current_pid()) {
    mdbx_r::close_handle(handle, true);
    return;
  }

  // A poisoned environment is never handed back to libmdbx, so its registered
  // transactions cannot be ended the ordinary way either -- and refusing on
  // their account would leave no way to release the environment at all.
  // detach_txns() invalidates them without calling libmdbx, which is what it
  // already does for this case when the finalizer runs.
  if (handle->poisoned)
    mdbx_r::detach_txns(handle);

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
  if (!mdbx_r::is_txn_sexp(txn))
    cpp11::stop("expected an 'mdbx_txn' object");

  mdbx_r::txn_handle *handle =
      static_cast<mdbx_r::txn_handle *>(R_ExternalPtrAddr(txn));

  if (handle == nullptr || handle->txn == nullptr)
    return;

  // A poisoned ownership graph is ended here rather than in libmdbx, which
  // must not be re-entered once it has rejected its own invariants.
  //
  // Refusing instead is what made a panic unrecoverable: the transaction could
  // not be aborted because its environment was poisoned, and the environment
  // could not be closed because the transaction was still registered, so
  // nothing short of dropping both references and forcing a GC released the
  // handle. Worse, abort is how mdbx_with_read() and mdbx_with_write() clean
  // up on the way out, so the refusal was raised from on.exit() and replaced
  // the panic that caused it -- destroying the only message that said what
  // libmdbx had actually found.
  //
  // A handle from another process is not covered: it belongs to the parent,
  // and finish_txn() refuses it by name.
  //
  // Of the four disjuncts only the two `poisoned` ones can fire as the code
  // stands, and it is worth saying why rather than leaving the next reader to
  // re-derive it. `owner == nullptr` cannot: mark_finished() and detach_txns()
  // are the only writers of it, and both null `txn` alongside, which the return
  // above has already excluded. `owner->env == nullptr` cannot either, because
  // the paths that clear it -- the finalizer, and an explicit close -- either
  // run detach_txns() first or belong to a child process, and the pid conjunct
  // excludes the child. They are kept as belt and braces all the same: every
  // one of them describes an ownership graph this transaction must not be
  // handed to libmdbx under, and the cost of testing them is nothing next to
  // the cost of being wrong about which states are reachable.
  if (handle->pid == mdbx_r::current_pid() &&
      (handle->poisoned || handle->owner == nullptr ||
       handle->owner->env == nullptr || handle->owner->poisoned)) {
    mdbx_r::mark_finished(handle, mdbx_r::txn_state::aborted);
    R_SetExternalPtrProtected(txn, R_NilValue);
    return;
  }

  finish_txn(txn, false);
}

namespace {

struct flags_context {
  mdbx_r::txn_handle *handle;
  unsigned flags;
};

void flags_call(void *data) {
  flags_context *context = static_cast<flags_context *>(data);
  context->flags =
      static_cast<unsigned>(mdbx_txn_flags(context->handle->txn));
}

void poison_flags(void *data) {
  mdbx_r::poison_txn(static_cast<flags_context *>(data)->handle);
}

// Whether libmdbx has marked this transaction errored -- MDBX_MAP_FULL above
// all. Every later operation on one then fails with MDBX_BAD_TXN, and its
// commit reports a rollback.
//
// Routed through guard() like every other libmdbx call that touches a
// transaction. ASSERT() inside mdbx_txn_flags() compiles out at this package's
// MDBX_CHECKING, so an unguarded call is not reachable in the shipped build --
// but a vendor bump, a sanitizer leg or MDBX_FORCE_ASSERTIONS would make it so,
// and a panic arriving with no poison callback leaves neither the transaction
// nor the environment marked. The environment's finalizer would then re-enter
// libmdbx to close a handle whose invariants had already failed.
bool txn_has_error(mdbx_r::txn_handle *handle) {
  if (handle == nullptr || handle->txn == nullptr)
    return false;

  flags_context context = {handle, 0};
  mdbx_r::guard(flags_call, &context, poison_flags);
  return (context.flags & MDBX_TXN_ERROR) != 0;
}

} // namespace

[[cpp11::register]]
std::string mdbx_txn_state_(cpp11::sexp txn) {
  if (!mdbx_r::is_txn_sexp(txn))
    cpp11::stop("expected an 'mdbx_txn' object");

  mdbx_r::txn_handle *handle =
      static_cast<mdbx_r::txn_handle *>(R_ExternalPtrAddr(txn));

  // What this reports is whether the transaction can still be used, not
  // whether its native handle happens to be allocated. The three answers below
  // each replace an "active" that was true of the binding's own bookkeeping
  // and false of everything the caller could do with it.
  if (handle == nullptr)
    return "invalid";

  // Inherited across a fork(). Every operation refuses it, so it is no more
  // usable here than a reclaimed one.
  if (handle->pid != mdbx_r::current_pid())
    return "invalid";

  // Poisoned by a libmdbx assertion failure, in this transaction or in the
  // environment that owns it -- either way nothing may touch it again.
  //
  // Only while it is still live, though. Once it has been ended the terminal
  // state is the more useful answer, and it must not depend on which of the
  // two poison paths got there: an environment panic leaves the transaction's
  // own flag clear, so clearing `owner` during cleanup made that case read
  // "aborted" while a transaction-level panic still read "poisoned".
  if (handle->state == mdbx_r::txn_state::active &&
      (handle->poisoned ||
       (handle->owner != nullptr && handle->owner->poisoned)))
    return "poisoned";

  switch (handle->state) {
  case mdbx_r::txn_state::active:
    // "active" was the one thing a transaction libmdbx has errored is not.
    if (txn_has_error(handle))
      return "failed";
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

// Refuse a named database that does not exist.
//
// libmdbx answers this with MDBX_NOTFOUND, whose text is "No matching
// key/data pair found" -- which describes a lookup that never happened and
// reads like the missing-key result mdbx_get() reports as NULL. Say which
// database was wanted, in which environment, and what would have created it.
[[noreturn]] void stop_missing_dbi(mdbx_r::txn_handle *handle,
                                   const std::string &name) {
  // owner is non-null for any transaction txn_from_sexp() let through.
  cpp11::stop("named database '%s' does not exist in '%s'; pass create = TRUE "
              "inside a write transaction to create it",
              name.c_str(), handle->owner->path.c_str());
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

  // A `db` handle whose creating transaction aborted, or whose database has
  // since been dropped, arrives here rather than at mdbx_dbi_open_().
  if (context.rc == MDBX_NOTFOUND && name != nullptr)
    stop_missing_dbi(handle, *name);

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
// An errored transaction is skipped, so that an environment-level query is not
// answered with MDBX_BAD_TXN -- mdbx_env_stat(env) failed that way while
// mdbx_env_info(env) beside it succeeded, though the two are documented as
// reporting one snapshot and neither was asked about the transaction. Skipped
// means falling back to a null transaction, and both then report the last
// committed state, which is what an environment-level query means.
//
// Only a *write* transaction, though. Falling back to null is exactly what the
// paragraph above says must not happen while this thread holds a read
// transaction: libmdbx starts an internal read of its own and collides with
// the reader slot already taken. A write transaction holds no reader slot, so
// the internal read is free to proceed -- and a read transaction cannot carry
// MDBX_TXN_ERROR anyway, since nothing a read does sets it. If one ever could,
// reusing it and reporting MDBX_BAD_TXN is the lesser of the two failures, and
// the honest one.
MDBX_txn *current_txn(mdbx_r::env_handle *handle) {
  for (mdbx_r::txn_handle *txn : handle->live_txns) {
    if (txn->txn == nullptr)
      continue;
    if (txn->write && txn_has_error(txn))
      continue;
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

// Internal test hook: how many paths the open registry is holding. An entry
// left behind would refuse a reopen that libmdbx would have allowed, which is
// invisible until someone hits it -- so the suite asserts the count returns to
// where it started.
[[cpp11::register]]
int mdbx_env_open_count_() { return static_cast<int>(mdbx_r::open_envs.size()); }

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

  // Creating a database is a write. libmdbx would report a bare EACCES, the
  // same status writable_txn() already refuses to pass on for mdbx_put().
  //
  // libmdbx refuses on the flag, before it looks for the database, so this is
  // reached whether or not the database already exists. The message says the
  // flag needs a write transaction rather than that creation was impossible,
  // which would describe something the caller may not have asked for.
  if (create && !handle->write)
    cpp11::stop("create = TRUE needs a write transaction; this mdbx "
                "transaction is read-only, so begin one with write = TRUE, or "
                "pass create = FALSE to open a database that already exists");

  mdbx_r::dbi_context context = {
      handle, name.c_str(),
      static_cast<unsigned>(create ? MDBX_CREATE : MDBX_DB_DEFAULTS), 0,
      MDBX_SUCCESS};

  mdbx_r::guard(mdbx_r::dbi_call, &context, mdbx_r::poison_dbi);

  // Only reachable with create = FALSE: a write transaction asked to create
  // one does not come back empty-handed.
  if (context.rc == MDBX_NOTFOUND)
    stop_missing_dbi(handle, name);

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
  mdbx_r::poison_txn(static_cast<drop_context *>(data)->handle);
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
  mdbx_r::poison_txn(static_cast<sequence_context *>(data)->handle);
}

} // namespace

// Read, and optionally advance, a database's sequence counter.
[[cpp11::register]]
double mdbx_dbi_sequence_(cpp11::sexp txn, cpp11::strings db, double increment) {
  // Reading the counter is a read; advancing it is a write, and only that
  // half needs a write transaction. Checked before the read below rather than
  // after it, so the refusal cannot arrive with the counter already touched.
  mdbx_r::txn_handle *handle =
      increment > 0 ? writable_txn(txn) : mdbx_r::txn_from_sexp(txn);
  ensure_dbi(handle, db);

  // Read before deciding, so the range check below happens while nothing has
  // been mutated: erroring after a successful increment would leave the counter
  // advanced by an amount the caller never received.
  sequence_context context = {handle, 0, 0, MDBX_SUCCESS};
  mdbx_r::guard(sequence_call, &context, poison_sequence);
  mdbx_r::check(context.rc);

  // The counter is 64-bit in libmdbx but reaches R as a double, which holds
  // integers exactly only up to 2^53. Checked against the native value, before
  // the conversion that would round it: this binding will not advance a counter
  // past that bound, but another one sharing the database is under no such
  // rule, and a counter it left up there must not be reported as a number that
  // merely looks like it.
  if (context.result > static_cast<uint64_t>(mdbx_r::max_exact_integer)) {
    char exact[32];
    std::snprintf(exact, sizeof exact, "%llu",
                  static_cast<unsigned long long>(context.result));
    cpp11::stop("this sequence stands at %s, past 2^53 -- the largest integer "
                "R's numeric type holds exactly -- so it cannot be reported "
                "without rounding. Something other than this package advanced "
                "it there",
                exact);
  }

  const double current = static_cast<double>(context.result);

  if (increment <= 0)
    return current;

  // Two successive increments past 2^53 return the same number, and a sequence
  // documented as unique must refuse to continue rather than hand out
  // duplicates.
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

namespace {

struct count_context {
  mdbx_r::txn_handle *handle;
  int count;
  int rc;
};

int count_visit(void *ctx, const MDBX_txn *, const MDBX_val *,
                MDBX_db_flags_t, const struct MDBX_stat *,
                MDBX_dbi) MDBX_CXX17_NOEXCEPT {
  ++static_cast<count_context *>(ctx)->count;
  return 0;
}

void count_call(void *data) {
  count_context *context = static_cast<count_context *>(data);
  context->rc = mdbx_enumerate_tables(context->handle->txn, count_visit, context);
}

void poison_count(void *data) {
  mdbx_r::poison_txn(static_cast<count_context *>(data)->handle);
}

// How many named databases this transaction can see.
int count_named_tables(mdbx_r::txn_handle *handle) {
  count_context context = {handle, 0, MDBX_SUCCESS};
  mdbx_r::guard(count_call, &context, poison_count);
  mdbx_r::check(context.rc);
  return context.count;
}

} // namespace

// Empty a database, or delete it outright.
[[cpp11::register]]
void mdbx_dbi_drop_(cpp11::sexp txn, cpp11::strings db, bool del) {
  // Emptying and deleting are both writes, and libmdbx reports a read
  // transaction's refusal as a bare EACCES. mdbx_put() has always named it.
  mdbx_r::txn_handle *handle = writable_txn(txn);

  // Emptying the main database destroys every named database with it: a named
  // database *is* a record in the main tree, and mdbx_drop() purges the whole
  // tree. It cannot be made consistent afterwards either -- this transaction's
  // cached handles go on answering from purged trees, and libmdbx keeps its own
  // environment-level record of the name, so after the commit mdbx_dbi_open()
  // still succeeds for a database whose reads then fail with MDBX_BAD_DBI.
  // Repairing that would need mdbx_dbi_close(), which this package does not
  // call. So refuse while there is anything to lose.
  //
  // Checked here rather than in R, and after writable_txn() rather than before
  // it. In R the only available answer to "is this a write transaction" was the
  // `write` attribute on the external pointer, which R code can rewrite in
  // place -- so the guard could be switched off with `attr(txn, "write") <-
  // FALSE` and the purge went through. handle->write is the transaction's own.
  if (!del && db.size() == 0) {
    const int named = count_named_tables(handle);
    if (named > 0)
      cpp11::stop("emptying the main database would also destroy the %d named "
                  "database(s) in this environment, because each one is a "
                  "record in the main database. Drop them by name first if "
                  "that is what you want, or delete the main database's keys "
                  "individually",
                  named);
  }

  // The main database cannot be deleted -- it is where the named ones are
  // recorded, so an environment without it is not an environment. libmdbx does
  // not say so: mdbx_drop() empties the table, then returns success without
  // ever looking at `del` for a core DBI. The caller would be told that the
  // deletion they asked for had happened. Refuse before anything is emptied, so
  // that the refusal costs them nothing and `delete = FALSE` remains the way to
  // ask for what libmdbx would have done.
  if (del && db.size() == 0)
    cpp11::stop("the main database cannot be deleted, only emptied: it is what "
                "records the named databases. Use delete = FALSE to empty it");

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
  mdbx_r::poison_txn(static_cast<list_context *>(data)->handle);
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
  cpp11::writable::integers out;
  cpp11::writable::strings names;

  for (const auto &entry : mdbx_r::error_table) {
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

// Internal test hooks: arm the fault injection in open_call and close_call, so
// a panic raised *by* an open or a close -- as opposed to one that arrived
// before it -- can be driven through the real control flow of mdbx_env_open_()
// and close_handle(). Each flag is consumed by the call it fires.
//
// What they exist to catch: both paths leave libmdbx holding the file with
// nothing left pointing at it, so both have to claim the path on the way out.
// Neither did, and the registry then reported free a path the next open would
// have met a bare errno -- or a hang -- on.
[[cpp11::register]]
void mdbx_test_arm_open_panic_() { mdbx_r::arm_open_panic(); }

[[cpp11::register]]
void mdbx_test_arm_close_panic_(cpp11::sexp env) {
  mdbx_r::arm_close_panic(mdbx_r::env_from_sexp(env));
}

// Internal regression hook, as above but for a transaction operation: drive a
// panic through the guard mdbx_get() installs, using the real get_context and
// the real poison_get.
//
// Every transaction-backed callback used to poison the transaction alone,
// leaving the environment believing itself healthy -- so this asserts the
// owner comes back poisoned too, which is what keeps the environment's close
// from handing libmdbx a transaction that was never ended.
[[cpp11::register]]
void mdbx_test_panic_get_(cpp11::sexp txn) {
  mdbx_r::txn_handle *handle = mdbx_r::txn_from_sexp(txn);

  mdbx_r::get_context context = {handle, {nullptr, 0}, {nullptr, 0},
                                 MDBX_SUCCESS};
  mdbx_r::guard(panic_immediately, &context, mdbx_r::poison_get);
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
