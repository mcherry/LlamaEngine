import Foundation

/// A tiny, dependency-free syntax tokenizer for fenced code blocks. It splits source
/// into coarse spans — keywords, strings, comments, numbers, and plain text — which the
/// renderer colors. This is deliberately *lexical and approximate*, not a real parser:
/// it's good enough to make LLM code replies readable without a heavyweight grammar.
///
/// Pure and synchronous, so it is unit-tested. Tolerant of partial input (an unclosed
/// string or comment runs to the end), which matters while a reply is still streaming.
/// Unknown languages return a single plain span so prose is never mis-highlighted.
public enum SyntaxHighlighter {
    public enum Kind: Equatable {
        case plain, keyword, string, comment, number
    }

    public struct Token: Equatable {
        public let kind: Kind
        public let text: String
    }

    /// Tokenizes `code` for the given language. Returns one `.plain` token spanning the
    /// whole input when the language is unknown or unspecified.
    public static func tokens(_ code: String, language: String?) -> [Token] {
        guard let profile = resolvedProfile(for: language, code: code) else {
            return code.isEmpty ? [] : [Token(kind: .plain, text: code)]
        }

        let chars = Array(code)
        let n = chars.count
        var tokens: [Token] = []
        var pending = ""
        var i = 0

        func flush() {
            if !pending.isEmpty {
                tokens.append(Token(kind: .plain, text: pending))
                pending = ""
            }
        }
        func emit(_ kind: Kind, _ text: String) {
            flush()
            tokens.append(Token(kind: kind, text: text))
        }

        while i < n {
            let c = chars[i]

            // Block comment (e.g. /* ... */) — may run to end if unterminated.
            if let block = profile.blockComment, matches(chars, i, block.open) {
                let start = i
                i += block.open.count
                while i < n, !matches(chars, i, block.close) { i += 1 }
                if i < n { i += block.close.count }
                emit(.comment, String(chars[start..<i]))
                continue
            }

            // Line comment (e.g. //, #, --) — to end of line.
            if let token = profile.lineComments.first(where: { matches(chars, i, $0) }) {
                _ = token
                let start = i
                while i < n, chars[i] != "\n" { i += 1 }
                emit(.comment, String(chars[start..<i]))
                continue
            }

            // Triple-quoted string (Swift/Python multiline).
            if profile.tripleQuotes, let delim = tripleDelimiter(chars, i, profile) {
                let start = i
                i += 3
                while i < n, !matches(chars, i, delim) {
                    i += (chars[i] == "\\" && i + 1 < n) ? 2 : 1
                }
                if i < n { i += 3 }
                emit(.string, String(chars[start..<i]))
                continue
            }

            // Single-line string with the profile's delimiters (handles backslash escapes).
            if profile.stringDelimiters.contains(c) {
                let start = i
                i += 1
                while i < n, chars[i] != c, chars[i] != "\n" {
                    i += (chars[i] == "\\" && i + 1 < n) ? 2 : 1
                }
                if i < n, chars[i] == c { i += 1 }
                emit(.string, String(chars[start..<i]))
                continue
            }

            // Number literal.
            if c.isNumber || (c == "." && i + 1 < n && chars[i + 1].isNumber
                              && (i == 0 || !isIdentChar(chars[i - 1]))) {
                let start = i
                i = scanNumber(chars, i)
                emit(.number, String(chars[start..<i]))
                continue
            }

            // Identifier / keyword.
            if isIdentStart(c) {
                let start = i
                i += 1
                while i < n, isIdentChar(chars[i]) { i += 1 }
                let word = String(chars[start..<i])
                let lookup = profile.caseInsensitiveKeywords ? word.lowercased() : word
                if profile.keywords.contains(lookup) {
                    emit(.keyword, word)
                } else {
                    pending += word
                }
                continue
            }

            pending.append(c)
            i += 1
        }
        flush()
        return tokens
    }

    // MARK: - Scanning helpers

    private static func scanNumber(_ chars: [Character], _ start: Int) -> Int {
        let n = chars.count
        var i = start
        // Hex / binary / octal prefix.
        if chars[i] == "0", i + 1 < n, "xXbBoO".contains(chars[i + 1]) {
            i += 2
            while i < n, chars[i].isHexDigit || chars[i] == "_" { i += 1 }
            return i
        }
        while i < n, chars[i].isNumber || chars[i] == "_" { i += 1 }
        if i < n, chars[i] == ".", i + 1 < n, chars[i + 1].isNumber {
            i += 1
            while i < n, chars[i].isNumber || chars[i] == "_" { i += 1 }
        }
        if i < n, chars[i] == "e" || chars[i] == "E" {
            var j = i + 1
            if j < n, chars[j] == "+" || chars[j] == "-" { j += 1 }
            if j < n, chars[j].isNumber {
                i = j
                while i < n, chars[i].isNumber || chars[i] == "_" { i += 1 }
            }
        }
        return i
    }

