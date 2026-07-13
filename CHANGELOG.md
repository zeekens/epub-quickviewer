# Changelog

All notable changes to epub-quickviewer are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com); versions
correspond to git tags (`v0.2` ↔ `[0.2]`).

## [0.4] - 2026-07-13

### Fixed
- The app window rendered a blank white page for every book (0.2 and 0.3).
  A sandboxed `WKWebView` cannot start its WebContent process without the
  `com.apple.security.network.client` entitlement, so the render process was
  terminated on load. Added the entitlement to the app.
  Quick Look previews were never affected: the extension hands HTML to
  Quick Look, which renders it in its own web view.

### Security
- The entitlement above grants the *app* outbound network capability, but the
  app still makes no requests: book HTML is sanitized, remote images are
  dropped, resources are inlined as `data:` URIs, and non-`about:` navigations
  are cancelled. The Quick Look extension does not have the entitlement and
  remains network-free.

## [0.3] - 2026-07-12

### Changed
- README screenshot and performance table now use the synthetic sample book
  rather than a copyrighted title.

## [0.2] - 2026-07-12

First public release.

### Added
- Quick Look preview extension: press space on an `.epub` in Finder to see
  cover, title, author, estimated page count, word count, linked table of
  contents, and the full book text.
- Minimal host app (`EPUB Quickviewer.app`) with ⌘O, drag & drop, and
  "Open With" support.
- Support for zipped and directory-format EPUBs (Apple Books style),
  EPUB 2 and 3, chapter titles from nav/NCX documents, DRM detection.
- CLI test harness (`epub-preview-cli`) and synthetic EPUB fixture generator.
- Builds with Command Line Tools only — no Xcode required.

### Security
- Book HTML is sanitized: scripts, styles, embedding tags (`iframe`,
  `object`, `embed`, `form`, …) and inline event handlers are stripped.
- URL scheme allowlisting; `javascript:`/`data:` links defused.
- No network access from previews: remote images dropped, all resources
  inlined as `data:` URIs.
- XML external entity resolution disabled (XXE).
- Zip-bomb caps (128 MiB/entry, 96 MiB total) and render budgets.
- Path traversal guard for directory-format EPUBs.
- App Sandbox + hardened runtime on both the app and the extension.
