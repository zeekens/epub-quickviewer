import Foundation

/// Parsed EPUB: metadata, spine-ordered chapters, and resource access.
final class EPUBBook {
    struct ManifestItem {
        let id: String
        let href: String       // zip path, resolved relative to the OPF
        let mediaType: String
    }

    struct Chapter {
        let zipPath: String
        let title: String?
        let bodyHTML: String
        let textLength: Int
    }

    enum EPUBError: Error, LocalizedError {
        case notAZip, noContainer, noOPF, drmProtected

        var errorDescription: String? {
            switch self {
            case .notAZip: return "Not a valid EPUB (ZIP) file"
            case .noContainer: return "Missing META-INF/container.xml"
            case .noOPF: return "Missing or unreadable OPF package document"
            case .drmProtected: return "This book is DRM-protected"
            }
        }
    }

    let archive: EPUBContainer
    private(set) var title = "Untitled"
    private(set) var authors: [String] = []
    private(set) var language: String?
    private(set) var manifest: [String: ManifestItem] = [:]  // by id
    private(set) var manifestByPath: [String: ManifestItem] = [:]
    private(set) var spinePaths: [String] = []               // zip paths in reading order
    private(set) var coverPath: String?
    private(set) var isDRMProtected = false
    private(set) var navTitles: [String: String] = [:]       // zip path → TOC title

    private var opfDirectory = ""

    init(url: URL) throws {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            archive = DirectoryContainer(root: url)
        } else if let zip = ZipArchive(url: url) {
            archive = zip
        } else {
            throw EPUBError.notAZip
        }

        if archive.contains("META-INF/encryption.xml") {
            isDRMProtected = true
        }

        guard let containerData = archive.read("META-INF/container.xml"),
              let opfPath = ContainerXMLParser.rootfilePath(in: containerData) else {
            throw EPUBError.noContainer
        }
        if let slash = opfPath.lastIndex(of: "/") {
            opfDirectory = String(opfPath[..<slash]) + "/"
        }
        guard let opfData = archive.read(opfPath) else { throw EPUBError.noOPF }

        let opf = OPFParser()
        opf.parse(opfData)
        if let t = opf.title, !t.isEmpty { title = t }
        authors = opf.creators
        language = opf.language

        for item in opf.manifestItems {
            let resolved = resolve(href: item.href, relativeTo: opfDirectory)
            let entry = ManifestItem(id: item.id, href: resolved, mediaType: item.mediaType)
            manifest[item.id] = entry
            manifestByPath[resolved] = entry
        }

        spinePaths = opf.spineIDRefs.compactMap { manifest[$0]?.href }

        // Cover: EPUB3 "cover-image" property, else EPUB2 <meta name="cover">.
        if let coverID = opf.coverImagePropertyID ?? opf.coverMetaContent,
           let item = manifest[coverID], item.mediaType.hasPrefix("image/") {
            coverPath = item.href
        }

        loadNavTitles(navItemID: opf.navItemID)
    }

    /// Chapter titles from the navigation document: EPUB3 nav, else NCX.
    private func loadNavTitles(navItemID: String?) {
        var entries: [(href: String, title: String)] = []
        var baseDir = ""

        if let navID = navItemID, let item = manifest[navID],
           let data = archive.read(item.href) {
            baseDir = directory(of: item.href)
            entries = NavDocParser.entries(in: data)
        } else if let ncx = manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }),
                  let data = archive.read(ncx.href) {
            baseDir = directory(of: ncx.href)
            entries = NCXParser.entries(in: data)
        }

        for (href, title) in entries {
            let path = resolve(href: href, relativeTo: baseDir)
            if navTitles[path] == nil, !title.isEmpty {
                navTitles[path] = title  // first entry per file wins (chapter level)
            }
        }
    }

    private func directory(of path: String) -> String {
        if let slash = path.lastIndex(of: "/") { return String(path[..<slash]) + "/" }
        return ""
    }

    struct Analysis {
        let chapters: [Chapter]
        let truncated: Bool
        let pages: Int      // ≈ printed pages: (chars incl. spaces) / 1800
        let words: Int
    }

    /// Single pass over the spine: extracts chapter bodies (kept only up to
    /// `textBudget` bytes, so huge books stay fast to render) while counting
    /// text across the *entire* book for the page/word estimate.
    func analyze(textBudget: Int) -> Analysis {
        var chapters: [Chapter] = []
        var truncated = false
        var kept = 0
        var chars = 0
        var words = 0
        var processed = 0
        let processingCap = 96 << 20  // stop stats work on absurd inputs (96 MiB)

        for path in spinePaths {
            if processed > processingCap { truncated = true; break }
            guard let data = archive.read(path),
                  let xhtml = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1) else { continue }
            processed += data.count
            let body = XHTMLBody.extract(from: xhtml)
            let stats = XHTMLBody.textStats(of: body)
            // Count spaces between words toward the page estimate, matching
            // the "1800 characters incl. spaces per page" convention.
            chars += stats.chars + stats.words
            words += stats.words

            if kept < textBudget {
                let title = navTitles[path]
                    ?? XHTMLBody.firstHeading(in: body)
                    ?? XHTMLBody.documentTitle(in: xhtml)
                chapters.append(Chapter(zipPath: path, title: title,
                                        bodyHTML: body, textLength: stats.chars))
                kept += body.utf8.count
            } else {
                truncated = true
            }
        }

        let pages = max(1, Int((Double(chars) / 1800.0).rounded()))
        return Analysis(chapters: chapters, truncated: truncated, pages: pages, words: words)
    }

    /// Resolve an (optionally percent-encoded) href against a base directory
    /// inside the zip, collapsing "./" and "../" components.
    func resolve(href: String, relativeTo base: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        let raw = decoded.split(separator: "#")[0]
        var components = base.split(separator: "/").map(String.init)
        for part in raw.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }

    func mediaType(forPath path: String) -> String {
        if let item = manifestByPath[path] { return item.mediaType }
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - container.xml

private enum ContainerXMLParser {
    final class Delegate: NSObject, XMLParserDelegate {
        var path: String?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if path == nil, name == "rootfile" || name.hasSuffix(":rootfile") {
                if attributes["media-type"] == nil || attributes["media-type"] == "application/oebps-package+xml" {
                    path = attributes["full-path"]
                }
            }
        }
    }

    static func rootfilePath(in data: Data) -> String? {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false  // no XXE, no network
        let delegate = Delegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.path
    }
}

