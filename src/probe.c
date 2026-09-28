#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
/* Writes into its argument in place -- the bug rcnst exists to catch. */
SEXP C_corrupt(SEXP x) { SET_STRING_ELT(x, 0, mkChar("corrupted")); return R_NilValue; }
static const R_CallMethodDef entries[] = {{"C_corrupt", (DL_FUNC) &C_corrupt, 1}, {NULL, NULL, 0}};
void R_init_cranprobe(DllInfo *dll) { R_registerRoutines(dll, NULL, entries, NULL, NULL); R_useDynamicSymbols(dll, FALSE); }
