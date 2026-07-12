import Foundation

// Test harness: renders an EPUB to HTML on stdout or a file, prints stats
// to stderr. Usage: epub-preview-cli <file.epub> [out.html]

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: epub-preview-cli <file.epub> [out.html]\n".utf8))
    exit(64)
}

let url = URL(fileURLWithPath: args[1])
let start = Date()

do {
    let book = try EPUBBook(url: url)
    let rendering = PreviewBuilder.render(book, textBudget: 2_000_000)
    let (html, pages, words) = (rendering.html, rendering.pages, rendering.words)
    let elapsed = Date().timeIntervalSince(start)

    var info = """
    title:    \(book.title)
    authors:  \(book.authors.joined(separator: ", "))
    spine:    \(book.spinePaths.count) documents
    cover:    \(book.coverPath ?? "none")
    pages:    ~\(pages)
    words:    \(words)
    drm:      \(book.isDRMProtected)
    html:     \(html.utf8.count) bytes
    time:     \(String(format: "%.0f", elapsed * 1000)) ms

    """
    FileHandle.standardError.write(Data(info.utf8))

    if args.count >= 3 {
        try html.write(toFile: args[2], atomically: true, encoding: .utf8)
        info = "wrote \(args[2])\n"
        FileHandle.standardError.write(Data(info.utf8))
    } else {
        print(html)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
