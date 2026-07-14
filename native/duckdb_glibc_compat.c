/* glibc-compat shim for statically embedding a system-GCC-built DuckDB into a
 * Lean 4 executable.
 *
 * Lean's toolchain links against its own BUNDLED glibc, which is older than the
 * host glibc DuckDB was compiled against. A few symbols the DuckDB object (and
 * the whole-archived libstdc++) reference are therefore absent from Lean's
 * glibc. We supply them here as thin wrappers over functions Lean's glibc DOES
 * have, then localize them into the encapsulated DuckDB object so they never
 * collide with the real symbols in a newer glibc.
 *
 *   __isoc23_*          C23 scanf/strtol family (glibc >= 2.38). The only
 *                       behavioural difference from the classic functions is
 *                       recognition of the C23 "0b" binary prefix; DuckDB's
 *                       internal numeric parsing does not depend on it, so
 *                       delegating to the classic functions is faithful.
 *   pthread_cond_clockwait  glibc >= 2.30. Delegated to pthread_cond_timedwait
 *                       (both take an absolute timeout); the clock id is ignored
 *                       because DuckDB only ever passes CLOCK_REALTIME here.
 *   __libc_single_threaded  glibc >= 2.32 data symbol. Conservatively 0 (i.e.
 *                       "assume multi-threaded"): only ever disables an
 *                       optimization, never changes results.
 *
 * MUST be compiled `-std=gnu11` WITHOUT _GNU_SOURCE: under a C23 dialect (or with
 * _GNU_SOURCE) the host glibc headers redirect strtol/sscanf/... to the very
 * __isoc23_* symbols we define here, turning each wrapper into infinite
 * self-recursion. gnu11 without _GNU_SOURCE binds the classic symbols.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <pthread.h>
#include <time.h>

char __libc_single_threaded = 0;

int __isoc23_sscanf(const char *str, const char *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  int r = vsscanf(str, fmt, ap);
  va_end(ap);
  return r;
}
int __isoc23_vsscanf(const char *str, const char *fmt, va_list ap) {
  return vsscanf(str, fmt, ap);
}
int __isoc23_scanf(const char *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  int r = vscanf(fmt, ap);
  va_end(ap);
  return r;
}
int __isoc23_vscanf(const char *fmt, va_list ap) {
  return vscanf(fmt, ap);
}
int __isoc23_fscanf(FILE *stream, const char *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  int r = vfscanf(stream, fmt, ap);
  va_end(ap);
  return r;
}
int __isoc23_vfscanf(FILE *stream, const char *fmt, va_list ap) {
  return vfscanf(stream, fmt, ap);
}
long          __isoc23_strtol(const char *n, char **e, int b)   { return strtol(n, e, b); }
unsigned long __isoc23_strtoul(const char *n, char **e, int b)  { return strtoul(n, e, b); }
long long          __isoc23_strtoll(const char *n, char **e, int b)  { return strtoll(n, e, b); }
unsigned long long __isoc23_strtoull(const char *n, char **e, int b) { return strtoull(n, e, b); }

int pthread_cond_clockwait(pthread_cond_t *cond, pthread_mutex_t *mutex,
                           clockid_t clock_id, const struct timespec *abstime) {
  (void) clock_id;
  return pthread_cond_timedwait(cond, mutex, abstime);
}
