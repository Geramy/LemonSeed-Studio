import Darwin
import XCTest
import StudioCore
import StudioToolchain
@testable import LemonSeedStudio

/// The C/C++ toolchain end to end, in the app with its bundled compiler,
/// WASI libraries and runtimes: compile, run in both runners, stdin, files,
/// projects, diagnostics, exit codes, sockets and threads.
@MainActor
final class ToolchainTests: XCTestCase {
    var root: URL!
    var service: ToolchainService { ToolchainService.shared }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "toolchain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNil(service.unavailableReason, "the toolchain ships in the app")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    static var samples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../Toolchain/samples").standardizedFileURL
    }

    func write(_ text: String, _ name: String) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Compiles one file (through the terminal driver path) to `name.wasm`.
    func compile(_ source: URL, _ extra: [String] = [], cxx: Bool = false) async throws -> (URL, CompileResult) {
        let compiler = try XCTUnwrap(service.compiler)
        let output = root.appending(path: source.deletingPathExtension().lastPathComponent + ".wasm")
        let arguments = try compiler.driverArguments(extra + [source.lastPathComponent, "-O2", "-o", output.path],
                                                     cxx: cxx, workingDirectory: root)
        return (output, await compiler.run(arguments: arguments, output: output))
    }

    final class Captured: @unchecked Sendable {
        var stdout = ""
        var stderr = ""
    }

    func run(_ program: URL, _ args: [String] = [], runner: WasmRunner? = nil, input: WasmInput? = nil)
        async throws -> (ToolchainService.RunOutcome, Captured) {
        let captured = Captured()
        let outcome = try await service.run(program, arguments: args, directory: root, runner: runner, input: input) { chunk in
            if chunk.stream == .stderr { captured.stderr += chunk.text } else { captured.stdout += chunk.text }
        }
        return (outcome, captured)
    }

    // MARK: Compile and run

    func testHelloCompilesAndRunsInWebKit() async throws {
        let source = try write(String(contentsOf: Self.samples.appending(path: "hello.c"), encoding: .utf8), "hello.c")
        let (wasm, result) = try await compile(source)
        XCTAssertTrue(result.succeeded, result.log)
        let (outcome, out) = try await run(wasm)
        XCTAssertEqual(outcome.runner, .webKit, "pure computation runs in the JIT: \(outcome.reason)")
        XCTAssertEqual(outcome.result.exitCode, 0, outcome.result.error ?? "")
        XCTAssertTrue(out.stdout.contains("Hello, iPad!"))
        XCTAssertTrue(out.stdout.contains("primes below 2000000: 148933"))
    }

    func testMediumCppCompilesAndRuns() async throws {
        let source = try write(String(contentsOf: Self.samples.appending(path: "medium.cpp"), encoding: .utf8), "medium.cpp")
        let (wasm, result) = try await compile(source, cxx: true)
        XCTAssertTrue(result.succeeded, result.log)
        for runner in WasmRunner.allCases {
            let (outcome, out) = try await run(wasm, runner: runner)
            XCTAssertEqual(outcome.result.exitCode, 0, "\(runner): \(outcome.result.error ?? out.stderr)")
            XCTAssertFalse(out.stdout.isEmpty)
        }
    }

    func testExitCodesComeBackFromBothRunners() async throws {
        let source = try write("#include <stdlib.h>\nint main(int argc, char **argv) { if (argc > 1) exit(5); return 3; }\n", "codes.c")
        let (wasm, result) = try await compile(source)
        XCTAssertTrue(result.succeeded, result.log)
        for runner in WasmRunner.allCases {
            let (a, _) = try await run(wasm, runner: runner)
            XCTAssertEqual(a.result.exitCode, 3, "\(runner) return")
            let (b, _) = try await run(wasm, ["x"], runner: runner)
            XCTAssertEqual(b.result.exitCode, 5, "\(runner) exit()")
        }
    }

    func testStdinIsReadInWAMR() async throws {
        let source = try write("""
            #include <stdio.h>
            #include <string.h>
            int main(void) {
              char line[128]; int n = 0;
              while (fgets(line, sizeof line, stdin)) { line[strcspn(line, "\\n")] = 0; printf("got %s\\n", line); n++; }
              printf("%d lines\\n", n);
              return n == 2 ? 0 : 1;
            }
            """, "echo.c")
        let (wasm, result) = try await compile(source)
        XCTAssertTrue(result.succeeded, result.log)
        let input = WasmInput()
        let task = Task { try await self.run(wasm, input: input) }
        input.write(Data("first\n".utf8))
        try await Task.sleep(for: .milliseconds(100))
        input.write(Data("second\n".utf8))
        input.close()
        let (outcome, out) = try await task.value
        XCTAssertEqual(outcome.runner, .wamr, "reading stdin needs synchronous host calls")
        XCTAssertEqual(outcome.result.exitCode, 0, out.stderr)
        XCTAssertEqual(out.stdout, "got first\ngot second\n2 lines\n")
    }

    func testFilesStayInsideTheProject() async throws {
        try Data("from the host\n".utf8).write(to: root.appending(path: "in.txt"))
        let source = try write("""
            #include <stdio.h>
            int main(void) {
              char buf[64] = {0};
              FILE *in = fopen("in.txt", "r");
              if (!in || !fgets(buf, sizeof buf, in)) return 2;
              fclose(in);
              FILE *out = fopen("out.txt", "w");
              if (!out) return 3;
              fprintf(out, "copied: %s", buf);
              fclose(out);
              FILE *escape = fopen("../escape.txt", "w");
              printf("escape %s\\n", escape ? "opened" : "refused");
              return escape ? 4 : 0;
            }
            """, "files.c")
        let (wasm, result) = try await compile(source)
        XCTAssertTrue(result.succeeded, result.log)
        let (outcome, out) = try await run(wasm)
        XCTAssertEqual(outcome.runner, .wamr)
        XCTAssertEqual(outcome.result.exitCode, 0, out.stdout + out.stderr)
        XCTAssertEqual(try String(contentsOf: root.appending(path: "out.txt"), encoding: .utf8), "copied: from the host\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appending(path: "escape.txt").path))
    }

    func testEverydayPOSIXCompilesWithTheEmulations() async throws {
        let source = try write("""
            #include <signal.h>
            #include <stdio.h>
            #include <sys/mman.h>
            #include <time.h>
            #include <unistd.h>
            static volatile int caught;
            static void on_signal(int s) { caught = s; }
            int main(void) {
              signal(SIGUSR1, on_signal);
              raise(SIGUSR1);
              char *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
              if (p == MAP_FAILED) return 2;
              p[0] = 'x';
              munmap(p, 4096);
              struct timespec t = { 0, 1000000 };
              nanosleep(&t, NULL);
              printf("signal %s, pid %d, clock %s\\n", caught == SIGUSR1 ? "caught" : "missed", getpid() > 0, clock() >= 0 ? "ok" : "no");
              return caught == SIGUSR1 ? 0 : 1;
            }
            """, "posix.c")
        let (wasm, result) = try await compile(source)
        XCTAssertTrue(result.succeeded, result.log)
        let (outcome, out) = try await run(wasm)
        XCTAssertEqual(outcome.result.exitCode, 0, out.stdout + out.stderr + (outcome.result.error ?? ""))
        XCTAssertEqual(out.stdout, "signal caught, pid 1, clock ok\n")
    }

    func testCompileErrorsReachProblems() async throws {
        let source = try write("int main(void) {\n  int x = ;\n  return undefined_name;\n}\n", "broken.c")
        let (_, result) = try await compile(source)
        XCTAssertFalse(result.succeeded)
        let errors = result.diagnostics.filter { $0.level == .error }
        XCTAssertGreaterThanOrEqual(errors.count, 2)
        XCTAssertEqual(errors.first?.file, "broken.c")
        XCTAssertEqual(errors.first?.line, 2)
        XCTAssertGreaterThan(errors.first?.column ?? 0, 0)
        let center = DiagnosticsCenter()
        service.publish(result.diagnostics, root: root, to: center)
        let published = center.diagnostics(for: source)
        XCTAssertEqual(published.filter { $0.severity == .error }.count, errors.count)
        XCTAssertEqual(published.first?.range.lowerBound.line, 2)
        XCTAssertEqual(published.first?.source, "clang")
    }

    // MARK: Projects

    func testMultiFileProjectBuildsIncrementally() async throws {
        _ = try write("#pragma once\nint add(int a, int b);\n#define BASE 40\n", "include/util.h")
        _ = try write("#include \"util.h\"\nint add(int a, int b) { return a + b; }\n", "src/util.c")
        _ = try write("#include <stdio.h>\n#include \"util.h\"\nint main(int c, char **v) { printf(\"%d %s\\n\", add(BASE, 2), c > 1 ? v[1] : \"\"); return 0; }\n", "src/main.c")
        _ = try write(#"{"name": "demo", "sources": ["src/*.c"], "includes": ["include"], "flags": ["-O2", "-Wall"], "args": ["ok"]}"#,
                      "studio-build.json")
        let compiler = try XCTUnwrap(service.compiler)
        let manifest = try ProjectManifest.load(from: root)
        var result = try await ProjectBuilder(compiler: compiler, root: root, manifest: manifest).build()
        XCTAssertTrue(result.succeeded, result.log)
        XCTAssertEqual(result.compiled, 2)
        XCTAssertTrue(result.linked)
        let (outcome, out) = try await run(result.output, manifest.args ?? [])
        XCTAssertEqual(outcome.result.exitCode, 0)
        XCTAssertEqual(out.stdout, "42 ok\n")

        // Nothing changed: nothing compiles or links.
        result = try await ProjectBuilder(compiler: compiler, root: root, manifest: manifest).build()
        XCTAssertEqual(result.compiled, 0)
        XCTAssertEqual(result.upToDate, 2)
        XCTAssertFalse(result.linked)

        // A header both files include: both recompile.
        try await Task.sleep(for: .milliseconds(1100))
        _ = try write("#pragma once\nint add(int a, int b);\n#define BASE 50\n", "include/util.h")
        result = try await ProjectBuilder(compiler: compiler, root: root, manifest: manifest).build()
        XCTAssertEqual(result.compiled, 2)
        XCTAssertTrue(result.linked)
        let (_, again) = try await run(result.output, manifest.args ?? [])
        XCTAssertEqual(again.stdout, "52 ok\n")
    }

    func testTheTargetIsSetInTheManifestAndBuildsForWASIX() async throws {
        _ = try write("#include <stdio.h>\n#include <unistd.h>\nint main(void) { char d[64]; printf(\"in %s\\n\", getcwd(d, sizeof d)); return 0; }\n", "main.c")
        let original = """
            {
                "name": "pick",
                "sources": ["main.c"]
            }
            """
        _ = try write(original, "studio-build.json")
        try ProjectManifest.setTarget(.wasix, in: root)
        let text = try String(contentsOf: root.appending(path: "studio-build.json"), encoding: .utf8)
        XCTAssertEqual(text, """
            {
                "target": "wasm32-wasix",
                "name": "pick",
                "sources": ["main.c"]
            }
            """)
        try ProjectManifest.setTarget(.wasip1Threads, in: root)
        XCTAssertEqual(try ProjectManifest.load(from: root).target, .wasip1Threads)
        try ProjectManifest.setTarget(.wasix, in: root)
        let manifest = try ProjectManifest.load(from: root)
        XCTAssertEqual(manifest, ProjectManifest(name: "pick", target: .wasix, sources: ["main.c"]))

        let compiler = try XCTUnwrap(service.compiler)
        let result = try await ProjectBuilder(compiler: compiler, root: root, manifest: manifest).build()
        XCTAssertTrue(result.succeeded, result.log)
        let info = try WasmModuleInfo(data: Data(contentsOf: result.output))
        XCTAssertTrue(info.imports.contains { $0.module == "wasix_32v1" }, "\(info.imports)")
        let (outcome, out) = try await run(result.output)
        XCTAssertEqual(outcome.runner, .wamr)
        XCTAssertEqual(out.stdout, "in /\n")

        // A one-line manifest gets the key too.
        let empty = root.appending(path: "e")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data(#"{"name": "e", "sources": []}"#.utf8).write(to: empty.appending(path: "studio-build.json"))
        try ProjectManifest.setTarget(.wasip1, in: empty)
        XCTAssertEqual(try ProjectManifest.load(from: empty).target, .wasip1)
    }

    // MARK: The terminal

    func testTerminalCompilesAndRunsWithPipedInput() async throws {
        _ = try write("#include <stdio.h>\nint main(void) { int a, b; if (scanf(\"%d %d\", &a, &b) != 2) return 9; printf(\"sum %d\\n\", a + b); return a + b == 7 ? 0 : 1; }\n", "sum.c")
        let shell = BuiltinShell(root: root, commands: BuiltinCommands.all + ToolchainCommands.all)
        let output = await shell.run("clang sum.c -o sum.wasm && echo '3 4' | run sum.wasm")
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        XCTAssertEqual(output.stdout, "sum 7\n")
        let failing = await shell.run("clang --target=riscv64 sum.c")
        XCTAssertNotEqual(failing.exitCode, 0)
        XCTAssertTrue(failing.stderr.contains("unsupported target"), failing.stderr)
        let escape = await shell.run("clang sum.c -o ../outside.wasm")
        XCTAssertNotEqual(escape.exitCode, 0)
    }

    // MARK: Sockets

    /// A loopback TCP listener on a free port, on its own thread.
    final class EchoServer: @unchecked Sendable {
        let fd: Int32
        let port: UInt16
        private(set) var received = ""
        private let done = DispatchSemaphore(value: 0)

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            self.fd = fd
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
            }
            guard bound, listen(fd, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
            port = UInt16(bigEndian: addr.sin_port)
            Thread {
                let client = accept(fd, nil, nil)
                var buffer = [UInt8](repeating: 0, count: 256)
                let n = recv(client, &buffer, buffer.count, 0)
                if n > 0 {
                    self.received = String(decoding: buffer[0..<n], as: UTF8.self)
                    _ = send(client, buffer, n, 0)
                }
                close(client)
                self.done.signal()
            }.start()
        }

        func wait() { _ = done.wait(timeout: .now() + 10) }
        deinit { close(fd) }
    }

    func testATCPClientWithGetaddrinfoReachesALocalServer() async throws {
        let server = try EchoServer()
        let source = try write("""
            #include <stdio.h>
            #include <string.h>
            #include <stdlib.h>
            #include <unistd.h>
            #include <sys/socket.h>
            #include <netinet/in.h>
            #include <netdb.h>
            int main(int argc, char **argv) {
              struct addrinfo hints = {0}, *res = NULL;
              hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
              int rc = getaddrinfo("localhost", argv[1], &hints, &res);
              if (rc != 0) { printf("getaddrinfo: %s\\n", gai_strerror(rc)); return 2; }
              int fd = socket(res->ai_family, res->ai_socktype, 0);
              if (fd < 0 || connect(fd, res->ai_addr, res->ai_addrlen) != 0) { perror("connect"); return 3; }
              freeaddrinfo(res);
              const char *msg = "hello from wasm";
              if (send(fd, msg, strlen(msg), 0) != (ssize_t)strlen(msg)) return 4;
              char buf[64] = {0};
              ssize_t n = recv(fd, buf, sizeof buf - 1, 0);
              printf("echo: %s\\n", n > 0 ? buf : "(none)");
              close(fd);
              return n > 0 ? 0 : 5;
            }
            """, "client.c")
        let (wasm, result) = try await compile(source)
        XCTAssertTrue(result.succeeded, result.log)
        let (outcome, out) = try await run(wasm, [String(server.port)])
        server.wait()
        XCTAssertEqual(outcome.runner, .wamr, outcome.reason)
        XCTAssertEqual(outcome.result.exitCode, 0, out.stdout + out.stderr + (outcome.result.error ?? ""))
        XCTAssertEqual(server.received, "hello from wasm")
        XCTAssertEqual(out.stdout, "echo: hello from wasm\n")
    }

    func testAServerWithPollAcceptsAConnection() async throws {
        let source = try write("""
            #include <stdio.h>
            #include <string.h>
            #include <unistd.h>
            #include <stdlib.h>
            #include <poll.h>
            #include <sys/socket.h>
            #include <netinet/in.h>
            #include <arpa/inet.h>
            int main(int argc, char **argv) {
              int fd = socket(AF_INET, SOCK_STREAM, 0);
              int one = 1;
              setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
              struct sockaddr_in addr = {0};
              addr.sin_family = AF_INET;
              addr.sin_port = htons(atoi(argv[1]));
              addr.sin_addr.s_addr = inet_addr("127.0.0.1");
              if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0) { perror("bind"); return 2; }
              if (listen(fd, 1) != 0) { perror("listen"); return 3; }
              printf("listening\\n"); fflush(stdout);
              struct pollfd p = { .fd = fd, .events = POLLIN };
              if (poll(&p, 1, 10000) != 1) { printf("poll timed out\\n"); return 4; }
              int client = accept(fd, NULL, NULL);
              if (client < 0) { perror("accept"); return 5; }
              char buf[64] = {0};
              ssize_t n = recv(client, buf, sizeof buf - 1, 0);
              char reply[96];
              int len = snprintf(reply, sizeof reply, "server got: %s", buf);
              send(client, reply, len, 0);
              close(client); close(fd);
              return n > 0 ? 0 : 6;
            }
            """, "server.c")
        let (wasm, result) = try await compile(source)
        XCTAssertTrue(result.succeeded, result.log)
        // A free port: bind one, close it, give it to the program.
        let probe = try EchoServer()
        let port = probe.port
        close(probe.fd)
        let task = Task { try await self.run(wasm, [String(port)]) }
        var reply = ""
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            if let text = Self.exchange(port: port, message: "ping") { reply = text; break }
        }
        let (outcome, out) = try await task.value
        XCTAssertEqual(outcome.runner, .wamr)
        XCTAssertEqual(outcome.result.exitCode, 0, out.stdout + out.stderr)
        XCTAssertEqual(reply, "server got: ping")
    }

    nonisolated static func exchange(port: UInt16, message: String) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard ok else { return nil }
        _ = message.withCString { send(fd, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 128)
        let n = recv(fd, &buffer, buffer.count, 0)
        return n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : nil
    }

    // MARK: Threads

    func testPthreadsRunInWAMR() async throws {
        let source = try write("""
            #include <pthread.h>
            #include <stdio.h>
            #include <stdatomic.h>
            static atomic_int total;
            static void *work(void *arg) { int n = (int)(long)arg; for (int i = 0; i < 1000; i++) atomic_fetch_add(&total, n); return NULL; }
            int main(void) {
              pthread_t t[4];
              for (long i = 0; i < 4; i++) { int rc = pthread_create(&t[i], NULL, work, (void *)(i + 1)); if (rc != 0) { printf("pthread_create: %d\\n", rc); return 2; } }
              for (int i = 0; i < 4; i++) pthread_join(t[i], NULL);
              printf("total %d\\n", atomic_load(&total));
              return atomic_load(&total) == 10000 ? 0 : 1;
            }
            """, "threads.c")
        let (wasm, result) = try await compile(source, ["-pthread"])
        XCTAssertTrue(result.succeeded, result.log)
        let info = try WasmModuleInfo(data: Data(contentsOf: wasm))
        XCTAssertTrue(info.usesThreads)
        let (outcome, out) = try await run(wasm)
        XCTAssertEqual(outcome.runner, .wamr, outcome.reason)
        XCTAssertEqual(outcome.result.exitCode, 0, out.stdout + out.stderr + (outcome.result.error ?? ""))
        XCTAssertEqual(out.stdout, "total 10000\n")
    }

    // MARK: WASIX

    func compileWASIX(_ source: String, _ name: String) async throws -> URL {
        let url = try write(source, name)
        let (wasm, result) = try await compile(url, ["--target=wasm32-wasix"])
        XCTAssertTrue(result.succeeded, result.log)
        XCTAssertTrue(try WasmModuleInfo(data: Data(contentsOf: wasm)).usesWASIX)
        return wasm
    }

    func testWASIXHelloRunsOnWAMR() async throws {
        let wasm = try await compileWASIX("#include <stdio.h>\nint main(void) { printf(\"hello wasix\\n\"); return 7; }\n", "wx_hello.c")
        let (outcome, out) = try await run(wasm)
        XCTAssertEqual(outcome.runner, .wamr, outcome.reason)
        XCTAssertEqual(outcome.result.exitCode, 7, out.stderr + (outcome.result.error ?? ""))
        XCTAssertEqual(out.stdout, "hello wasix\n")
    }

    func testWASIXClientWithGetaddrinfoReachesALocalServer() async throws {
        let server = try EchoServer()
        let wasm = try await compileWASIX("""
            #include <stdio.h>
            #include <string.h>
            #include <unistd.h>
            #include <sys/socket.h>
            #include <netdb.h>
            int main(int argc, char **argv) {
              struct addrinfo hints = {0}, *res = NULL;
              hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
              int rc = getaddrinfo("localhost", argv[1], &hints, &res);
              if (rc != 0) { printf("getaddrinfo: %s\\n", gai_strerror(rc)); return 2; }
              int fd = socket(res->ai_family, res->ai_socktype, 0);
              if (fd < 0 || connect(fd, res->ai_addr, res->ai_addrlen) != 0) { perror("connect"); return 3; }
              freeaddrinfo(res);
              const char *msg = "hello from wasix";
              send(fd, msg, strlen(msg), 0);
              char buf[64] = {0};
              ssize_t n = recv(fd, buf, sizeof buf - 1, 0);
              printf("echo: %s\\n", n > 0 ? buf : "(none)");
              close(fd);
              return n > 0 ? 0 : 5;
            }
            """, "wx_client.c")
        let (outcome, out) = try await run(wasm, [String(server.port)])
        server.wait()
        XCTAssertEqual(outcome.result.exitCode, 0, out.stdout + out.stderr + (outcome.result.error ?? ""))
        XCTAssertEqual(server.received, "hello from wasix")
        XCTAssertEqual(out.stdout, "echo: hello from wasix\n")
    }

    func testWASIXServerWithPollAcceptsAConnection() async throws {
        let wasm = try await compileWASIX("""
            #include <stdio.h>
            #include <stdlib.h>
            #include <unistd.h>
            #include <poll.h>
            #include <sys/socket.h>
            #include <netinet/in.h>
            #include <arpa/inet.h>
            int main(int argc, char **argv) {
              int fd = socket(AF_INET, SOCK_STREAM, 0); int one = 1;
              setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
              struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_port = htons(atoi(argv[1]));
              a.sin_addr.s_addr = inet_addr("127.0.0.1");
              if (bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 1)) { perror("bind/listen"); return 2; }
              struct pollfd p = { fd, POLLIN, 0 };
              if (poll(&p, 1, 10000) != 1) { printf("poll timed out\\n"); return 4; }
              struct sockaddr_in peer; socklen_t len = sizeof peer;
              int c = accept(fd, (struct sockaddr *)&peer, &len);
              if (c < 0) { perror("accept"); return 5; }
              char b[64] = {0}; ssize_t n = recv(c, b, 63, 0);
              char r[128]; int l = snprintf(r, sizeof r, "server got: %s from %s", b, inet_ntoa(peer.sin_addr));
              send(c, r, l, 0); close(c); close(fd);
              return n > 0 ? 0 : 6;
            }
            """, "wx_server.c")
        let probe = try EchoServer()
        let port = probe.port
        close(probe.fd)
        let task = Task { try await self.run(wasm, [String(port)]) }
        var reply = ""
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            if let text = Self.exchange(port: port, message: "ping") { reply = text; break }
        }
        let (outcome, out) = try await task.value
        XCTAssertEqual(outcome.result.exitCode, 0, out.stdout + out.stderr + (outcome.result.error ?? ""))
        XCTAssertEqual(reply, "server got: ping from 127.0.0.1")
    }

    func testWASIXThreadsSignalsAndTheWorkingDirectory() async throws {
        try FileManager.default.createDirectory(at: root.appending(path: "data"), withIntermediateDirectories: true)
        try Data("inside\n".utf8).write(to: root.appending(path: "data/in.txt"))
        let wasm = try await compileWASIX("""
            #include <pthread.h>
            #include <signal.h>
            #include <stdatomic.h>
            #include <stdio.h>
            #include <string.h>
            #include <unistd.h>
            static atomic_int total;
            static volatile int caught;
            static void on_signal(int s) { caught = s; }
            static void *work(void *arg) { for (int i = 0; i < 1000; i++) atomic_fetch_add(&total, (int)(long)arg); return NULL; }
            int main(void) {
              pthread_t t[4];
              for (long i = 0; i < 4; i++) if (pthread_create(&t[i], NULL, work, (void *)(i + 1))) return 2;
              for (int i = 0; i < 4; i++) pthread_join(t[i], NULL);
              // Threads that end are reused: start and join more than the runtime's 64.
              for (int round = 0; round < 80; round++) { pthread_t x; if (pthread_create(&x, NULL, work, (void *)0L)) return 3; pthread_join(x, NULL); }
              signal(SIGUSR1, on_signal);
              raise(SIGUSR1);
              char cwd[256];
              if (chdir("data") != 0) { perror("chdir"); return 4; }
              if (!getcwd(cwd, sizeof cwd)) { perror("getcwd"); return 6; }
              FILE *f = fopen("in.txt", "r");
              char line[32] = {0};
              if (!f || !fgets(line, sizeof line, f)) { perror("fopen"); return 5; }
              fclose(f);
              printf("total %d, signal %s, cwd %s, read %s", atomic_load(&total), caught == SIGUSR1 ? "caught" : "missed", cwd, line);
              return 0;
            }
            """, "wx_threads.c")
        let (outcome, out) = try await run(wasm)
        XCTAssertEqual(outcome.runner, .wamr)
        XCTAssertEqual(outcome.result.exitCode, 0, out.stdout + out.stderr + (outcome.result.error ?? ""))
        XCTAssertEqual(out.stdout, "total 10000, signal caught, cwd /data, read inside\n")
    }

    func testWASIXCoverageListsEveryCall() {
        let coverage = WAMRRunner.wasixCoverage
        XCTAssertEqual(coverage.count, Set(coverage.map(\.call)).count, "each call once")
        for call in ["sock_open", "sock_accept_v2", "resolve", "futex_wait", "thread_exit", "getcwd", "path_open2"] {
            XCTAssertTrue(coverage.contains { $0.call == call && $0.implemented }, call)
        }
        for call in ["proc_fork", "proc_exec", "dlopen", "epoll_create"] {
            XCTAssertTrue(coverage.contains { $0.call == call && !$0.implemented }, call)
        }
    }
}
