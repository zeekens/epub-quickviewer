import Foundation

/// Builds a single self-contained HTML page for an EPUB: metadata header,
/// cover, and the full spine content with images inlined as data URIs.
enum PreviewBuilder {
    static let imageBudgetTotal = 24_000_000   // bytes of raw image data, whole book
    static let imageBudgetSingle = 3_000_000   // skip individual images larger than this

    struct Rendering {
        let html: String
        let pages: Int
        let words: Int
    }

    static func render(_ book: EPUBBook, textBudget: Int = 4_000_000) -> Rendering {
        let analysis = book.analyze(textBudget: textBudget)
        let chapters = analysis.chapters
        let truncated = analysis.truncated
        let pages = analysis.pages
        let words = analysis.words

        var imageBudget = imageBudgetTotal
        var body = ""

        // Header ---------------------------------------------------------
        body += "<header class=\"book-header\">"
        if let coverPath = book.coverPath,
           let uri = dataURI(forPath: coverPath, in: book, budget: &imageBudget) {
            body += "<img class=\"cover\" src=\"\(uri)\" alt=\"Cover\">"
        }
        body += "<div class=\"book-meta\">"
        body += "<h1 class=\"book-title\">\(escape(book.title))</h1>"
        if !book.authors.isEmpty {
            body += "<p class=\"book-author\">\(escape(book.authors.joined(separator: ", ")))</p>"
        }
        var facts = ["\(chapters.count) chapter\(chapters.count == 1 ? "" : "s")",
                     "≈ \(pages) page\(pages == 1 ? "" : "s")"]
        if words > 0 { facts.append("\(formatCount(words)) words") }
        if book.isDRMProtected { facts.append("DRM-protected") }
        body += "<p class=\"book-facts\">\(facts.joined(separator: " &nbsp;·&nbsp; "))</p>"
        body += "</div></header>"

        if book.isDRMProtected {
            body += "<p class=\"notice\">This book is DRM-protected; its text cannot be displayed.</p>"
        }

        // Chapter list (anchors) ------------------------------------------
        let titledChapters = chapters.enumerated().filter { $0.element.title != nil }
        let uniqueTitles = Set(titledChapters.map { $0.element.title! })
        if titledChapters.count > 2, uniqueTitles.count > 2 {
            body += "<nav class=\"toc\"><h2>Contents</h2><ol>"
            for (index, chapter) in titledChapters {
                body += "<li><a href=\"#ch\(index)\">\(escape(chapter.title!))</a></li>"
            }
            body += "</ol></nav>"
        }

        // Chapters ---------------------------------------------------------
        for (index, chapter) in chapters.enumerated() {
            let content = rewriteResources(in: sanitize(chapter.bodyHTML),
                                           chapterPath: chapter.zipPath,
                                           book: book, imageBudget: &imageBudget)
            body += "<section class=\"chapter\" id=\"ch\(index)\">\(content)</section>"
        }

        if truncated {
            body += "<p class=\"notice\">Preview truncated — the full book is longer.</p>"
        }

        return Rendering(html: shell(title: book.title, body: body),
                         pages: pages, words: words)
    }

    static func errorHTML(fileName: String, message: String) -> String {
        let body = """
        <header class="book-header"><div class="book-meta">
        <h1 class="book-title">\(escape(fileName))</h1>
        <p class="notice">\(escape(message))</p>
        </div></header>
        """
        return shell(title: fileName, body: body)
    }

    // MARK: - Sanitization

    private static let dangerousTagsRegex = try! NSRegularExpression(
        pattern: "</?(?:iframe|object|embed|form|input|button|link|meta|base|applet|frame|frameset)\\b[^>]*>",
        options: .caseInsensitive)
    private static let eventAttributeRegex = try! NSRegularExpression(
        pattern: "\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)",
        options: .caseInsensitive)

