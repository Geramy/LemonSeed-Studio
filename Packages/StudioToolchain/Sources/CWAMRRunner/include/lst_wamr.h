// In-process WASI runner on the WebAssembly Micro Runtime (fast interpreter).

#ifndef LST_WAMR_H
#define LST_WAMR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lst_wamr_session lst_wamr_session;

typedef struct lst_wamr_options {
  const uint8_t *wasm;      ///< module bytes (copied; the caller keeps ownership)
  size_t wasm_length;
  const char *const *argv;  ///< argv[0] is the program name
  int argc;
  const char *const *env;   ///< "KEY=value" strings
  int env_count;
  const char *preopen_dir;  ///< host directory mapped to "/" and ".", or NULL
  uint32_t stack_size;      ///< wasm operand stack; 0 means 256 KB
  uint32_t heap_size;       ///< app heap for the libc-less malloc; 0 is fine
  /// Host fd the program reads as stdin (fd 0), e.g. a pipe's read end; -1
  /// for none (end of file at once). Not closed by the runner.
  int stdin_fd;
  /// Nonzero: the program may open sockets to any address and resolve any
  /// name (WAMR's socket calls, the WASIX socket calls). iOS still applies
  /// its own rules (local network permission, no privileged ports).
  int allow_network;
  void *user;
  /// stdout (fd 1) and stderr (fd 2) bytes, from a reader thread.
  void (*output)(void *user, int fd, const char *data, size_t length);
} lst_wamr_options;

typedef struct lst_wamr_result {
  int exit_code;          ///< WASI exit code, or -1 if the module trapped
  double load_ms;         ///< parse and validate
  double instantiate_ms;
  double run_ms;
  char error[512];        ///< trap or load error, empty on success
} lst_wamr_result;

lst_wamr_session *lst_wamr_session_create(void);
/// Runs the module's _start to completion on the calling thread.
int lst_wamr_session_run(lst_wamr_session *session,
                         const lst_wamr_options *options,
                         lst_wamr_result *result);
/// Asks a running module to stop (safe from any thread).
void lst_wamr_session_terminate(lst_wamr_session *session);
void lst_wamr_session_destroy(lst_wamr_session *session);

/// "WAMR 2.4.5 fast-interp" or similar.
const char *lst_wamr_version(void);

#ifdef __cplusplus
}
#endif

#endif
