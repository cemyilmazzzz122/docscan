# Desktop app (Linux)

`desktop/` contains a Qt (PySide6) app for Linux, designed for KDE Plasma. It implements the same
pipeline as the C++ engine in Python with OpenCV, and serves as the reference implementation.

## Install

```sh
desktop/install.sh
```

This creates a virtual environment in `desktop/.venv` (reusing the system PySide6 if installed),
and adds:

- `~/.local/bin/docscan`, the command,
- an application menu entry,
- two Dolphin actions on images: *Scan document* and *Scan document to PDF*.

`desktop/install.sh --remove` undoes all of it.

## Use

Open DocScan and drop photos onto the window, click to choose files, or paste with Ctrl+V. Pasting
works with copied files, file paths and image data (for example a screenshot).

Every scan is saved next to its photo as `<name>_scanned.jpg`. Images pasted as raw data are first
saved to `DocScan` in your Pictures folder.

| Toolbar | Action |
| --- | --- |
| Open, Paste | add photos |
| Color, Gray, Black & White, Original | output mode |
| Adjust corners | drag the four corners, then Apply |
| Straighten | toggle bent-page correction for the current page |
| Rotate | 90 degrees clockwise |
| Save as | save the current page elsewhere |
| Export PDF | all pages as one A4 PDF |
| Clear | remove all pages |

## Command line

```sh
docscan --cli [-m color|gray|bw|original] [--no-straighten] [--pdf out.pdf] photos...
```

## Files

| File | Contents |
| --- | --- |
| `docscan/app.py` | window, page list, corner editor, PDF export, clipboard, CLI |
| `docscan/scanner.py` | detection, perspective correction, filters |
| `docscan/dewarp.py` | straightening of bent pages |
| `install.sh` | per-user installation |
| `requirements.txt` | Python dependencies |
