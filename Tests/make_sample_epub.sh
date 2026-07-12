#!/bin/bash
# Generate a small but structurally realistic EPUB 3 for testing.
set -euo pipefail
OUT="${1:-sample.epub}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/META-INF" "$WORK/OEBPS/images"

printf 'application/epub+zip' > "$WORK/mimetype"

cat > "$WORK/META-INF/container.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
EOF

cat > "$WORK/OEBPS/content.opf" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:12345678-1234-1234-1234-123456789012</dc:identifier>
    <dc:title>The Testing of Books</dc:title>
    <dc:creator>Ada Exempel</dc:creator>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-07-12T00:00:00Z</meta>
    <meta name="cover" content="cover-img"/>
  </metadata>
  <manifest>
    <item id="cover-img" href="images/cover.png" media-type="image/png" properties="cover-image"/>
    <item id="inline-img" href="images/figure.png" media-type="image/png"/>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch3" href="chapter3.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
    <itemref idref="ch3"/>
  </spine>
</package>
EOF

cat > "$WORK/OEBPS/nav.xhtml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Contents</title></head>
<body><nav epub:type="toc"><ol>
<li><a href="chapter1.xhtml">One</a></li>
<li><a href="chapter2.xhtml">Two</a></li>
<li><a href="chapter3.xhtml">Three</a></li>
</ol></nav></body></html>
EOF

para() {
  echo "<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.</p>"
}

make_chapter() {
  local n="$1" title="$2" extra="$3"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
    echo "<title>$title</title>"
    echo '<script>alert("should be stripped")</script>'
    echo '<style>p { color: red; }</style>'
    echo "</head><body>"
    echo "<h1>$title</h1>"
    echo "$extra"
    for i in $(seq 1 30); do para; done
    echo '<p>Cross link to <a href="chapter2.xhtml">chapter two</a> and an <a href="https://example.org">external site</a>.</p>'
    echo "</body></html>"
  } > "$WORK/OEBPS/chapter$n.xhtml"
}

make_chapter 1 "A Beginning" '<p><img src="images/figure.png" alt="figure"/></p>'
make_chapter 2 "The Middle Part" ''
make_chapter 3 "An End" '<p><img src="../OEBPS/images/figure.png" alt="relative"/></p>'

# Tiny valid PNGs (1x1 blue for cover, 1x1 green for figure)
base64 -d > "$WORK/OEBPS/images/cover.png" <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/p9BsegAAAABJRU5ErkJggg==
EOF
base64 -d > "$WORK/OEBPS/images/figure.png" <<'EOF'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNg+M/wHwAEAQH/7yz47gAAAABJRU5ErkJggg==
EOF

OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"
(cd "$WORK" && zip -X -0 -q "$OUT_ABS" mimetype && zip -X -9 -q -r "$OUT_ABS" META-INF OEBPS)
echo "created $OUT_ABS"
