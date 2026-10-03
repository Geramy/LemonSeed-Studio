import XCTest
@testable import StudioCore

final class ShellParserTests: XCTestCase {
    private func words(_ line: String, env: [String: String] = [:]) throws -> [[String]] {
        try ShellParser.parse(line, environment: env).pipelines.flatMap { $0.commands.map { $0.words.map(\.text) } }
    }

    func testQuotingAndEscapes() throws {
        XCTAssertEqual(try words(#"echo "a b" 'c d' e\ f"#), [["echo", "a b", "c d", "e f"]])
        XCTAssertEqual(try words(#"echo "say \"hi\"" 'it''s'"#), [["echo", #"say "hi""#, "its"]])
        XCTAssertEqual(try words("echo a#b # comment"), [["echo", "a#b"]])
    }

    func testVariables() throws {
        let env = ["HOME": "/w", "NAME": "lemon"]
        XCTAssertEqual(try words("echo $NAME ${NAME}s \"$NAME!\" '$NAME' ~ ~/x", env: env),
                       [["echo", "lemon", "lemons", "lemon!", "$NAME", "/w", "/w/x"]])
        XCTAssertEqual(try words("echo $MISSING.", env: env), [["echo", "."]])
    }

    func testOperators() throws {
        let script = try ShellParser.parse("a && b || c; d | e > out.txt; f >> log")
        XCTAssertEqual(script.pipelines.map(\.connector), [.always, .ifSuccess, .ifFailure, .always, .always])
        XCTAssertEqual(script.pipelines[3].commands.count, 2)
        XCTAssertEqual(script.pipelines[3].commands[1].redirect, ShellScript.Redirect(target: .init("out.txt"), append: false))
        XCTAssertEqual(script.pipelines[4].commands[0].redirect?.append, true)
    }

    func testErrors() {
        XCTAssertThrowsError(try ShellParser.parse("echo 'open"))
        XCTAssertThrowsError(try ShellParser.parse("echo \"open"))
        XCTAssertThrowsError(try ShellParser.parse("echo >"))
        XCTAssertThrowsError(try ShellParser.parse("| a"))
        XCTAssertThrowsError(try ShellParser.parse("a &&"))
        XCTAssertEqual(try ShellParser.parse("   ").pipelines.count, 0)
    }

    func testQuotedWordsAreNotGlobs() throws {
        let script = try ShellParser.parse(#"ls *.c "*.h""#)
        let commandWords = script.pipelines[0].commands[0].words
        XCTAssertFalse(commandWords[1].quoted)
        XCTAssertTrue(commandWords[2].quoted)
    }
}

final class BuiltinShellTests: XCTestCase {
    func testPwdCdAndPrompt() async throws {
        let tree = try TemporaryTree(["src/lib/": ""])
        let shell = BuiltinShell(root: tree.url)
        var output = await shell.run("pwd")
        XCTAssertEqual(output.stdout, tree.url.standardizedFileURL.path + "\n")
        _ = await shell.run("cd src/lib")
        let prompt = await shell.promptPath
        XCTAssertEqual(prompt, "~/src/lib")
        _ = await shell.run("cd ..")
        output = await shell.run("pwd")
        XCTAssertTrue(output.stdout.hasSuffix("/src\n"))
        _ = await shell.run("cd -")
        let back = await shell.promptPath
        XCTAssertEqual(back, "~/src/lib")
        _ = await shell.run("cd")
        let home = await shell.promptPath
        XCTAssertEqual(home, "~")
        output = await shell.run("cd nope")
        XCTAssertEqual(output.exitCode, 1)
        XCTAssertTrue(output.stderr.contains("No such file or directory"))
    }

    func testJailToWorkspace() async throws {
        let tree = try TemporaryTree(["a.txt": "x"])
        let shell = BuiltinShell(root: tree.child("."))
        var output = await shell.run("cd ..")
        XCTAssertEqual(output.exitCode, 1)
        XCTAssertTrue(output.stderr.contains("outside the workspace"))
        output = await shell.run("cat /etc/hosts")
        XCTAssertEqual(output.exitCode, 1)
        XCTAssertTrue(output.stderr.contains("outside the workspace"))
        output = await shell.run("rm -rf .")
        XCTAssertTrue(output.stderr.contains("refusing"))
        XCTAssertTrue(tree.exists("a.txt"))
    }

    func testFileCommands() async throws {
        let tree = try TemporaryTree()
        let shell = BuiltinShell(root: tree.url)
        var output = await shell.run("mkdir -p src/include && echo 'int x;' > src/a.c && echo more >> src/a.c")
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        XCTAssertEqual(try tree.read("src/a.c"), "int x;\nmore\n")

        output = await shell.run("cp src/a.c src/b.c && mv src/b.c src/include/ && ls src/include")
        XCTAssertEqual(output.stdout, "b.c\n")

        output = await shell.run("cat src/a.c src/include/b.c")
        XCTAssertEqual(output.stdout, "int x;\nmore\nint x;\nmore\n")

        output = await shell.run("cat -n src/a.c")
        XCTAssertEqual(output.stdout, "  1  int x;\n  2  more\n")

        output = await shell.run("rm src/include")
        XCTAssertEqual(output.exitCode, 1)
        XCTAssertTrue(output.stderr.contains("is a directory"))

        output = await shell.run("cp src/include copy")
        XCTAssertEqual(output.exitCode, 1)
        output = await shell.run("cp -r src/include copy && rm -r src/include && ls")
        XCTAssertEqual(output.stdout, "copy\nsrc\n")

        output = await shell.run("touch empty.txt && ls -a")
        XCTAssertEqual(output.stdout, "copy\nempty.txt\nsrc\n")
        output = await shell.run("mkdir src")
        XCTAssertTrue(output.stderr.contains("File exists"))
        output = await shell.run("rm -f nothing-here")
        XCTAssertEqual(output.exitCode, 0)
    }

    func testPipesConnectorsAndStatus() async throws {
        let tree = try TemporaryTree(["f.txt": "data\n"])
        let shell = BuiltinShell(root: tree.url)
        var output = await shell.run("cat f.txt | cat")
        XCTAssertEqual(output.stdout, "data\n")
        output = await shell.run("cat missing || echo fallback")
        XCTAssertEqual(output.stdout, "fallback\n")
        XCTAssertTrue(output.stderr.contains("missing"))
        output = await shell.run("cat missing && echo never")
        XCTAssertEqual(output.stdout, "")
        XCTAssertEqual(output.exitCode, 1)
        output = await shell.run("echo $?")
        XCTAssertEqual(output.stdout, "1\n")
        output = await shell.run("false-command; echo after")
        XCTAssertEqual(output.stdout, "after\n")
        XCTAssertTrue(output.stderr.contains("not available on iPad"))
    }

    func testGlobs() async throws {
        let tree = try TemporaryTree(["a.c": "", "b.c": "", "c.h": "", ".hidden.c": "", "src/x.c": "", "src/y.h": ""])
        let shell = BuiltinShell(root: tree.url)
        var output = await shell.run("echo *.c")
        XCTAssertEqual(output.stdout, "a.c b.c\n")
        output = await shell.run("echo src/*")
        XCTAssertEqual(output.stdout, "src/x.c src/y.h\n")
        output = await shell.run("echo */*.h")
        XCTAssertEqual(output.stdout, "src/y.h\n")
        output = await shell.run("echo '*.c' *.zzz")
        XCTAssertEqual(output.stdout, "*.c *.zzz\n", "quoted and unmatched patterns stay literal")
        output = await shell.run("rm *.h && ls")
        XCTAssertEqual(output.stdout, "a.c\nb.c\nsrc\n")
    }

    func testLsColumnsAndLongFormat() async throws {
        var files: [String: String] = [:]
        for name in ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"] { files[name + ".txt"] = "12345" }
        files["dir/"] = ""
        let tree = try TemporaryTree(files)
        let shell = BuiltinShell(root: tree.url)
        var output = await shell.run("ls", columns: 40, isTerminal: true)
        let lines = output.stdout.split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertLessThan(lines.count, 7, "laid out in columns")
        XCTAssertTrue(output.stdout.contains("\u{1B}[1m\u{1B}[34mdir"), "directories are colored")

        output = await shell.run("ls -l alpha.txt")
        XCTAssertTrue(output.stdout.hasPrefix("-rw"))
        XCTAssertTrue(output.stdout.contains(" 5 "))
        XCTAssertTrue(output.stdout.hasSuffix("alpha.txt\n"))

        output = await shell.run("ls -z")
        XCTAssertEqual(output.exitCode, 2)
    }

    func testHelpClearAndUnknown() async throws {
        let tree = try TemporaryTree()
        let shell = BuiltinShell(root: tree.url)
        var output = await shell.run("help")
        for name in ["ls", "cd", "pwd", "cat", "mkdir", "rm", "mv", "cp", "echo", "clear", "help"] {
            XCTAssertTrue(output.stdout.contains(name), name)
        }
        output = await shell.run("help mv")
        XCTAssertTrue(output.stdout.hasPrefix("mv source"))
        output = await shell.run("clear")
        XCTAssertTrue(output.clearScreen)
        output = await shell.run("gcc main.c")
        XCTAssertEqual(output.exitCode, 127)
        output = await shell.run("echo 'unterminated")
        XCTAssertEqual(output.exitCode, 2)
        let history = await shell.history
        XCTAssertEqual(history.last, "echo 'unterminated")
    }

    func testCustomCommandRegistration() async throws {
        struct Upper: ShellCommand {
            let name = "upper"
            let summary = "Uppercase stdin"
            let usage = "upper"
            func run(_ arguments: [String], context: inout ShellContext) -> Int32 {
                context.write((context.stdin ?? arguments.joined(separator: " ")).uppercased())
                return 0
            }
        }
        let tree = try TemporaryTree()
        let shell = BuiltinShell(root: tree.url)
        await shell.register(Upper())
        let output = await shell.run("echo lemon | upper")
        XCTAssertEqual(output.stdout, "LEMON\n")
    }
}
