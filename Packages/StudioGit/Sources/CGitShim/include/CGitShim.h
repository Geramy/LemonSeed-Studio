/*
 * CGitShim: non-variadic entry points over libgit2 for Swift.
 *
 * Swift cannot call C variadic functions such as git_libgit2_opts(), so the
 * global options GitKit needs are wrapped here one by one.
 */
#ifndef CGITSHIM_H
#define CGITSHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* PEM bundle OpenSSL checks server certificates against (NULL path keeps it). */
int lsg_set_ssl_cert_locations(const char *file, const char *path);
/* Connect and I/O timeouts in milliseconds (0 = libgit2 default). */
int lsg_set_server_timeouts(int connect_timeout_ms, int io_timeout_ms);
/* Repository ownership checks (safe.directory); off for app containers. */
int lsg_set_owner_validation(int enabled);
int lsg_set_user_agent(const char *user_agent);
/* Config search path for a level (GIT_CONFIG_LEVEL_*); NULL resets it. */
int lsg_set_search_path(int level, const char *path);
/* Upper bound for mmap'd pack windows, for the memory governor. */
int lsg_set_mwindow_mapped_limit(size_t bytes);
int lsg_set_mwindow_file_limit(size_t files);
/* Enable or disable strict object creation checks. */
int lsg_set_strict_object_creation(int enabled);

#ifdef __cplusplus
}
#endif

#endif
