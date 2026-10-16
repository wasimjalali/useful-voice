import Foundation

/// Coding category rules.
/// `windows/src/core/formatting/categoryCoding.ts` mirrors this file rule for rule.
///
/// What it does: curly quotes become straight, spoken file names become real ones
/// ("index dot ts" is `index.ts`), "at" or "tag" before one makes a mention (`@index.ts`)
/// and spoken symbols ("slash", "underscore", "dot", "dash dash") become the symbol.
///
/// What it never does: add or remove sentence punctuation, change capitals, or touch a
/// spoken symbol that is not between code-like words. "a dot on the map" and "look at
/// the docs" come out exactly as dictated.
public enum CategoryCoding {
    private static let extensions: Set<String> = [
        "ts", "tsx", "js", "jsx", "json", "md", "py", "swift", "rs", "go", "rb", "java", "kt", "c", "h",
        "cpp", "cs", "css", "html", "yml", "yaml", "toml", "sh", "txt", "lock", "sql",
    ]

    /// Extensions that are also everyday words or letters. "red dot go" is prose; "main dot go"
    /// is a file. These convert only after a name that looks like a file name.
    private static let ambiguousExtensions: Set<String> = ["go", "c", "h", "lock"]

    /// Plain words that are common file names, so "main dot go" converts. Code-like words qualify anyway.
    private static let commonBasenames: Set<String> = [
        "main", "index", "mod", "server", "client", "util", "cargo", "yarn", "package", "pipfile",
        "poetry", "composer", "hello", "foo", "bar", "baz", "run", "setup", "handler", "router",
        "types", "model", "models", "api", "db", "cli", "cmd", "parser", "helper", "helpers", "common",
        "init", "start", "example", "sample", "demo", "script", "readme", "license", "makefile",
    ]

    /// A path made only of "~", "." and ".." parts ("~", "..", "../.."). Not a word, but it
    /// joins a spoken slash: "cd ~ slash projects" is `cd ~/projects`.
    private static func isPathRoot(_ t: Tok) -> Bool {
        if let built = t.built { return built.root }
        let parts = t.core.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.enumerated().allSatisfy { i, p in
            p == "." || p == ".." || (p == "~" && i == 0) || (p.isEmpty && i > 0 && i == parts.count - 1)
        }
    }

    /// Names that are a dot file when spoken alone: "dot gitignore" is `.gitignore`. They are
    /// not in `extensions`: "copy dot env" is "copy .env", never `copy.env`.
    private static let dotfiles: Set<String> = [
        "env", "gitignore", "gitattributes", "npmrc", "nvmrc", "eslintrc", "prettierrc", "editorconfig",
        "dockerignore", "babelrc", "zshrc", "bashrc",
    ]