    private static func tripleDelimiter(_ chars: [Character], _ i: Int, _ profile: Profile) -> String? {
        if profile.stringDelimiters.contains("\""), matches(chars, i, "\"\"\"") { return "\"\"\"" }
        if profile.stringDelimiters.contains("'"), matches(chars, i, "'''") { return "'''" }
        return nil
    }

    private static func matches(_ chars: [Character], _ i: Int, _ token: String) -> Bool {
        let t = Array(token)
        guard i + t.count <= chars.count else { return false }
        for k in 0..<t.count where chars[i + k] != t[k] { return false }
        return true
    }

    private static func isIdentStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
    private static func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    // MARK: - Language profiles

    struct Profile {
        var keywords: Set<String>
        var caseInsensitiveKeywords = false
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var stringDelimiters: [Character] = ["\""]
        var tripleQuotes = false
    }

    /// The profile to tokenize with. A specific language profile when recognized; a
    /// generic fallback (strings, numbers, universal keywords, sniffed comments) for an
    /// unrecognized but explicitly *tagged* language, so obscure languages still get some
    /// color; or `nil` for untagged blocks and deliberately-plain tags (`text`, `output`,
    /// `log`, `diff`, `mermaid`, …) so fixed-width output stays uncolored.
    static func resolvedProfile(for language: String?, code: String) -> Profile? {
        if let specific = profile(for: language) { return specific }
        guard let raw = language?.lowercased().trimmingCharacters(in: .whitespaces),
              !raw.isEmpty, !plainOutputTags.contains(raw) else { return nil }
        return genericProfile(sniffedFrom: code)
    }

    /// Language tags that are really fixed-width output, not code — kept plain even though
    /// they carry a tag, so logs, transcripts, and diffs aren't speckled with color.
    static let plainOutputTags: Set<String> = [
        "text", "plaintext", "plain", "txt", "output", "console", "log", "logs",
        "none", "raw", "ansi", "term", "terminal", "diff", "patch", "markdown", "md", "mermaid"
    ]

    /// A conservative generic profile for an unknown language: universal keywords, common
    /// string delimiters, a C-style block comment, and a line-comment marker *sniffed*
    /// from the code so dialects like assembly (`;`) or shell-ish (`#`) get the right
    /// comment style instead of a fixed guess.
    static func genericProfile(sniffedFrom code: String) -> Profile {
        Profile(keywords: universalKeywords,
                lineComments: sniffedLineComments(code),
                blockComment: ("/*", "*/"),
                stringDelimiters: ["\"", "'"])
    }

