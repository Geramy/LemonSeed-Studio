import Foundation

/// Picks a language for a file from its name and, when the name is ambiguous, its first bytes.
public enum LanguageDetector {
    /// Exact file names (compared case-insensitively) that identify a language.
    static let fileNames: [String: LemonLanguage] = [
        "cmakelists.txt": .cmake,
        "makefile": .make,
        "gnumakefile": .make,
        "bsdmakefile": .make,
        ".bashrc": .shell,
        ".bash_profile": .shell,
        ".zshrc": .shell,
        ".zprofile": .shell,
        ".profile": .shell,
        "package.swift": .swift,
        ".clang-format": .yaml,
        ".clang-tidy": .yaml,
        ".clangd": .yaml,
        "readme": .markdown
    ]

    /// File extensions (lower-cased, without the dot) that identify a language.
    static let extensions: [String: LemonLanguage] = [
        "c": .c,
        "h": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "c++": .cpp, "hh": .cpp, "hpp": .cpp, "hxx": .cpp, "h++": .cpp,
        "ipp": .cpp, "inl": .cpp, "tpp": .cpp, "cppm": .cpp, "ixx": .cpp, "cu": .cpp, "cuh": .cpp, "hip": .cpp,
        "m": .objectiveC, "mm": .objectiveC,
        "swift": .swift,
        "py": .python, "pyi": .python, "pyw": .python,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "mts": .typescript, "cts": .typescript,
        "tsx": .tsx,
        "rs": .rust,
        "go": .go,
        "cmake": .cmake,
        "mk": .make, "mak": .make, "make": .make,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown,
        "json": .json, "jsonc": .json, "geojson": .json, "webmanifest": .json,
        "yaml": .yaml, "yml": .yaml,
        "html": .html, "htm": .html, "xhtml": .html,
        "css": .css,
        "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell, "command": .shell
    ]

    /// Detects the language of a file.
    /// - Parameters:
    ///   - fileName: The file name or path. Only the last path component is used.
    ///   - contents: Optional leading contents of the file, used for shebangs and for telling
    ///     C, C++ and Objective-C headers apart. A few kilobytes are enough.
    public static func language(forFileName fileName: String, contents: String? = nil) -> LemonLanguage {
        let name = (fileName as NSString).lastPathComponent
        let lowercasedName = name.lowercased()
        if let language = fileNames[lowercasedName] {
            return language
        }
        if lowercasedName.hasPrefix("makefile.") || lowercasedName.hasSuffix(".makefile") {
            return .make
        }
        if lowercasedName.hasPrefix("dockerfile") {
            return .shell
        }
        let pathExtension = (lowercasedName as NSString).pathExtension
        if pathExtension == "h", let contents {
            return headerLanguage(contents: contents)
        }
        if let language = extensions[pathExtension] {
            return language
        }
        if let contents, let language = language(fromShebangIn: contents) {
            return language
        }
        return .plainText
    }

    /// Detects the language from a `#!` line, e.g. `#!/usr/bin/env python3`.
    public static func language(fromShebangIn contents: String) -> LemonLanguage? {
        guard contents.hasPrefix("#!") else {
            return nil
        }
        let firstLine = contents.prefix { $0 != "\n" && $0 != "\r" }
        let components = firstLine.dropFirst(2).split(separator: " ").map(String.init)
        guard var interpreter = components.first.map({ ($0 as NSString).lastPathComponent }) else {
            return nil
        }
        if interpreter == "env" {
            guard let argument = components.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
                return nil
            }
            interpreter = argument
        }
        switch interpreter {
        case let name where name.hasPrefix("python"):
            return .python
        case "sh", "bash", "zsh", "dash", "ksh":
            return .shell
        case "node", "nodejs", "bun", "deno":
            return .javascript
        case "make", "gmake":
            return .make
        case "swift":
            return .swift
        default:
            return nil
        }
    }

    /// `.h` files are shared by C, C++ and Objective-C. Look for constructs only the latter two have.
    static func headerLanguage(contents: String) -> LemonLanguage {
        let sample = contents.prefix(16_384)
        let objectiveCMarkers = ["@interface", "@protocol", "@implementation", "#import <Foundation", "@property", "NS_ASSUME_NONNULL"]
        if objectiveCMarkers.contains(where: { sample.contains($0) }) {
            return .objectiveC
        }
        let cppMarkers = ["namespace ", "template <", "template<", "\nclass ", "std::", "#include <vector>", "#include <string>",
                          "public:", "private:", "constexpr", "nullptr", "extern \"C++\""]
        if cppMarkers.contains(where: { sample.contains($0) }) {
            return .cpp
        }
        return .c
    }
}
