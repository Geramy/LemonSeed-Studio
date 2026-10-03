// In-process clang driver, cc1 and wasm-ld. See include/lst_compiler.h.
//
// The flow mirrors clang's own driver with -fintegrated-cc1, minus every
// process spawn:
//   1. clang::driver::Driver parses the command line and plans the jobs.
//   2. Each "-cc1" job runs through CompilerInvocation + ExecuteCompilerInvocation
//      (what cc1_main does), on the calling thread.
//   3. The link job runs through lld::lldMain with only the wasm driver.
// Every step runs inside llvm::CrashRecoveryContext, so a fatal error or a
// crash in the compiler returns an error instead of ending the app.

#include "lst_compiler.h"

// Written by build-llvm-ios.sh (1) or make-stub-xcframeworks.sh (0).
#include <lemonseed/llvm_config.h>

#if LST_HAVE_LLVM

#include "clang/Basic/Diagnostic.h"
#include "clang/Basic/DiagnosticIDs.h"
#include "clang/Basic/DiagnosticOptions.h"
#include "clang/Basic/SourceManager.h"
#include "clang/Basic/Version.h"
#include "clang/CodeGen/ObjectFilePCHContainerWriter.h"
#include "clang/Driver/Compilation.h"
#include "clang/Driver/Driver.h"
#include "clang/Driver/Job.h"
#include "clang/Driver/Tool.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/Frontend/TextDiagnosticBuffer.h"
#include "clang/Frontend/TextDiagnosticPrinter.h"
#include "clang/FrontendTool/Utils.h"
#include "clang/Serialization/ObjectFilePCHContainerReader.h"
#include "lld/Common/Driver.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/CrashRecoveryContext.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/Process.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/VirtualFileSystem.h"
#include "llvm/Support/raw_ostream.h"

#include <chrono>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>

LLD_HAS_DRIVER(wasm)

using namespace clang;

namespace {

/// A raw_ostream that hands everything written to it to a callback.
class CallbackStream final : public llvm::raw_ostream {
public:
  CallbackStream(const lst_callbacks *callbacks, lst_stream stream)
      : callbacks_(callbacks), stream_(stream) {}
  ~CallbackStream() override { flush(); }

private:
  void write_impl(const char *ptr, size_t size) override {
    position_ += size;
    if (callbacks_ && callbacks_->text)
      callbacks_->text(callbacks_->user, stream_, ptr, size);
  }
  uint64_t current_pos() const override { return position_; }

  const lst_callbacks *callbacks_;
  lst_stream stream_;
  uint64_t position_ = 0;
};

/// Renders diagnostics as text (like command-line clang) and also reports
/// each one in structured form.
class StructuredDiagnostics final : public DiagnosticConsumer {
public:
  StructuredDiagnostics(llvm::raw_ostream &os, DiagnosticOptions &options,
                        const lst_callbacks *callbacks)
      : printer_(os, options), callbacks_(callbacks) {}

  void BeginSourceFile(const LangOptions &langOpts,
                       const Preprocessor *pp) override {
    printer_.BeginSourceFile(langOpts, pp);
  }
  void EndSourceFile() override { printer_.EndSourceFile(); }
  void finish() override { printer_.finish(); }

  void HandleDiagnostic(DiagnosticsEngine::Level level,
                        const Diagnostic &info) override {
    DiagnosticConsumer::HandleDiagnostic(level, info);
    printer_.HandleDiagnostic(level, info);
    if (!callbacks_ || !callbacks_->diagnostic)
      return;

    llvm::SmallString<256> message;
    info.FormatDiagnostic(message);
    std::string file;
    unsigned line = 0, column = 0;
    if (info.getLocation().isValid() && info.hasSourceManager()) {
      PresumedLoc loc =
          info.getSourceManager().getPresumedLoc(info.getLocation());
      if (loc.isValid()) {
        file = loc.getFilename();
        line = loc.getLine();
        column = loc.getColumn();
      }
    }
    lst_diagnostic d;
    d.level = mapLevel(level);
    d.file = file.c_str();
    d.line = line;
    d.column = column;
    d.message = message.c_str();
    callbacks_->diagnostic(callbacks_->user, &d);
  }

private:
  static lst_diag_level mapLevel(DiagnosticsEngine::Level level) {
    switch (level) {
    case DiagnosticsEngine::Ignored:
    case DiagnosticsEngine::Note:
      return LST_DIAG_NOTE;
    case DiagnosticsEngine::Remark:
      return LST_DIAG_REMARK;
    case DiagnosticsEngine::Warning:
      return LST_DIAG_WARNING;
    case DiagnosticsEngine::Error:
      return LST_DIAG_ERROR;
    case DiagnosticsEngine::Fatal:
      return LST_DIAG_FATAL;
    }
    return LST_DIAG_ERROR;
  }

