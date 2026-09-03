#ifndef R_MDBX_HOOKS_H
#define R_MDBX_HOOKS_H

#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MDBX_R_PANIC_MESSAGE_SIZE 256
#define MDBX_R_PANIC_FUNCTION_SIZE 128

typedef struct mdbx_r_panic_info {
  char message[MDBX_R_PANIC_MESSAGE_SIZE];
  char function[MDBX_R_PANIC_FUNCTION_SIZE];
  unsigned line;
} mdbx_r_panic_info;

typedef void (*mdbx_r_guarded_function)(void *data);
typedef void (*mdbx_r_poison_function)(void *data);

typedef enum mdbx_r_guard_result {
  MDBX_R_GUARD_OK = 0,
  MDBX_R_GUARD_PANIC = 1
} mdbx_r_guard_result;

/* Run a C-compatible libmdbx call below a package-owned jump boundary. If
 * libmdbx panics, the panic hook returns here rather than jumping across the
 * cpp11/C++ boundary. The optional poison callback runs before control returns
 * to C++.
 *
 * Guarded functions and poison callbacks must not call R or contain C++
 * objects whose destructors would be skipped by longjmp(). */
mdbx_r_guard_result mdbx_r_run_guarded(mdbx_r_guarded_function function,
                                       void *data,
                                       mdbx_r_poison_function poison,
                                       mdbx_r_panic_info *panic);

/* Set process-global libmdbx diagnostics to fatal-only. */
mdbx_r_guard_result mdbx_r_initialize(int *native_result,
                                      mdbx_r_panic_info *panic);

/* Internal test hook proving that poisoning precedes error translation. */
mdbx_r_guard_result mdbx_r_test_panic_boundary(int *poisoned,
                                               mdbx_r_panic_info *panic);

/* Called from the locally patched libmdbx amalgamation. */
void mdbx_r_log_va(const char *function, int line, const char *fmt,
                   va_list args);
void mdbx_r_panic(const char *msg, const char *func, unsigned line);

#ifdef __cplusplus
}
#endif

#endif
