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

#ifndef CGITSHIM_LFS_H
#define CGITSHIM_LFS_H
#ifdef __cplusplus
extern "C" {
#endif

/*
 * Git LFS filter ("filter=lfs"). libgit2 does not run external filter
 * processes, so GitKit registers this native filter. It buffers a file and
 * hands it to `transform`:
 *
 *   to_odb = 1  clean:  working-tree content -> pointer text
 *   to_odb = 0  smudge: pointer text -> content from the local LFS store
 *
 * `git_dir` is the repository's .git directory. The callback returns 0 and
 * sets *out (malloc'd, freed by the filter) to replace the content, or
 * returns 0 with *out == NULL to pass the input through unchanged, or a
 * negative libgit2 error code to fail.
 */
typedef int (*lsg_lfs_transform_fn)(int to_odb, const char *git_dir, const char *path,
                                    const char *in, size_t in_len,
                                    char **out, size_t *out_len);

/* Registers the filter once per process (later calls only swap the callback). */
int lsg_lfs_filter_register(lsg_lfs_transform_fn transform);

#ifdef __cplusplus
}
#endif
#endif
