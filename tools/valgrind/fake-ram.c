/* LD_PRELOAD shim for the valgrind CI leg: report FAKE_RAM_GB of physical
 * memory to sysconf(). Maintainer-only; tools/ is in .Rbuildignore.
 *
 * libmdbx sizes its default upper geometry from physical RAM (about 1.6x it),
 * so what a default-geometry mdbx_env_open() asks valgrind to map depends on
 * the machine. A GitHub runner's 16 GB stays under what valgrind can map;
 * CRAN's valgrind machine does not, and every default open there failed with
 * EINVAL (issue #30). This lets a small runner ask for what CRAN's machine
 * asks for. Nothing else about the process changes.
 *
 * Build: cc -shared -fPIC -O2 -o fake-ram.so fake-ram.c -ldl */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>

long sysconf(int name) {
  static long (*real)(int);
  if (real == NULL)
    real = (long (*)(int))dlsym(RTLD_NEXT, "sysconf");

  if (name == _SC_PHYS_PAGES || name == _SC_AVPHYS_PAGES) {
    const char *gb = getenv("FAKE_RAM_GB");
    if (gb != NULL && *gb != '\0')
      return (long)(atof(gb) * 1073741824.0 / (double)real(_SC_PAGESIZE));
  }
  return real(name);
}
