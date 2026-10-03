import Foundation
@testable import LemonText
@testable import LemonTextCore
import Testing

@Suite("Language detection")
struct LanguageDetectionTests {
    @Test(arguments: [
        ("main.c", LemonLanguage.c),
        ("sqlite3.c", .c),
        ("engine.cpp", .cpp),
        ("engine.cc", .cpp),
        ("vector.hpp", .cpp),
        ("kernel.cu", .cpp),
        ("AppDelegate.m", .objectiveC),
        ("Bridge.mm", .objectiveC),
        ("ContentView.swift", .swift),
        ("train.py", .python),
        ("index.js", .javascript),
        ("module.mjs", .javascript),
        ("App.jsx", .javascript),
        ("server.ts", .typescript),
        ("Button.tsx", .tsx),
        ("lib.rs", .rust),
        ("main.go", .go),
        ("toolchain.cmake", .cmake),
        ("rules.mk", .make),
        ("README.md", .markdown),
        ("package.json", .json),
        ("ci.yml", .yaml),
        ("config.yaml", .yaml),
        ("index.html", .html),
        ("site.css", .css),
        ("build.sh", .shell),
        ("notes.txt", .plainText),
        ("LICENSE", .plainText)
    ])
    func detectsByExtension(fileName: String, expected: LemonLanguage) {
        #expect(LanguageDetector.language(forFileName: fileName) == expected)
    }

    @Test func detectsExactFileNames() {
        #expect(LanguageDetector.language(forFileName: "CMakeLists.txt") == .cmake)
        #expect(LanguageDetector.language(forFileName: "/src/project/cmakelists.txt") == .cmake)
        #expect(LanguageDetector.language(forFileName: "Makefile") == .make)
        #expect(LanguageDetector.language(forFileName: "GNUmakefile") == .make)
        #expect(LanguageDetector.language(forFileName: "Makefile.am") == .make)
        #expect(LanguageDetector.language(forFileName: ".zshrc") == .shell)
        #expect(LanguageDetector.language(forFileName: "Package.swift") == .swift)
        #expect(LanguageDetector.language(forFileName: ".clang-format") == .yaml)
    }

    @Test func extensionMatchingIsCaseInsensitive() {
        #expect(LanguageDetector.language(forFileName: "MAIN.C") == .c)
        #expect(LanguageDetector.language(forFileName: "Notes.MD") == .markdown)
    }

    @Test func tellsHeaderLanguagesApart() {
        #expect(LanguageDetector.language(forFileName: "sqlite3.h", contents: "#ifndef SQLITE3_H\nint sqlite3_open(const char*);\n") == .c)
        #expect(LanguageDetector.language(forFileName: "View.h", contents: "#import <UIKit/UIKit.h>\n@interface View : UIView\n@end\n") == .objectiveC)
        #expect(LanguageDetector.language(forFileName: "engine.h", contents: "#pragma once\nnamespace lse {\nclass Engine;\n}\n") == .cpp)
        #expect(LanguageDetector.language(forFileName: "plain.h") == .c)
    }

    @Test func detectsShebangs() {
        #expect(LanguageDetector.language(forFileName: "tool", contents: "#!/usr/bin/env python3\nprint('hi')\n") == .python)
        #expect(LanguageDetector.language(forFileName: "run", contents: "#!/bin/bash\necho hi\n") == .shell)
        #expect(LanguageDetector.language(forFileName: "serve", contents: "#!/usr/bin/env -S node --experimental\n") == .javascript)
        #expect(LanguageDetector.language(forFileName: "data", contents: "no shebang here") == .plainText)
    }

    @Test func injectionNamesResolve() {
        #expect(LanguageRegistry.language(forInjectionName: "c++") == .cpp)
        #expect(LanguageRegistry.language(forInjectionName: "sh") == .shell)
        #expect(LanguageRegistry.language(forInjectionName: "yml") == .yaml)
        #expect(LanguageRegistry.language(forInjectionName: "brainfuck") == nil)
    }
}

@Suite("Grammars")
struct GrammarTests {
    @Test(arguments: LemonLanguage.allCases.filter { $0 != .plainText })
    func grammarLoadsAndQueriesCompile(language: LemonLanguage) throws {
        let registry = LanguageRegistry()
        let treeSitterLanguage = try #require(registry.treeSitterLanguage(for: language))
        #expect((13 ... 14).contains(treeSitterLanguage.abiVersion), "\(language) ABI \(treeSitterLanguage.abiVersion)")
        #expect(treeSitterLanguage.highlightsQueryError() == nil, "\(language): \(treeSitterLanguage.highlightsQueryError() ?? "")")
        #expect(treeSitterLanguage.injectionsQueryError() == nil, "\(language): \(treeSitterLanguage.injectionsQueryError() ?? "")")
    }

    @Test func plainTextHasNoGrammar() {
        #expect(LanguageRegistry().treeSitterLanguage(for: .plainText) == nil)
    }

    @Test func markdownInlineInjectionResolves() throws {
        let registry = LanguageRegistry()
        let inline = try #require(registry.treeSitterLanguage(named: "markdown_inline"))
        #expect(inline.highlightsQueryError() == nil)
        #expect(registry.treeSitterLanguage(named: "javascript") != nil)
    }

    @Test func registryCachesLanguages() {
        let registry = LanguageRegistry()
        #expect(registry.treeSitterLanguage(for: .c) === registry.treeSitterLanguage(for: .c))
    }
}

@Suite("Lua pattern predicates")
struct LuaPatternTests {
    @Test func translatesCharacterClasses() throws {
        let pattern = LuaPatternTranslator.regularExpressionPattern(fromLuaPattern: "^[%u@][%u%d_]+$")
        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ string: String) -> Bool {
            regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
        }
        #expect(matches("CMAKE_CXX_FLAGS"))
        #expect(matches("@ONLY"))
        #expect(!matches("lowercase"))
    }

    @Test func translatesEscapesAndLazyQuantifier() {
        #expect(LuaPatternTranslator.regularExpressionPattern(fromLuaPattern: "%.h$") == "\\.h$")
        #expect(LuaPatternTranslator.regularExpressionPattern(fromLuaPattern: "a.-b") == "a.*?b")
        #expect(LuaPatternTranslator.regularExpressionPattern(fromLuaPattern: "%S+") == "[^\\s]+")
    }
}
