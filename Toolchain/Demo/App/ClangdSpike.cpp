// See ClangdSpike.h. Compiled against the clangd headers staged by
// Toolchain/scripts/build-llvm-ios.sh; without them this is a stub.

#include "ClangdSpike.h"

#include <cstring>

#if __has_include(<lemonseed/llvm_config.h>)
#include <lemonseed/llvm_config.h>
#endif

#if LST_HAVE_LLVM && __has_include("ClangdServer.h")

#include "ClangdServer.h"
#include "CodeComplete.h"
#include "GlobalCompilationDatabase.h"
#include "Protocol.h"
#include "support/Logger.h"
#include "support/MemoryTree.h"
#include "support/ThreadsafeFS.h"

#include "llvm/Support/Allocator.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"

#include <mach/mach.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <future>
#include <string>
#include <vector>

using namespace clang::clangd;

namespace {

unsigned long long footprint() {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
    return 0;
  return info.phys_footprint;
}

double since(std::chrono::steady_clock::time_point t) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t).count();
}

struct Callbacks : ClangdServer::Callbacks {
  std::atomic<int> diagnostics{-1};
  void onDiagnosticsReady(PathRef, llvm::StringRef, llvm::ArrayRef<Diag> diags) override {
    diagnostics = static_cast<int>(diags.size());
  }
};

void describe(const MemoryTree &tree, const std::string &name, int depth, std::string &out) {
  if (depth > 0) {
    // Per-file nodes are named by absolute path; the file name is enough.
    std::string shown = name.substr(name.find_last_of('/') == std::string::npos ? 0 : name.find_last_of('/') + 1);
    char line[256];
    snprintf(line, sizeof line, "%*s%s: %.1f MB\n", (depth - 1) * 2, "", shown.c_str(),
             tree.total() / 1048576.0);
    out += line;
  }
  if (depth >= 3) return;
  std::vector<std::pair<std::string, const MemoryTree *>> kids;
  for (const auto &entry : tree.children())
    kids.emplace_back(entry.first.str(), &entry.second);
  std::sort(kids.begin(), kids.end(),
            [](auto &a, auto &b) { return a.second->total() > b.second->total(); });
  for (auto &[childName, child] : kids)
    if (child->total() >= 64 * 1024) describe(*child, childName, depth + 1, out);
}

} // namespace

extern "C" void lst_clangd_measure(const char *file, const char *const *flags, int flagCount,
                                   int preamblesInMemory, lst_clangd_stats *out) {
  memset(out, 0, sizeof *out);
  out->available = 1;
  out->footprint_before = footprint();

  auto buffer = llvm::MemoryBuffer::getFile(file);
  if (!buffer) {
    snprintf(out->breakdown, sizeof out->breakdown, "cannot read %s", file);
    return;
  }
  std::string contents = (*buffer)->getBuffer().str();

  StreamLogger logger(llvm::errs(), Logger::Error);
  LoggingSession session(logger);
  {
    RealThreadsafeFS fs;
    OverlayCDB cdb(nullptr, std::vector<std::string>(flags, flags + flagCount));
    ClangdServer::Options options = ClangdServer::optsForTest();
    options.AsyncThreadsCount = 2;
    options.StorePreamblesInMemory = preamblesInMemory != 0;
    options.BuildDynamicSymbolIndex = true;
    Callbacks callbacks;
    ClangdServer server(cdb, fs, options, &callbacks);

    auto t0 = std::chrono::steady_clock::now();
    server.addDocument(file, contents, "1");
    server.blockUntilIdleForTest(300);
    out->first_build_ms = since(t0);
    out->diagnostics = callbacks.diagnostics;

    // Edit the body (preamble unchanged): add a line, complete after it.
    std::string marker = "  return 0;\n}";
    size_t at = contents.rfind(marker);
    std::string edited = contents;
    std::string insertion = "  std::vector<int> spike;\n  spike.\n";
    if (at != std::string::npos) edited.insert(at, insertion);
    int line = static_cast<int>(std::count(edited.begin(), edited.begin() + (at == std::string::npos ? 0 : at), '\n')) + 1;

    auto t1 = std::chrono::steady_clock::now();
    server.addDocument(file, edited, "2");
    server.blockUntilIdleForTest(300);
    out->rebuild_ms = since(t1);

    std::promise<int> done;
    auto t2 = std::chrono::steady_clock::now();
    server.codeComplete(file, Position{line, 8}, CodeCompleteOptions(),
                        [&](llvm::Expected<CodeCompleteResult> result) {
                          if (!result) {
                            llvm::consumeError(result.takeError());
                            done.set_value(-1);
                          } else {
                            done.set_value(static_cast<int>(result->Completions.size()));
                          }
                        });
    out->completion_items = done.get_future().get();
    out->completion_ms = since(t2);
    server.blockUntilIdleForTest(60);

    llvm::BumpPtrAllocator alloc;
    MemoryTree tree(&alloc);
    server.profile(tree);
    out->clangd_bytes = tree.total();
    std::string text;
    describe(tree, "clangd", 0, text);
    snprintf(out->breakdown, sizeof out->breakdown, "%s", text.c_str());
    out->footprint_open = footprint();
  }
  out->footprint_after = footprint();
}

#else

extern "C" void lst_clangd_measure(const char *, const char *const *, int, int,
                                   lst_clangd_stats *out) {
  memset(out, 0, sizeof *out);
  snprintf(out->breakdown, sizeof out->breakdown,
           "Built without clangd headers (run Toolchain/scripts/build-llvm-ios.sh).");
}

#endif
