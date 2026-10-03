// Clangd memory spike: run clangd's ClangdServer in this process on one file
// and report time and memory. A measurement harness, not the ClangdHost API.

#ifndef CLANGD_SPIKE_H
#define CLANGD_SPIKE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lst_clangd_stats {
  int available;                   ///< 0 when built without clangd
  double first_build_ms;           ///< open -> idle (preamble, AST, diagnostics, index)
  double rebuild_ms;               ///< after an edit in the body (preamble reused)
  double completion_ms;            ///< code completion after "spike."
  int completion_items;
  int diagnostics;                 ///< diagnostics on the first build
  unsigned long long clangd_bytes; ///< clangd's own accounting (MemoryTree total)
  unsigned long long footprint_before;  ///< process phys_footprint, bytes
  unsigned long long footprint_open;    ///< with the file open and idle
  unsigned long long footprint_after;   ///< after the server is destroyed
  char breakdown[2048];            ///< MemoryTree, two levels, text
} lst_clangd_stats;

/// Opens `file` in a fresh ClangdServer configured with `flags` (fallback
/// compile flags), waits for it to go idle, edits it, completes, measures.
void lst_clangd_measure(const char *file, const char *const *flags, int flag_count,
                        int preambles_in_memory, lst_clangd_stats *out);

#ifdef __cplusplus
}
#endif

#endif
