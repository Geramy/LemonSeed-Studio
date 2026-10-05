// WASIX on WAMR: the wasix_32v1 host calls, implemented over WAMR's own WASI
// and socket calls (so sockets are ordinary WASI file descriptors that
// fd_read, fd_write, poll_oneoff and fd_close handle) and its wasi-threads.

#ifndef LST_WASIX_H
#define LST_WASIX_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Registers the wasix_32v1 natives with WAMR. Call once, after the runtime
/// is initialized and before modules load. Returns false if WAMR lacks the
/// calls the shim is built on.
bool lst_wasix_register(void);

/// How each wasix_32v1 call is handled, for documentation and tests: one
/// "name:implemented" or "name:enosys" entry per line.
const char *lst_wasix_coverage(void);

#ifdef __cplusplus
}
#endif

#endif