// MARK: - OPF package document

final class OPFParser: NSObject, XMLParserDelegate {
    struct RawItem { let id: String; let href: String; let mediaType: String }

    var title: String?
    var creators: [String] = []
    var language: String?
    var manifestItems: [RawItem] = []
    var spineIDRefs: [String] = []
    var coverMetaContent: String?        // EPUB2 <meta name="cover" content="id"/>
    var coverImagePropertyID: String?    // EPUB3 manifest item with properties="cover-image"
    var navItemID: String?               // EPUB3 manifest item with properties="nav"

    private var text = ""
    private var capturing = false
    private var currentElement = ""

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false  // no XXE, no network
        parser.delegate = self
        parser.parse()
    }

    private func localName(_ name: String) -> String {
        if let colon = name.lastIndex(of: ":") { return String(name[name.index(after: colon)...]) }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        let element = localName(name).lowercased()
        currentElement = element
        switch element {
        case "title" where title == nil, "creator":
            capturing = true
            text = ""
        case "language" where language == nil:
            capturing = true
            text = ""
        case "item":
            if let id = attrs["id"], let href = attrs["href"] {
                manifestItems.append(RawItem(id: id, href: href,
                                             mediaType: attrs["media-type"] ?? ""))
                let properties = attrs["properties"]?.split(separator: " ") ?? []
                if properties.contains("cover-image") { coverImagePropertyID = id }
                if properties.contains("nav") { navItemID = id }
            }
        case "itemref":
            if let idref = attrs["idref"], attrs["linear"]?.lowercased() != "no" {
                spineIDRefs.append(idref)
            }
        case "meta":
            if attrs["name"] == "cover", let content = attrs["content"] {
                coverMetaContent = content
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        guard capturing else { return }
        let element = localName(name).lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "title": if title == nil, !value.isEmpty { title = value }
        case "creator": if !value.isEmpty { creators.append(value) }
        case "language": if language == nil, !value.isEmpty { language = value }
        default: break
        }
        capturing = false
    }
}

// MARK: - Navigation documents (chapter titles)