    /// Tallies which comment markers begin lines (after indentation) and returns the
    /// dominant one, always including `//` when present since it's near-zero
    /// false-positive. Falls back to `//` when nothing stands out.
    static func sniffedLineComments(_ code: String) -> [String] {
        let candidates = ["//", "--", "#", ";", "%"]
        var counts: [String: Int] = [:]
        for line in code.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let marker = candidates.first(where: { trimmed.hasPrefix($0) }) {
                counts[marker, default: 0] += 1
            }
        }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return ["//"] }
        var markers = [best]
        if best != "//", (counts["//"] ?? 0) > 0 { markers.append("//") }
        return markers
    }

    /// Resolves a language tag (incl. common aliases) to a profile, or `nil` when the
    /// language is unknown so the caller renders it as plain text.
    static func profile(for language: String?) -> Profile? {
        guard let raw = language?.lowercased().trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }

        switch raw {
        case "swift":
            return Profile(keywords: swiftKeywords, lineComments: ["//"],
                           blockComment: ("/*", "*/"), stringDelimiters: ["\""], tripleQuotes: true)
        case "python", "py":
            return Profile(keywords: pythonKeywords, lineComments: ["#"],
                           stringDelimiters: ["\"", "'"], tripleQuotes: true)
        case "javascript", "js", "jsx", "typescript", "ts", "tsx":
            return Profile(keywords: jsKeywords, lineComments: ["//"],
                           blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"])
        case "json":
            return Profile(keywords: ["true", "false", "null"], stringDelimiters: ["\""])
        case "go", "golang":
            return Profile(keywords: goKeywords, lineComments: ["//"],
                           blockComment: ("/*", "*/"), stringDelimiters: ["\"", "`"])
        case "rust", "rs":
            return Profile(keywords: rustKeywords, lineComments: ["//"],
                           blockComment: ("/*", "*/"), stringDelimiters: ["\""])
        case "c", "cpp", "c++", "objc", "objective-c", "h", "hpp":
            return Profile(keywords: cKeywords, lineComments: ["//"],
                           blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'"])
        case "java", "kotlin", "kt", "scala":
            return Profile(keywords: javaKeywords, lineComments: ["//"],
                           blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'"])
        case "ruby", "rb":
            return Profile(keywords: rubyKeywords, lineComments: ["#"],
                           stringDelimiters: ["\"", "'"])
        case "sql":
            return Profile(keywords: sqlKeywords, caseInsensitiveKeywords: true,
                           lineComments: ["--"], blockComment: ("/*", "*/"),
                           stringDelimiters: ["'"])
        case "bash", "sh", "zsh", "shell":
            return Profile(keywords: shellKeywords, lineComments: ["#"],
                           stringDelimiters: ["\"", "'"])
        case "asm", "assembly", "nasm", "masm", "gas", "x86", "x86asm", "arm", "armasm", "aarch64":
            return Profile(keywords: assemblyKeywords, caseInsensitiveKeywords: true,
                           lineComments: [";", "#", "//"], blockComment: ("/*", "*/"),
                           stringDelimiters: ["\"", "'"])
        default:
            return nil
        }
    }

    // MARK: - Keyword sets

    private static let swiftKeywords: Set<String> = [
        "let", "var", "func", "if", "else", "guard", "return", "for", "while", "repeat",
        "in", "switch", "case", "default", "break", "continue", "do", "try", "catch",
        "throw", "throws", "rethrows", "enum", "struct", "class", "protocol", "extension",
        "init", "deinit", "self", "Self", "super", "nil", "true", "false", "import",
        "public", "private", "internal", "fileprivate", "open", "static", "final", "lazy",
        "weak", "unowned", "mutating", "nonmutating", "override", "convenience", "required",
        "associatedtype", "typealias", "where", "as", "is", "some", "any", "inout",
        "defer", "async", "await", "actor", "subscript", "willSet", "didSet", "get", "set"]

    private static let pythonKeywords: Set<String> = [
        "def", "class", "return", "if", "elif", "else", "for", "while", "break", "continue",
        "pass", "import", "from", "as", "with", "try", "except", "finally", "raise",
        "lambda", "yield", "global", "nonlocal", "del", "assert", "in", "is", "not", "and",
        "or", "None", "True", "False", "async", "await", "match", "case", "self"]

    private static let jsKeywords: Set<String> = [
        "function", "return", "if", "else", "for", "while", "do", "break", "continue",
        "switch", "case", "default", "var", "let", "const", "new", "delete", "typeof",
        "instanceof", "in", "of", "this", "class", "extends", "super", "import", "export",
        "from", "as", "try", "catch", "finally", "throw", "async", "await", "yield",
        "true", "false", "null", "undefined", "void", "interface", "type", "enum",
        "implements", "public", "private", "protected", "readonly", "static", "get", "set"]

    private static let goKeywords: Set<String> = [
        "func", "return", "if", "else", "for", "range", "break", "continue", "switch",
        "case", "default", "var", "const", "type", "struct", "interface", "map", "chan",
        "go", "defer", "select", "package", "import", "nil", "true", "false", "iota"]

    private static let rustKeywords: Set<String> = [
        "fn", "let", "mut", "return", "if", "else", "for", "while", "loop", "break",
        "continue", "match", "struct", "enum", "trait", "impl", "use", "mod", "pub",
        "crate", "self", "super", "as", "ref", "move", "dyn", "async", "await", "where",
        "type", "const", "static", "unsafe", "true", "false", "Some", "None", "Ok", "Err"]

    private static let cKeywords: Set<String> = [
        "int", "char", "float", "double", "void", "long", "short", "unsigned", "signed",
        "const", "static", "struct", "union", "enum", "typedef", "sizeof", "return", "if",
        "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
        "goto", "extern", "register", "volatile", "inline", "class", "public", "private",
        "protected", "virtual", "template", "namespace", "using", "new", "delete", "this",
        "true", "false", "nullptr", "NULL", "auto", "bool"]

    private static let javaKeywords: Set<String> = [
        "public", "private", "protected", "class", "interface", "extends", "implements",
        "static", "final", "void", "int", "long", "double", "float", "boolean", "char",
        "byte", "short", "return", "if", "else", "for", "while", "do", "switch", "case",
        "default", "break", "continue", "new", "this", "super", "import", "package", "try",
        "catch", "finally", "throw", "throws", "true", "false", "null", "instanceof",
        "abstract", "enum", "val", "var", "fun", "when", "object"]

    private static let rubyKeywords: Set<String> = [
        "def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until",
        "for", "break", "next", "return", "yield", "do", "begin", "rescue", "ensure",
        "raise", "then", "case", "when", "self", "nil", "true", "false", "and", "or", "not",
        "require", "require_relative", "attr_accessor", "attr_reader", "attr_writer"]

    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "update", "delete", "create", "table",
        "drop", "alter", "add", "column", "join", "inner", "outer", "left", "right", "on",
        "group", "by", "order", "having", "limit", "offset", "union", "all", "distinct",
        "as", "and", "or", "not", "null", "is", "in", "like", "between", "values", "set",
        "primary", "key", "foreign", "references", "default", "index", "view", "asc", "desc"]

    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
        "in", "function", "return", "break", "continue", "local", "export", "readonly",
        "echo", "then", "select", "until"]

    /// A broad union of keywords common across many languages, used by the generic
    /// fallback so an unrecognized-but-tagged language still gets keyword color.
    private static let universalKeywords: Set<String> = [
        "if", "else", "elif", "elsif", "for", "foreach", "while", "do", "loop", "switch",
        "case", "default", "break", "continue", "return", "yield", "goto", "when", "then",
        "end", "begin", "fi", "done", "esac", "until",
        "function", "func", "def", "fn", "sub", "proc", "procedure", "lambda", "macro",
        "class", "struct", "enum", "union", "interface", "trait", "protocol", "record",
        "object", "module", "namespace", "package",
        "import", "include", "require", "use", "using", "from", "as", "export", "extern",
        "extends", "implements",
        "public", "private", "protected", "internal", "static", "const", "final",
        "abstract", "virtual", "override",
        "let", "var", "val", "dim", "local", "global", "auto", "register", "volatile", "mutable",
        "new", "delete", "sizeof", "typeof", "typedef", "type", "template",
        "true", "false", "null", "nil", "none", "void", "undefined",
        "self", "this", "super", "base",
        "try", "catch", "except", "finally", "throw", "throws", "raise", "defer", "ensure", "rescue",
        "and", "or", "not", "in", "is", "of"]

    /// x86-64 and ARM mnemonics, directives, and registers for `asm`-tagged blocks.
    /// Matched case-insensitively so `MOV`/`mov` and `RAX`/`rax` both color.
    private static let assemblyKeywords: Set<String> = {
        var words: Set<String> = [
            // x86 data / arithmetic / logic
            "mov", "movabs", "movzx", "movsx", "movsxd", "lea", "push", "pop", "xchg", "bswap",
            "add", "adc", "sub", "sbb", "mul", "imul", "div", "idiv", "inc", "dec", "neg",
            "and", "or", "xor", "not", "shl", "shr", "sal", "sar", "rol", "ror", "cmp", "test",
            // x86 control flow
            "jmp", "je", "jne", "jz", "jnz", "jg", "jge", "jl", "jle", "ja", "jae", "jb", "jbe",
            "jo", "jno", "js", "jns", "jc", "jnc", "call", "ret", "leave", "enter", "loop",
            "int", "syscall", "sysret", "nop", "hlt", "cpuid", "rdtsc", "cld", "std", "cli", "sti",
            "cbw", "cwde", "cdqe", "cwd", "cdq", "cqo", "sete", "setne", "setg", "setl",
            "cmove", "cmovne", "pushfq", "popfq",
            // ARM / AArch64
            "ldr", "ldp", "str", "stp", "ldrb", "strb", "ldrh", "strh", "adr", "adrp",
            "b", "bl", "blr", "br", "cbz", "cbnz", "tbz", "tbnz", "movz", "movk", "movn",
            "madd", "msub", "sdiv", "udiv", "orr", "eor", "bic", "lsl", "lsr", "asr",
            "cmn", "tst", "ccmp", "csel", "cset", "bfi", "ubfx", "sbfx", "svc", "mrs", "msr",
            // directives (NASM / GAS without the leading dot)
            "section", "global", "globl", "extern", "db", "dw", "dd", "dq", "dt",
            "resb", "resw", "resd", "resq", "equ", "times", "align", "bits", "org", "default",
            "byte", "word", "dword", "qword", "ptr", "offset",
            // segment / special registers
            "rip", "eflags", "rflags", "cs", "ds", "es", "fs", "gs", "ss",
            "sp", "lr", "pc", "xzr", "wzr", "fp", "ip",
            // x86 named registers
            "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp",
            "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp",
            "ax", "bx", "cx", "dx", "al", "bl", "cl", "dl", "ah", "bh", "ch", "dh"]
        for i in 8...15 { words.insert("r\(i)"); words.insert("r\(i)d"); words.insert("r\(i)b"); words.insert("r\(i)w") }
        for i in 0...31 { words.insert("xmm\(i)"); words.insert("ymm\(i)") }
        for i in 0...30 { words.insert("x\(i)"); words.insert("w\(i)") }
        for i in 0...15 { words.insert("r\(i)") }
        return words
    }()
}