  TextDiagnosticPrinter printer_;
  const lst_callbacks *callbacks_;
};

double millisecondsSince(std::chrono::steady_clock::time_point start) {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now() - start)
      .count();
}

/// LLVM's default fatal-error path exits the process. Route it through
/// Process::Exit, which unwinds to the innermost CrashRecoveryContext instead.
void fatalErrorHandler(void *, const char *message, bool) {
  llvm::errs() << "LLVM fatal error: " << message << "\n";
  llvm::sys::Process::Exit(70);
}

void initializeOnce() {
  static std::once_flag once;
  std::call_once(once, [] {
    llvm::InitializeAllTargets();
    llvm::InitializeAllTargetMCs();
    llvm::InitializeAllAsmPrinters();
    llvm::InitializeAllAsmParsers();
    llvm::CrashRecoveryContext::Enable();
    llvm::install_fatal_error_handler(fatalErrorHandler, nullptr);
  });
}

/// Runs fn inside a crash recovery context. Returns false if it crashed or
/// hit a fatal error; *exitCode then holds the code passed to Process::Exit.
template <typename Fn> bool runSafely(Fn &&fn, int *exitCode) {
  llvm::CrashRecoveryContext context;
  context.DumpStackAndCleanupOnFailure = false;
  bool ok = context.RunSafely([&] { fn(); });
  if (!ok && exitCode)
    *exitCode = context.RetCode ? context.RetCode : 70;
  return ok;
}

/// One cc1 invocation: what clang's cc1_main does, with diagnostics routed to
/// our consumer and without -disable-free (we must not leak in a long-lived
/// process).
int runCC1(llvm::ArrayRef<const char *> jobArgs, const char *argv0,
           llvm::raw_ostream &errOS, const lst_callbacks *callbacks) {
  llvm::SmallVector<const char *, 128> args;
  for (const char *arg : jobArgs.drop_front()) // drop "-cc1"
    if (std::strcmp(arg, "-disable-free") != 0)
      args.push_back(arg);

  auto pchOps = std::make_shared<PCHContainerOperations>();
  pchOps->registerWriter(std::make_unique<ObjectFilePCHContainerWriter>());
  pchOps->registerReader(std::make_unique<ObjectFilePCHContainerReader>());

  IntrusiveRefCntPtr<DiagnosticIDs> diagIDs(new DiagnosticIDs());
  DiagnosticOptions parseOptions;
  auto *parseBuffer = new TextDiagnosticBuffer;
  DiagnosticsEngine parseDiags(diagIDs, parseOptions, parseBuffer);

  auto invocation = std::make_shared<CompilerInvocation>();
  bool ok = CompilerInvocation::CreateFromArgs(*invocation, args, parseDiags,
                                               argv0);
  auto clang = std::make_unique<CompilerInstance>(std::move(invocation),
                                                  std::move(pchOps));
  clang->createDiagnostics(
      *llvm::vfs::getRealFileSystem(),
      new StructuredDiagnostics(errOS, clang->getDiagnosticOpts(), callbacks),
      /*ShouldOwnClient=*/true);
  if (!clang->hasDiagnostics())
    return 1;
  clang->setVerboseOutputStream(errOS); // "N errors generated." and -v
  parseBuffer->FlushDiagnostics(clang->getDiagnostics());
  if (!ok) {
    clang->getDiagnosticClient().finish();
    return 1;
  }
  ok = ExecuteCompilerInvocation(clang.get());
  return ok ? 0 : 1;
}

std::mutex &linkerMutex() {
  static std::mutex mutex;
  return mutex;
}

int runWasmLd(llvm::ArrayRef<const char *> args, llvm::raw_ostream &outOS,
              llvm::raw_ostream &errOS) {
  // lld keeps global state: one link at a time.
  std::lock_guard<std::mutex> lock(linkerMutex());
  static const lld::DriverDef drivers[] = {{lld::Wasm, &lld::wasm::link}};
  lld::Result result = lld::lldMain(args, outOS, errOS, drivers);
  if (!result.canRunAgain)
    errOS << "wasm-ld: linker state could not be reset; restart the app "
             "before linking again\n";
  return result.retCode;
}

bool endsWith(llvm::StringRef s, llvm::StringRef suffix) {
  return s.ends_with(suffix);
}

} // namespace

extern "C" int lst_toolchain_available(void) { return 1; }

extern "C" const char *lst_toolchain_version(void) {
  static const std::string version = getClangFullVersion();
  return version.c_str();
}

