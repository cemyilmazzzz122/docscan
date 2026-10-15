#!/usr/bin/env bash
# Installs the DocScan desktop app for the current user (Linux, KDE Plasma friendly).
#
#   desktop/install.sh            install
#   desktop/install.sh --remove   uninstall
#
# Creates a virtualenv next to this script (reusing the system PySide6 if present),
# a `docscan` command in ~/.local/bin, an application menu entry and a Dolphin
# right-click menu ("Scan document", "Scan document to PDF").
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin/docscan"
APP="$HOME/.local/share/applications/docscan.desktop"
MENU="$HOME/.local/share/kio/servicemenus/docscan.desktop"
MIME="image/jpeg;image/png;image/webp;image/heif;image/heic;image/avif;image/tiff;image/bmp;"

if [[ "${1:-}" == "--remove" ]]; then
  rm -f "$BIN" "$APP" "$MENU"
  rm -rf "$HERE/.venv"
  echo "DocScan removed."
  exit 0
fi

python3 -m venv --system-site-packages "$HERE/.venv"
"$HERE/.venv/bin/pip" install -q -r "$HERE/requirements.txt"
if ! "$HERE/.venv/bin/python" -c "import PySide6" 2>/dev/null; then
  "$HERE/.venv/bin/pip" install -q PySide6
fi

mkdir -p "$(dirname "$BIN")" "$(dirname "$APP")" "$(dirname "$MENU")"
cat > "$BIN" <<SH
#!/bin/sh
exec "$HERE/.venv/bin/python" "$HERE/docscan/app.py" "\$@"
SH
chmod +x "$BIN"

cat > "$APP" <<DESKTOP
[Desktop Entry]
Type=Application
Name=DocScan
GenericName=Document Scanner
Comment=Turns a document photo into a flat, clean scanned document
Exec=$BIN %F
Icon=document-scan
Terminal=false
Categories=Graphics;Scanning;
MimeType=$MIME
Keywords=scan;document;pdf;
DESKTOP

cat > "$MENU" <<DESKTOP
[Desktop Entry]
Type=Service
MimeType=$MIME
X-KDE-Priority=TopLevel
Actions=scan;pdf

[Desktop Action scan]
Name=Scan document
Icon=document-scan
Exec=$BIN %F

[Desktop Action pdf]
Name=Scan document to PDF
Icon=application-pdf
Exec=sh -c 'out="\$(dirname "\$1")/scanned_document.pdf"; "$BIN" --cli --pdf "\$out" "\$@" && notify-send -i document-scan "DocScan" "PDF ready: \$out"' _ %F
DESKTOP
chmod +x "$MENU"
update-desktop-database "$(dirname "$APP")" 2>/dev/null || true

echo "DocScan installed. Run 'docscan' or open it from the application menu."
