import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Data-based Quick Look preview: Finder (spacebar), qlmanage, and any
/// QLPreviewPanel host render the HTML we return here.
class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let fileURL = request.fileURL
        var pageTitle = fileURL.lastPathComponent
        var html: String

        do {
            let book = try EPUBBook(url: fileURL)
            // Tighter text budget than the app: Quick Look should open fast.
            let rendering = PreviewBuilder.render(book, textBudget: 2_000_000)
            pageTitle = "\(book.title) — ≈\(rendering.pages) pages"
            html = rendering.html
        } catch {
            html = PreviewBuilder.errorHTML(fileName: fileURL.lastPathComponent,
                                            message: error.localizedDescription)
        }

        let data = Data(html.utf8)
        let reply = QLPreviewReply(dataOfContentType: .html,
                                   contentSize: CGSize(width: 780, height: 920)) { _ in data }
        reply.title = pageTitle
        reply.stringEncoding = .utf8
        return reply
    }
}
