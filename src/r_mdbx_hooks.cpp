/* R-side hooks and protected-call boundary for the patched libmdbx
 * amalgamation.
 *
 * libmdbx's own panic and logging paths write to stderr and call the platform
 * assert handler / abort(), both of which would terminate the R session and are
 * flagged by `R CMD check`. src/vendor/libmdbx/mdbx.c is patched to call these
 * two functions instead; the patch is recorded in .agents/patch.md.
 *
 * This file is part of the R/C++ boundary. Its functions have C linkage via
 * r_mdbx_hooks.h, so the vendored mdbx.c can call them directly. */

#include <R_ext/Error.h>
#include <R_ext/Print.h>

#include <setjmp.h>

#include "mdbx.h"
#include "r_mdbx_hooks.h"

#if defined(_MSC_VER)
#define MDBX_R_THREAD_LOCAL __declspec(thread)
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define MDBX_R_THREAD_LOCAL _Thread_local
#elif defined(__GNUC__) || defined(__clang__)
#define MDBX_R_THREAD_LOCAL __thread
#else
#error "mdbx requires thread-local storage for panic containment"
#endif

typedef struct mdbx_r_guard_frame {
  struct mdbx_r_guard_frame *previous;
  jmp_buf destination;
} mdbx_r_guard_frame;

static MDBX_R_THREAD_LOCAL mdbx_r_guard_frame *mdbx_r_active_guard;
static MDBX_R_THREAD_LOCAL mdbx_r_panic_info mdbx_r_last_panic;

static void mdbx_r_copy_text(char *destination, size_t size,
                             const char *source) {
  size_t index = 0;

  if (size == 0)
    return;

  if (source != NULL) {
    while (index + 1 < size && source[index] != '\0') {
      destination[index] = source[index];
      ++index;
    }
  }

  destination[index] = '\0';
}

mdbx_r_guard_result mdbx_r_run_guarded(mdbx_r_guarded_function function,
                                       void *data,
                                       mdbx_r_poison_function poison,
                                       mdbx_r_panic_info *panic) {
  mdbx_r_guard_frame frame = {0};

  frame.previous = mdbx_r_active_guard;
  mdbx_r_active_guard = &frame;

  if (setjmp(frame.destination) == 0) {
    function(data);
    mdbx_r_active_guard = frame.previous;
    return MDBX_R_GUARD_OK;
  }

  mdbx_r_active_guard = frame.previous;

  if (poison != NULL)
    poison(data);
  if (panic != NULL)
    *panic = mdbx_r_last_panic;

  return MDBX_R_GUARD_PANIC;
}

/* Replaces the fprintf(stderr, ...) fallback in debug_log_va(), used when no
 * logger callback has been installed via mdbx_setup_debug(). */
void mdbx_r_log_va(const char *function, int line, const char *fmt, va_list args) {
  if (function && line > 0)
    REprintf("%s:%d ", function, line);
  else if (function)
    REprintf("%s: ", function);
  else if (line > 0)
    REprintf("%d: ", line);

  REvprintf(fmt, args);
}

/* Replaces the body of osal_panic(). A guarded call records the panic and
 * jumps to the package-owned boundary below C++. The direct Rf_error fallback
 * is reserved for an unexpected panic outside a package invocation, such as
 * failure during native-library initialization. */
void mdbx_r_panic(const char *msg, const char *func, unsigned line) {
  if (mdbx_r_active_guard != NULL) {
    mdbx_r_copy_text(mdbx_r_last_panic.message,
                     sizeof(mdbx_r_last_panic.message),
                     msg ? msg : "(unknown assertion)");
    mdbx_r_copy_text(mdbx_r_last_panic.function,
                     sizeof(mdbx_r_last_panic.function),
                     func ? func : "(unknown function)");
    mdbx_r_last_panic.line = line;
    longjmp(mdbx_r_active_guard->destination, 1);
  }

  Rf_error("libmdbx assertion failed: %s (%s:%u)", msg ? msg : "(unknown assertion)",
           func ? func : "(unknown function)", line);
}

typedef struct mdbx_r_initialize_context {
  int result;
} mdbx_r_initialize_context;

static void mdbx_r_initialize_call(void *data) {
  mdbx_r_initialize_context *context = (mdbx_r_initialize_context *)data;
  context->result = mdbx_setup_debug(MDBX_LOG_FATAL, MDBX_DBG_NONE,
                                     MDBX_LOGGER_DONTCHANGE);
}

mdbx_r_guard_result mdbx_r_initialize(int *native_result,
                                      mdbx_r_panic_info *panic) {
  mdbx_r_initialize_context context = {-1};
  mdbx_r_guard_result result =
      mdbx_r_run_guarded(mdbx_r_initialize_call, &context, NULL, panic);

  if (native_result != NULL)
    *native_result = context.result;
  return result;
}

typedef struct mdbx_r_test_panic_context {
  int poisoned;
} mdbx_r_test_panic_context;

static void mdbx_r_test_panic_call(void *data) {
  (void)data;
  mdbx_r_panic("panic-boundary test", "mdbx_r_test_panic_call", 1);
}

static void mdbx_r_test_poison(void *data) {
  mdbx_r_test_panic_context *context = (mdbx_r_test_panic_context *)data;
  context->poisoned = 1;
}

mdbx_r_guard_result mdbx_r_test_panic_boundary(int *poisoned,
                                               mdbx_r_panic_info *panic) {
  mdbx_r_test_panic_context context = {0};
  mdbx_r_guard_result result = mdbx_r_run_guarded(
      mdbx_r_test_panic_call, &context, mdbx_r_test_poison, panic);

  if (poisoned != NULL)
    *poisoned = context.poisoned;
  return result;
}
