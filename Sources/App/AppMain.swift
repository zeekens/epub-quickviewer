import AppKit
import WebKit
import UniformTypeIdentifiers

/// Minimal host app: a window with a WKWebView rendering the same HTML the
/// Quick Look extension produces. Exists mainly so the appex registers with
/// the system; doubles as a lightweight reader.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var emptyLabel: NSTextField!
    private var pendingURL: URL?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        if let url = pendingURL {
            pendingURL = nil
            load(url: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        // Open events can arrive before didFinishLaunching builds the UI.
        if window == nil {
            pendingURL = url
        } else {
            load(url: url)
        }
    }

    // MARK: - UI

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 940),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "EPUB Quickviewer"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.tabbingMode = .disallowed

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(webView)

        emptyLabel = NSTextField(labelWithString: "Open an EPUB file, or drop one here\n(⌘O)")
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 16)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
        ])

        let dropView = DropView(frame: window.contentView!.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.onDrop = { [weak self] url in self?.load(url: url) }
        window.contentView!.addSubview(dropView)

        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About EPUB Quickviewer",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit EPUB Quickviewer",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        if let epubType = UTType("org.idpf.epub-container") {
            panel.allowedContentTypes = [epubType]
        }
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url: url)
        }
    }

    // MARK: - Loading

    private func load(url: URL) {
        emptyLabel.isHidden = true
        do {
            let book = try EPUBBook(url: url)
            let rendering = PreviewBuilder.render(book, textBudget: 8_000_000)
            window.title = "\(book.title) — ≈\(rendering.pages) pages"
            webView.loadHTMLString(rendering.html, baseURL: nil)
        } catch {
            window.title = url.lastPathComponent
            webView.loadHTMLString(PreviewBuilder.errorHTML(fileName: url.lastPathComponent,
                                                            message: error.localizedDescription),
                                   baseURL: nil)
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
}

extension AppDelegate: WKNavigationDelegate {
    /// The web view renders untrusted book HTML: never let it browse.
    /// Link clicks to the web open in the default browser; same-page anchor
    /// jumps (about:blank#chN) and the initial loadHTMLString are allowed.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if navigationAction.navigationType == .linkActivated {
            if let url, let scheme = url.scheme?.lowercased() {
                if scheme == "about" {
                    decisionHandler(.allow)  // TOC anchor within the loaded page
                    return
                }
                if scheme == "http" || scheme == "https" || scheme == "mailto" {
                    NSWorkspace.shared.open(url)
                }
            }
            decisionHandler(.cancel)
            return
        }
        // Initial HTML load and other internal navigations (about:blank only).
        decisionHandler(url == nil || url?.scheme?.lowercased() == "about" ? .allow : .cancel)
    }
}

/// Transparent overlay that accepts .epub file drops.
final class DropView: NSView {
    var onDrop: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // pass clicks through

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        epubURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = epubURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    private func epubURL(from info: NSDraggingInfo) -> URL? {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return nil
        }
        return urls.first { $0.pathExtension.lowercased() == "epub" }
    }
}