    /// Book content is untrusted. <script>/<style> blocks are already removed
    /// during body extraction; this pass drops embedding/form/meta tags and
    /// inline event handlers. URL schemes are constrained separately in
    /// rewriteResources.
    static func sanitize(_ html: String) -> String {
        var result = html
        for regex in [dangerousTagsRegex, eventAttributeRegex] {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    // MARK: - Resource inlining

    /// Rewrite img src / svg image href attributes to data URIs and defuse
    /// internal links (chapter files are merged, so hrefs would dangle).
    private static func rewriteResources(in html: String, chapterPath: String,
                                         book: EPUBBook, imageBudget: inout Int) -> String {
        let chapterDir: String
        if let slash = chapterPath.lastIndex(of: "/") {
            chapterDir = String(chapterPath[..<slash]) + "/"
        } else {
            chapterDir = ""
        }

        let pattern = "(src|xlink:href|href)\\s*=\\s*([\"'])([^\"']*)\\2"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }

        let ns = html as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length

            let attr = ns.substring(with: match.range(at: 1)).lowercased()
            let quote = ns.substring(with: match.range(at: 2))
            let value = ns.substring(with: match.range(at: 3))
            let full = ns.substring(with: match.range)

            let lower = value.lowercased()

            if attr == "href" {
                // Allowlist: web/mail links and same-page anchors. Everything
                // else (javascript:, data:, file:, cross-file paths) → "#".
                if lower.hasPrefix("http://") || lower.hasPrefix("https://")
                    || lower.hasPrefix("mailto:") || value.hasPrefix("#") {
                    result += full
                } else {
                    result += "href=\(quote)#\(quote)"
                }
                continue
            }

            // src / xlink:href → inline as an image. Remote URLs are dropped
            // (no network fetches from a preview); data: URIs pass only if
            // they are images.
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                result += "\(ns.substring(with: match.range(at: 1)))=\(quote)\(quote)"
                continue
            }
            if lower.hasPrefix("data:") {
                if lower.hasPrefix("data:image/") {
                    result += full
                } else {
                    result += "\(ns.substring(with: match.range(at: 1)))=\(quote)\(quote)"
                }
                continue
            }
            if lower.contains(":") && !value.contains("/") {
                // Any other scheme (javascript:, vbscript:, …)
                result += "\(ns.substring(with: match.range(at: 1)))=\(quote)\(quote)"
                continue
            }
            let resolved = book.resolve(href: value, relativeTo: chapterDir)
            if let uri = dataURI(forPath: resolved, in: book, budget: &imageBudget) {
                result += "\(ns.substring(with: match.range(at: 1)))=\(quote)\(uri)\(quote)"
            } else {
                result += "\(ns.substring(with: match.range(at: 1)))=\(quote)\(quote)"
            }
        }
        result += ns.substring(from: last)
        return result
    }

    private static func dataURI(forPath path: String, in book: EPUBBook,
                                budget: inout Int) -> String? {
        let mime = book.mediaType(forPath: path)
        guard mime.hasPrefix("image/") else { return nil }
        guard budget > 0, let data = book.archive.read(path),
              data.count <= imageBudgetSingle, data.count <= budget else { return nil }
        budget -= data.count
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    // MARK: - Page shell

    private static func shell(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body {
            margin: 0; padding: 0 24px 48px;
            font: 16px/1.6 -apple-system, "New York", Georgia, serif;
            font-family: ui-serif, "New York", Georgia, serif;
            background: #fffdf8; color: #1c1b19;
            max-width: 42em; margin: 0 auto;
            -webkit-text-size-adjust: 100%;
            word-wrap: break-word;
        }
        @media (prefers-color-scheme: dark) {
            body { background: #1d1c1a; color: #d8d5cf; }
        }
        .book-header {
            display: flex; gap: 20px; align-items: flex-end;
            padding: 28px 0 20px;
            border-bottom: 1px solid rgba(128,128,128,.35);
            margin-bottom: 24px;
        }
        .cover {
            max-width: 110px; max-height: 160px;
            border-radius: 4px;
            box-shadow: 0 2px 10px rgba(0,0,0,.3);
            flex-shrink: 0;
        }
        .book-title { font-size: 1.7em; line-height: 1.2; margin: 0 0 6px; }
        .book-author { margin: 0 0 8px; font-style: italic; opacity: .85; }
        .book-facts {
            margin: 0;
            font: 12px/1.4 -apple-system, system-ui, sans-serif;
            text-transform: uppercase; letter-spacing: .06em;
            opacity: .6;
        }
        .notice {
            font-family: -apple-system, system-ui, sans-serif;
            font-size: .9em; opacity: .7;
            border-left: 3px solid rgba(128,128,128,.5);
            padding: 6px 12px; margin: 20px 0;
        }
        .toc { margin: 0 0 28px; font-family: -apple-system, system-ui, sans-serif; font-size: .9em; }
        .toc h2 { font-size: .85em; text-transform: uppercase; letter-spacing: .08em; opacity: .6; margin: 0 0 8px; }
        .toc ol { margin: 0; padding-left: 1.4em; columns: 2; column-gap: 2em; }
        .toc li { margin: 2px 0; break-inside: avoid; }
        .toc a { color: inherit; text-decoration: none; opacity: .85; }
        .toc a:hover { text-decoration: underline; }
        .chapter { margin-bottom: 2.5em; }
        .chapter + .chapter { border-top: 1px solid rgba(128,128,128,.25); padding-top: 2.5em; }
        .chapter img, .chapter svg { max-width: 100%; height: auto; }
        .chapter h1, .chapter h2, .chapter h3 { line-height: 1.25; }
        .chapter p { margin: 0 0 0; text-indent: 1.4em; }
        .chapter p:first-of-type, .chapter h1 + p, .chapter h2 + p, .chapter h3 + p { text-indent: 0; }
        .chapter blockquote { margin: 1em 1.5em; opacity: .9; }
        .chapter pre { overflow-x: auto; font-size: .85em; }
        .chapter table { border-collapse: collapse; max-width: 100%; }
        .chapter td, .chapter th { border: 1px solid rgba(128,128,128,.4); padding: 4px 8px; }
        a { color: #b3541e; }
        @media (prefers-color-scheme: dark) { a { color: #e0956b; } }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func formatCount(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
}