    /// Words that are never a code name next to a spoken symbol: articles, pronouns, shell verbs.
    private static let notNames: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "his", "her", "its", "our",
        "their", "of", "in", "on", "at", "to", "for", "and", "or", "but", "is", "it", "with", "as", "by",
        "from", "i", "we", "you", "he", "she", "they", "be", "are", "was", "were", "am", "been", "have",
        "has", "had", "do", "does", "did", "can", "could", "would", "should", "will", "not", "no", "yes",
        "if", "so", "than", "then", "when", "while", "where", "what", "who", "which", "why", "how", "about",
        "into", "over", "under", "after", "before", "between", "up", "down", "out", "off", "them", "him",
        "me", "us", "there", "here", "now", "just", "also", "only", "very", "more", "most", "some", "any",
        "all", "each", "every", "other", "such",
        "cd", "ls", "cat", "rm", "mv", "cp", "mkdir", "touch", "open", "edit", "use", "type", "press",
        "add", "insert", "put", "say",
    ]

    /// Short lower-case words that are common parts of a snake_case name. A spoken underscore
    /// joins two plain words only when one of them is on this list or otherwise looks like code:
    /// "user underscore id" is `user_id`, "these logs underscore concerns" stays prose.
    private static let identifierParts: Set<String> = [
        "id", "ids", "name", "count", "max", "min", "url", "uri", "api", "db", "var", "tmp", "temp", "user",
        "config", "cfg", "file", "path", "key", "value", "val", "index", "idx", "num", "len", "str", "obj",
        "arr", "dict", "list", "src", "dst", "dir", "err", "msg", "ctx", "req", "res", "ptr", "buf", "env",
        "fn", "func", "init", "foo", "bar", "baz", "type", "size", "utc", "ms", "px", "kb", "mb",
    ]

    /// Words before a spoken slash that let it start a path: "cd slash usr" is `cd /usr`, "move it
    /// to slash tmp" is `to /tmp`. After any other word the slash stays spoken: "we slash build
    /// times" and "20 slash src" are prose.
    private static let slashLeaders: Set<String> = [
        "cd", "ls", "cat", "rm", "mv", "cp", "mkdir", "touch", "open", "edit", "type", "press",
        "add", "insert", "put", "say", "in", "into", "to", "from", "at", "on", "of", "under", "inside",
        "the", "a", "an", "my", "your", "our", "this", "that",
    ]

    /// Plain lower-case folder names that mark a word as part of a path.
    private static let pathWords: Set<String> = [
        "src", "lib", "app", "bin", "usr", "etc", "var", "tmp", "home", "dist", "build", "docs", "test",
        "tests", "public", "packages", "scripts", "utils", "config", "node_modules", "components", "pages",
        "sources", "tools", "assets", "users", "opt", "mnt", "library", "documents", "downloads",
        "applications", "volumes", "projects", "repos", "workspace",
    ]

    private static let symbolText: [String: String] = ["dot": ".", "slash": "/", "underscore": "_"]

    private static let leadChars: Set<Character> = ["\"", "'", "(", "[", "{", "`", "<"]
    private static let trailChars: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'", "`", ">", "\u{2026}"]
    private static let namePunct: Set<Character> = ["_", "-", "/", ".", "~", "@"]

    /// What is known about a word that convertSymbols built by joining words and symbols. Kept so
    /// a long chain ("src slash src slash ...") never rescans the growing word: linear time.
    private struct Built {
        /// Holds a letter or digit (so it is a name word).
        var alnum: Bool
        /// Only ASCII letters, digits, "_" and "-".
        var ident: Bool
        /// Only "~", "." and ".." parts (see isPathRoot).
        var root: Bool
        /// Ends in "/".
        var endsSlash: Bool
    }

    /// One whitespace-separated word, split into the punctuation around it and its core.
    private struct Tok {
        /// The whitespace before the word.
        var sep: String
        var lead: String
        var core: String
        var trail: String
        /// True when the word is, or ends in, a file name this pass built.
        var file: Bool
        /// Set on words convertSymbols built. Such a word always holds a symbol, so it is code-like.
        var built: Built? = nil
    }

    public static func straightenQuotes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    private static func isNameCore(_ core: String) -> Bool {
        if core.isEmpty { return false }
        var alnum = false
        for c in core {
            if CategoryText.isAlnum(c) { alnum = true } else if !namePunct.contains(c) { return false }
        }
        return alnum
    }

    private static func tokenizeLine(_ line: String) -> (toks: [Tok], tail: String) {
        let cs = Array(line)
        var toks: [Tok] = []
        var i = 0
        var sep = ""
        while i < cs.count {
            if CategoryText.isWS(cs[i]) {
                sep.append(cs[i])
                i += 1
                continue
            }
            var j = i
            while j < cs.count && !CategoryText.isWS(cs[j]) { j += 1 }
            let run = Array(cs[i..<j])
            var a = 0
            var b = run.count
            while a < b && leadChars.contains(run[a]) { a += 1 }
            while b > a && trailChars.contains(run[b - 1]) { b -= 1 }
            if a == b {
                toks.append(Tok(sep: sep, lead: "", core: String(run), trail: "", file: false))
            } else {
                toks.append(Tok(sep: sep, lead: String(run[0..<a]), core: String(run[a..<b]),
                                trail: String(run[b...]), file: false))
            }
            sep = ""
            i = j
        }
        return (toks, sep)
    }

    private static func symbolWord(_ t: Tok) -> String? {
        if !t.lead.isEmpty || !t.trail.isEmpty { return nil }
        let word = t.core.lowercased()
        return word == "dot" || word == "slash" || word == "underscore" ? word : nil
    }

    private static func isDash(_ t: Tok) -> Bool {
        t.lead.isEmpty && t.trail.isEmpty && t.core.lowercased() == "dash"
    }

    private static func isSpokenSymbol(_ t: Tok) -> Bool { symbolWord(t) != nil || isDash(t) }

    /// A word that can sit next to a spoken symbol: a name core that is not an article, verb or symbol.
    private static func isNameWord(_ t: Tok) -> Bool {
        if let built = t.built { return built.alnum }
        return isNameCore(t.core) && !notNames.contains(t.core.lowercased()) && !isSpokenSymbol(t)
    }

    private static func isCodeLike(_ t: Tok) -> Bool {
        if t.file || t.built != nil { return true }
        for (i, c) in t.core.enumerated() {
            if c == "_" || c == "/" || c == "." || c == "~" || c == "@" { return true }
            if CategoryText.isDigit(c) { return true }
            if i > 0 && c.isUppercase { return true }
        }
        return pathWords.contains(t.core.lowercased())
    }

    /// ASCII letters, digits, "_" and "-" only: the shape of a variable, function or flag name.
    private static func isIdentifierShaped(_ t: Tok) -> Bool {
        if let built = t.built { return built.ident }
        if t.core.isEmpty { return false }
        return t.core.allSatisfy { c in
            c == "_" || c == "-" || (c.isASCII && CategoryText.isAlnum(c))
        }
    }

    /// Whether a word can be part of a path. Bare numbers cannot: "slash 20 percent" is prose.
    private static func isPathish(_ t: Tok) -> Bool {
        if t.file || t.built != nil { return true }
        if t.core.contains(where: { $0 == "/" || $0 == "." || $0 == "_" || $0 == "~" || $0 == "@" }) { return true }
        return t.core.contains { !CategoryText.isDigit($0) && CategoryText.isAlnum($0) }
    }

    /// Whether a word next to a spoken underscore is clearly part of a code name: it holds a
    /// digit, an underscore or an inner capital, or it is a common identifier part ("id").
    private static func isUnderscoreCodeLike(_ t: Tok) -> Bool {
        if t.built != nil { return true }
        for (i, c) in t.core.enumerated() {
            if c == "_" || CategoryText.isDigit(c) { return true }
            if i > 0 && c.isUppercase { return true }
        }
        return identifierParts.contains(t.core)
    }

    private static func hasAlnum(_ t: Tok) -> Bool {
        if let built = t.built { return built.alnum }
        return t.core.contains(where: CategoryText.isAlnum)
    }

    private static func endsWithSlash(_ t: Tok) -> Bool {
        if let built = t.built { return built.endsSlash }
        return t.core.last == "/"
    }

    /// A written file name ("src/app.tsx", "my_util.py") clear enough to mention after "at": its
    /// name holds a "/", "_", digit or inner capital, starts in lower case, and has a lower-case
    /// known extension. "meet at index.html" and "looking at Next.js" stay prose.
    private static func isCodeFileName(_ core: String) -> Bool {
        if !looksLikeFileName(core) { return false }
        let cs = Array(core)
        guard let dot = cs.lastIndex(of: ".") else { return false }
        let ext = String(cs[(dot + 1)...])
        if ext != ext.lowercased() || cs[0].isUppercase { return false }
        for i in 0..<dot {
            let c = cs[i]
            if c == "/" || c == "_" || CategoryText.isDigit(c) { return true }
            if i > 0 && c.isUppercase { return true }
        }
        return false
    }

    /// Whether a name can stand in front of an ambiguous extension such as ".go".
    private static func isFileBase(_ t: Tok) -> Bool {
        isCodeLike(t) || commonBasenames.contains(t.core.lowercased())
    }

    /// "index.ts", "src/app.tsx": a name that already ends in a known extension.
    private static func looksLikeFileName(_ core: String) -> Bool {
        let cs = Array(core)
        guard let dot = cs.lastIndex(of: "."), dot > 0, cs[0] != "@" else { return false }
        let after = String(cs[(dot + 1)...]).lowercased()
        return extensions.contains(after) && cs[dot - 1] != "/"
    }

    /// "index dot ts" and "foo dot test dot ts" become `index.ts` and `foo.test.ts`.
    private static func convertFileNames(_ toks: [Tok]) -> [Tok] {
        var out: [Tok] = []
        var i = 0
        while i < toks.count {
            let first = toks[i]
            var e = i
            if isNameWord(first) && first.trail.isEmpty && i + 2 < toks.count {
                // Walk "name dot name dot name ...", stopping at a word that carries trailing punctuation.
                while e + 2 < toks.count
                        && toks[e].trail.isEmpty
                        && symbolWord(toks[e + 1]) == "dot"
                        && isNameWord(toks[e + 2])
                        && toks[e + 2].lead.isEmpty {
                    e += 2
                }
            }
            if e == i {
                out.append(first)
                i += 1
                continue
            }
            let ext = toks[e].core.lowercased()
            let valid = extensions.contains(ext)
                && (!ambiguousExtensions.contains(ext) || isFileBase(toks[e - 2]))
            if !valid {
                // Every shorter chain ends at the same word, so it fails the same way: skip them all.
                for k in i...e { out.append(toks[k]) }
                i = e + 1
                continue
            }
            var parts: [String] = []
            var k = i
            while k <= e {
                parts.append(toks[k].core)
                k += 2
            }
            parts[parts.count - 1] = ext
            out.append(Tok(sep: first.sep, lead: first.lead, core: parts.joined(separator: "."),
                           trail: toks[e].trail, file: true))
            i = e + 1
        }
        return out
    }

    /// "dash dash help" becomes `--help`.
    private static func convertFlags(_ toks: [Tok]) -> [Tok] {
        var out: [Tok] = []
        var i = 0
        while i < toks.count {
            let first = toks[i]
            if isDash(first), i + 2 < toks.count, isDash(toks[i + 1]),
               isNameWord(toks[i + 2]), toks[i + 2].lead.isEmpty {
                let third = toks[i + 2]
                out.append(Tok(sep: first.sep, lead: "", core: "--" + third.core, trail: third.trail, file: false))
                i += 3
            } else {
                out.append(first)
                i += 1
            }
        }
        return out
    }

    /// "src slash app", "foo underscore bar", "dot slash src", "dot env".
    private static func convertSymbols(_ toks: [Tok]) -> [Tok] {
        var out: [Tok] = []
        var i = 0
        while i < toks.count {
            let tok = toks[i]
            if symbolWord(tok) == nil {
                out.append(tok)
                i += 1
                continue
            }
            var j = i
            var text = ""
            var dots = 0
            var slashes = 0
            var underscores = 0
            while j < toks.count, let word = symbolWord(toks[j]) {
                text += symbolText[word] ?? ""
                if word == "dot" { dots += 1 } else if word == "slash" { slashes += 1 } else { underscores += 1 }
                j += 1
            }
            var left: Tok? = nil
            if let lastOut = out.last, lastOut.trail.isEmpty,
               isNameWord(lastOut) || (slashes > 0 && isPathRoot(lastOut)) {
                left = lastOut
            }
            var right: Tok? = nil
            if j < toks.count, toks[j].lead.isEmpty, isNameWord(toks[j]) || (slashes > 0 && isPathRoot(toks[j])) {
                right = toks[j]
            }
            let runLength = j - i

            // Around a slash, only path-like words join: "slash 20 percent" is prose.
            if slashes > 0 {
                if let l = left, !isPathish(l) { left = nil }
                if let r = right, !isPathish(r) { right = nil }
            }
            // A spoken "./" or "../" starts a path, so it never joins the word before it:
            // "run dot slash build" is `run ./build`.
            if symbolWord(tok) == "dot" && slashes > 0 { left = nil }
            // "copy dot env": a dot file on its own, not joined to the word before it.
            var dotFile = false
            if dots == 1 && runLength == 1, let r = right, dotfiles.contains(r.core.lowercased()) {
                dotFile = left == nil || !isCodeLike(left!)
            }
            if dotFile { left = nil }

            var allowed = false
            if underscores == runLength {
                // Both sides must look like identifiers, and one side like code: "the underscore key" and
                // "logs underscore concerns" are prose, "user underscore id" is `user_id`. Two or more
                // underscores ("underscore underscore init") are code on their own.
                let identifiers = (left == nil || isIdentifierShaped(left!))
                    && (right == nil || isIdentifierShaped(right!))
                var pair = false
                if let l = left, let r = right { pair = isUnderscoreCodeLike(l) || isUnderscoreCodeLike(r) }
                allowed = identifiers && (pair || (runLength >= 2 && (left != nil || right != nil)))
            } else if dots > 0 && slashes > 0 {
                allowed = true
            } else if dotFile {
                allowed = true
            } else if let l = left, let r = right {
                // Around a slash the left word itself must be path-like: "run slash test" is prose.
                allowed = slashes > 0 ? isCodeLike(l) || isPathRoot(l) : isCodeLike(l) || isCodeLike(r)
            } else if slashes == runLength && left == nil && right != nil {
                // A leading slash only where nothing, punctuation or a path-taking word comes before it.
                var leads = true
                if let lastOut = out.last {
                    leads = !lastOut.trail.isEmpty
                        || (lastOut.built == nil && slashLeaders.contains(lastOut.core.lowercased()))
                }
                allowed = leads && isCodeLike(right!)
            }

            if !allowed {
                for k in i..<j { out.append(toks[k]) }
                i = j
                continue
            }
            if left != nil { out.removeLast() }
            let base = left ?? Tok(sep: tok.sep, lead: "", core: "", trail: "", file: false)
            let onlyUnderscores = underscores == runLength
            var root = false
            if let l = left, isPathRoot(l), !endsWithSlash(l), text == "/" {
                // Root parts joined by one slash: ".." + "/" + ".." is still a root.
                if let r = right { root = isPathRoot(r) && r.core.first != "~" } else { root = true }
            }
            let built = Built(
                alnum: (left.map(hasAlnum) ?? false) || (right.map(hasAlnum) ?? false),
                ident: onlyUnderscores && (left.map(isIdentifierShaped) ?? true)
                    && (right.map(isIdentifierShaped) ?? true),
                root: root,
                endsSlash: right.map(endsWithSlash) ?? text.hasSuffix("/"))
            out.append(Tok(sep: base.sep, lead: base.lead,
                           core: base.core + text + (right?.core ?? ""),
                           trail: right?.trail ?? "",
                           file: right?.file ?? false,
                           built: built))
            i = right != nil ? j + 1 : j
        }
        return out
    }

    /// "tag index.ts", "at index dot ts" and "at src/app.tsx" become mentions. "tag" always makes
    /// one, and so does a file name spelled out by speech. After "at" a written name must look
    /// like code (isCodeFileName), so "looking at Next.js" stays prose.
    private static func convertMentions(_ toks: [Tok]) -> [Tok] {
        var out: [Tok] = []
        var i = 0
        while i < toks.count {
            let tok = toks[i]
            let word = tok.core.lowercased()
            if tok.lead.isEmpty, tok.trail.isEmpty, word == "at" || word == "tag",
               i + 1 < toks.count, toks[i + 1].lead.isEmpty,
               toks[i + 1].file
                || (word == "tag" ? looksLikeFileName(toks[i + 1].core) : isCodeFileName(toks[i + 1].core)) {
                let next = toks[i + 1]
                out.append(Tok(sep: tok.sep, lead: "", core: "@" + next.core, trail: next.trail, file: true))
                i += 2
            } else {
                out.append(tok)
                i += 1
            }
        }
        return out
    }

    private static func renderLine(_ toks: [Tok], tail: String) -> String {
        toks.map { $0.sep + $0.lead + $0.core + $0.trail }.joined() + tail
    }

    /// Applies every Coding rule. Line breaks and spacing are kept as dictated.
    public static func format(_ text: String) -> String {
        let lines = CategoryText.splitLines(straightenQuotes(text))
        return lines.map { line -> String in
            let (toks, tail) = tokenizeLine(line)
            let converted = convertMentions(convertSymbols(convertFlags(convertFileNames(toks))))
            return renderLine(converted, tail: tail)
        }.joined(separator: "\n")
    }
}