extern "C" int lst_clang_main(int argc, const char *const *argv,
                              const lst_callbacks *callbacks,
                              lst_timings *timings) {
  initializeOnce();
  lst_timings local = {};
  CallbackStream outOS(callbacks, LST_STREAM_STDOUT);
  CallbackStream errOS(callbacks, LST_STREAM_STDERR);
  int exitCode = 0;

  bool survived = runSafely(
      [&] {
        auto start = std::chrono::steady_clock::now();
        llvm::SmallVector<const char *, 64> args(argv, argv + argc);

        DiagnosticOptions diagOptions;
        IntrusiveRefCntPtr<DiagnosticIDs> diagIDs(new DiagnosticIDs());
        DiagnosticsEngine diags(
            diagIDs, diagOptions,
            new StructuredDiagnostics(errOS, diagOptions, callbacks));
        driver::Driver driver(argv[0], "wasm32-wasip1", diags,
                              "clang LLVM compiler",
                              llvm::vfs::getRealFileSystem());
        driver.setCheckInputsExist(true);

        std::unique_ptr<driver::Compilation> compilation(
            driver.BuildCompilation(args));
        local.driver_ms = millisecondsSince(start);
        if (!compilation || compilation->containsError() ||
            diags.hasErrorOccurred()) {
          exitCode = 1;
          return;
        }

        for (const driver::Command &job : compilation->getJobs()) {
          const llvm::opt::ArgStringList &jobArgs = job.getArguments();
          llvm::StringRef executable = job.getExecutable();
          if (!jobArgs.empty() && llvm::StringRef(jobArgs[0]) == "-cc1") {
            auto t = std::chrono::steady_clock::now();
            exitCode = runCC1(jobArgs, argv[0], errOS, callbacks);
            local.compile_ms += millisecondsSince(t);
            local.compile_jobs++;
          } else if (job.getCreator().isLinkJob()) {
            auto t = std::chrono::steady_clock::now();
            llvm::SmallVector<const char *, 64> ldArgs;
            ldArgs.push_back("wasm-ld");
            ldArgs.append(jobArgs.begin(), jobArgs.end());
            exitCode = runWasmLd(ldArgs, outOS, errOS);
            local.link_ms += millisecondsSince(t);
            local.link_jobs++;
          } else if (endsWith(executable, "wasm-opt")) {
            continue; // optional post-link optimizer; not bundled
          } else {
            errOS << "clang: '" << executable
                  << "' is not available on iPad (in-process tools only)\n";
            exitCode = 1;
          }
          if (exitCode != 0)
            break;
        }
        if (exitCode != 0)
          compilation->CleanupFileMap(compilation->getResultFiles(), nullptr,
                                      true);
        compilation->CleanupFileList(compilation->getTempFiles());
      },
      &exitCode);

  if (!survived)
    errOS << "clang: the compiler crashed or hit a fatal error (exit code "
          << exitCode << "); the app is still running\n";
  outOS.flush();
  errOS.flush();
  if (timings)
    *timings = local;
  return exitCode;
}

extern "C" int lst_wasm_ld_main(int argc, const char *const *argv,
                                const lst_callbacks *callbacks) {
  initializeOnce();
  CallbackStream outOS(callbacks, LST_STREAM_STDOUT);
  CallbackStream errOS(callbacks, LST_STREAM_STDERR);
  int exitCode = 0;
  bool survived = runSafely(
      [&] {
        exitCode = runWasmLd(llvm::ArrayRef<const char *>(argv, argc), outOS,
                             errOS);
      },
      &exitCode);
  if (!survived)
    errOS << "wasm-ld: the linker crashed (exit code " << exitCode << ")\n";
  return exitCode;
}

#else // !LST_HAVE_LLVM

#include <string.h>

static const char kMissing[] =
    "The LLVM toolchain is not built into this app (placeholder "
    "LemonSeedLLVM.xcframework). Run Toolchain/scripts/build-llvm-ios.sh, "
    "then rebuild.";

static void reportMissing(const lst_callbacks *callbacks) {
  if (callbacks && callbacks->text)
    callbacks->text(callbacks->user, LST_STREAM_STDERR, kMissing,
                    strlen(kMissing));
}

extern "C" int lst_toolchain_available(void) { return 0; }
extern "C" const char *lst_toolchain_version(void) { return kMissing; }

extern "C" int lst_clang_main(int, const char *const *,
                              const lst_callbacks *callbacks,
                              lst_timings *timings) {
  if (timings)
    memset(timings, 0, sizeof *timings);
  reportMissing(callbacks);
  return 127;
}

extern "C" int lst_wasm_ld_main(int, const char *const *,
                                const lst_callbacks *callbacks) {
  reportMissing(callbacks);
  return 127;
}

#endif