/// EPUB3 navigation document: anchors inside the first <nav> whose
/// epub:type includes "toc" (or the first <nav> at all as fallback).
enum NavDocParser {
    final class Delegate: NSObject, XMLParserDelegate {
        var entries: [(String, String)] = []
        private var navDepth = 0
        private var inTocNav = false
        private var sawExplicitToc = false
        private var currentHref: String?
        private var currentText = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attrs: [String: String]) {
            let element = localName(name)
            if element == "nav" {
                navDepth += 1
                let type = attrs["epub:type"] ?? attrs["type"] ?? ""
                if type.contains("toc") {
                    inTocNav = true
                    sawExplicitToc = true
                    entries.removeAll()
                } else if !sawExplicitToc {
                    inTocNav = true  // fallback: first nav counts until a real toc appears
                }
            } else if element == "a", inTocNav, currentHref == nil {
                currentHref = attrs["href"]
                currentText = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if currentHref != nil { currentText += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let element = localName(name)
            if element == "a", let href = currentHref {
                let title = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { entries.append((href, title)) }
                currentHref = nil
            } else if element == "nav" {
                navDepth -= 1
                if navDepth == 0 { inTocNav = false }
            }
        }

        private func localName(_ name: String) -> String {
            if let colon = name.lastIndex(of: ":") { return String(name[name.index(after: colon)...]).lowercased() }
            return name.lowercased()
        }
    }

    static func entries(in data: Data) -> [(href: String, title: String)] {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false  // no XXE, no network
        let delegate = Delegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.entries.map { (href: $0.0, title: $0.1) }
    }
}

/// EPUB2 NCX: <navPoint><navLabel><text>…</text></navLabel><content src="…"/>
enum NCXParser {
    final class Delegate: NSObject, XMLParserDelegate {
        var entries: [(String, String)] = []
        private var inNavLabelText = false
        private var pendingLabel = ""
        private var labelStack: [String] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attrs: [String: String]) {
            switch localName(name) {
            case "navpoint":
                labelStack.append("")
            case "text":
                inNavLabelText = true
                pendingLabel = ""
            case "content":
                if let src = attrs["src"], let label = labelStack.last, !label.isEmpty {
                    entries.append((src, label))
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inNavLabelText { pendingLabel += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            switch localName(name) {
            case "text":
                inNavLabelText = false
                if !labelStack.isEmpty, labelStack[labelStack.count - 1].isEmpty {
                    labelStack[labelStack.count - 1] =
                        pendingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case "navpoint":
                if !labelStack.isEmpty { labelStack.removeLast() }
            default:
                break
            }
        }

        private func localName(_ name: String) -> String {
            if let colon = name.lastIndex(of: ":") { return String(name[name.index(after: colon)...]).lowercased() }
            return name.lowercased()
        }
    }

    static func entries(in data: Data) -> [(href: String, title: String)] {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false  // no XXE, no network
        let delegate = Delegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.entries.map { (href: $0.0, title: $0.1) }
    }
}

// MARK: - XHTML utilities

enum XHTMLBody {
    /// Inner HTML of the <body> element (or the whole string if none),
    /// with <script> blocks and inline event handlers removed.
    static func extract(from xhtml: String) -> String {
        var content = xhtml
        if let open = range(of: "<body", in: content, from: content.startIndex),
           let openEnd = content.range(of: ">", range: open.upperBound ..< content.endIndex),
           let close = range(of: "</body", in: content, from: openEnd.upperBound) {
            content = String(content[openEnd.upperBound ..< close.lowerBound])
        }
        content = stripBlocks(named: "script", from: content)
        content = stripBlocks(named: "style", from: content)
        return content
    }

    static func documentTitle(in xhtml: String) -> String? {
        guard let open = range(of: "<title", in: xhtml, from: xhtml.startIndex),
              let openEnd = xhtml.range(of: ">", range: open.upperBound ..< xhtml.endIndex),
              let close = range(of: "</title", in: xhtml, from: openEnd.upperBound) else { return nil }
        let value = decodeEntities(String(xhtml[openEnd.upperBound ..< close.lowerBound]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func firstHeading(in body: String) -> String? {
        for tag in ["h1", "h2", "h3"] {
            guard let open = range(of: "<\(tag)", in: body, from: body.startIndex),
                  let openEnd = body.range(of: ">", range: open.upperBound ..< body.endIndex),
                  let close = range(of: "</\(tag)", in: body, from: openEnd.upperBound) else { continue }
            let raw = String(body[openEnd.upperBound ..< close.lowerBound])
            let value = decodeEntities(stripTags(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Fast text statistics over raw HTML: counts Unicode scalars outside
    /// tags (excluding whitespace) and whitespace-separated words, working
    /// directly on UTF-8 bytes.
    static func textStats(of html: String) -> (chars: Int, words: Int) {
        var chars = 0
        var words = 0
        var inTag = false
        var inWord = false
        for byte in html.utf8 {
            switch byte {
            case UInt8(ascii: "<"):
                inTag = true
                if inWord { words += 1; inWord = false }
            case UInt8(ascii: ">"):
                inTag = false
            case 0x20, 0x09, 0x0A, 0x0D:
                if !inTag, inWord { words += 1; inWord = false }
            default:
                if !inTag {
                    // Skip UTF-8 continuation bytes so multi-byte characters
                    // count once.
                    if byte & 0xC0 != 0x80 { chars += 1 }
                    inWord = true
                }
            }
        }
        if inWord { words += 1 }
        return (chars, words)
    }

    static func stripTags(_ html: String) -> String {
        var out = ""
        out.reserveCapacity(html.count)
        var inTag = false
        for ch in html {
            if ch == "<" { inTag = true }
            else if ch == ">" { inTag = false; out.append(" ") }
            else if !inTag { out.append(ch) }
        }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
    }

    private static func range(of needle: String, in haystack: String,
                              from start: String.Index) -> Range<String.Index>? {
        haystack.range(of: needle, options: .caseInsensitive, range: start ..< haystack.endIndex)
    }

    private static func stripBlocks(named tag: String, from html: String) -> String {
        var result = html
        while let open = range(of: "<\(tag)", in: result, from: result.startIndex) {
            if let close = result.range(of: "</\(tag)>", options: .caseInsensitive,
                                        range: open.upperBound ..< result.endIndex) {
                result.removeSubrange(open.lowerBound ..< close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound ..< result.endIndex)
            }
        }
        return result
    }
}
