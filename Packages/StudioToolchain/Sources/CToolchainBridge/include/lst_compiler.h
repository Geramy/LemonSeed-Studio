// C interface to the in-process clang driver, cc1 and wasm-ld.
//
// Nothing here spawns a process: the clang driver plans the jobs, then each
// cc1 job runs through clang's frontend in this thread and the link job runs
// through lld's wasm driver as a library.

#ifndef LST_COMPILER_H
#define LST_COMPILER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum lst_diag_level {
  LST_DIAG_NOTE = 0,
  LST_DIAG_REMARK = 1,
  LST_DIAG_WARNING = 2,
  LST_DIAG_ERROR = 3,
  LST_DIAG_FATAL = 4,
} lst_diag_level;

/// One structured diagnostic. Strings are valid only during the callback.
typedef struct lst_diagnostic {
  lst_diag_level level;
  const char *file;    ///< empty when the diagnostic has no location
  unsigned line;       ///< 1-based, 0 when unknown
  unsigned column;     ///< 1-based, 0 when unknown
  const char *message;
} lst_diagnostic;

typedef enum lst_stream {
  LST_STREAM_STDOUT = 1,
  LST_STREAM_STDERR = 2,
} lst_stream;

typedef struct lst_callbacks {
  void *user;
  /// Text a command-line clang would print (rendered diagnostics, -v output).
  void (*text)(void *user, lst_stream stream, const char *data, size_t length);
  /// Structured diagnostics for a Problems panel.
  void (*diagnostic)(void *user, const lst_diagnostic *diagnostic);
} lst_callbacks;

typedef struct lst_timings {
  double driver_ms;  ///< argument parsing and job planning
  double compile_ms; ///< all cc1 jobs
  double link_ms;    ///< wasm-ld
  int compile_jobs;
  int link_jobs;
} lst_timings;

/// Whether this build carries LLVM (0 when the package was built before the
/// LLVM XCFramework existed; every call then fails with a message).
int lst_toolchain_available(void);

/// "clang version 21.1.8 ..." or a message saying the toolchain is missing.
const char *lst_toolchain_version(void);

/// Runs a clang command line in process. argv[0] is treated as the path of
/// the clang executable (it need not exist; pass -resource-dir explicitly).
/// Returns the exit code clang would have returned. Thread-safe: compiles may
/// run in parallel, links are serialized. Run it on a thread with an 8 MB stack.
int lst_clang_main(int argc, const char *const *argv,
                   const lst_callbacks *callbacks, lst_timings *timings);

/// Runs wasm-ld directly (argv[0] should be "wasm-ld"). Serialized.
int lst_wasm_ld_main(int argc, const char *const *argv,
                     const lst_callbacks *callbacks);

#ifdef __cplusplus
}
#endif

#endif
