"""DocScan — drop or paste a photo, get a clean scanned document."""

from __future__ import annotations

import argparse
import os
import sys
import time
from dataclasses import dataclass, field

import numpy as np
from PySide6.QtCore import (QMarginsF, QObject, QPointF, QRectF, QRunnable, QSize, QStandardPaths, Qt, QThreadPool,
                            QUrl, Signal)
from PySide6.QtGui import (QAction, QColor, QGuiApplication, QIcon, QImage, QImageReader, QKeySequence, QPageSize,
                           QPainter, QPainterPath, QPdfWriter, QPen, QPixmap)
from PySide6.QtWidgets import (QApplication, QButtonGroup, QFileDialog, QHBoxLayout, QLabel, QListWidget,
                               QListWidgetItem, QMainWindow, QMessageBox, QPushButton, QSizePolicy, QStackedWidget,
                               QToolBar, QVBoxLayout, QWidget)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scanner  # noqa: E402

MODE_LABELS = {"color": "Color", "gray": "Gray", "bw": "Black && White", "original": "Original"}
IMAGE_FILTER = "Images (*.jpg *.jpeg *.png *.webp *.bmp *.tif *.tiff *.heic *.heif *.avif)"
OUTPUT_SUFFIX = "_scanned"


# ---------------------------------------------------------------- conversions

def load_image(path: str) -> np.ndarray:
    """OpenCV first, then Qt (KDE's kimageformats plugins also open HEIC/AVIF)."""
    try:
        return scanner.imread(path)
    except ValueError:
        reader = QImageReader(path)
        reader.setAutoTransform(True)
        qimg = reader.read()
        if qimg.isNull():
            raise ValueError(f"Could not open image: {os.path.basename(path)}\n{reader.errorString()}")
        return from_qimage(qimg)


def from_qimage(qimg: QImage) -> np.ndarray:
    qimg = qimg.convertToFormat(QImage.Format.Format_BGR888)
    arr = np.frombuffer(qimg.constBits(), np.uint8).reshape(qimg.height(), qimg.bytesPerLine())
    return arr[:, : qimg.width() * 3].reshape(qimg.height(), qimg.width(), 3).copy()


def to_qimage(img: np.ndarray) -> QImage:
    img = np.ascontiguousarray(img)
    h, w = img.shape[:2]
    if img.ndim == 2:
        return QImage(img.data, w, h, w, QImage.Format.Format_Grayscale8).copy()
    return QImage(img.data, w, h, w * 3, QImage.Format.Format_BGR888).copy()


def output_path(src: str) -> str:
    base, _ = os.path.splitext(src)
    return base + OUTPUT_SUFFIX + ".jpg"


def paste_dir() -> str:
    """Where pasted images are stored, since they have no file of their own."""
    pictures = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.PicturesLocation)
    path = os.path.join(pictures or os.path.expanduser("~"), "DocScan")
    os.makedirs(path, exist_ok=True)
    return path


def write_pdf(path: str, images: list[np.ndarray]) -> None:
    writer = QPdfWriter(path)
    writer.setResolution(200)
    writer.setTitle("Scanned document")
    painter = None
    for i, img in enumerate(images):
        h, w = img.shape[:2]
        mm = QPageSize(QPageSize.PageSizeId.A4).size(QPageSize.Unit.Millimeter)
        if w > h:
            mm.transpose()
        writer.setPageSize(QPageSize(mm, QPageSize.Unit.Millimeter, "A4"))
        writer.setPageMargins(QMarginsF(0, 0, 0, 0))
        if i == 0:
            painter = QPainter(writer)
        else:
            writer.newPage()
        page = QRectF(0, 0, writer.width(), writer.height())
        s = min(page.width() / w, page.height() / h)
        target = QRectF(0, 0, w * s, h * s)
        target.moveCenter(page.center())
        painter.drawImage(target, to_qimage(img))
    if painter:
        painter.end()


# ----------------------------------------------------------------- processing

@dataclass
class Page:
    path: str
    original: np.ndarray | None = None
    corners: np.ndarray | None = None
    mode: str = "color"
    straighten: bool = True
    result: np.ndarray | None = None
    saved_to: str = ""
    error: str = ""
    preview: QPixmap = field(default_factory=QPixmap)


class _Signals(QObject):
    done = Signal(object)


class ScanJob(QRunnable):
    def __init__(self, page: Page):
        super().__init__()
        self.page = page
        self.signals = _Signals()

    def run(self):
        p = self.page
        try:
            if p.original is None:
                p.original = load_image(p.path)
            p.result, p.corners = scanner.scan(p.original, p.mode, p.corners, p.straighten)
            p.saved_to = output_path(p.path)
            scanner.imwrite(p.saved_to, p.result)
            p.error = ""
        except Exception as e:  # noqa: BLE001 — shown to the user
            p.error = str(e)
        self.signals.done.emit(p)


# ---------------------------------------------------------------------- views

class ImageView(QWidget):
    """Shows an image centered, preserving its aspect ratio."""

    def __init__(self):
        super().__init__()
        self._img = QImage()
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)

    def set_image(self, img: QImage):
        self._img = img
        self.update()

    def image_rect(self) -> QRectF:
        if self._img.isNull():
            return QRectF()
        area = QRectF(self.rect()).adjusted(16, 16, -16, -16)
        s = min(area.width() / self._img.width(), area.height() / self._img.height())
        r = QRectF(0, 0, self._img.width() * s, self._img.height() * s)
        r.moveCenter(area.center())
        return r

    def paintEvent(self, _):
        if self._img.isNull():
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        r = self.image_rect()
        p.fillRect(r.translated(3, 4), QColor(0, 0, 0, 40))
        p.drawImage(r, self._img)


class CornerEditor(ImageView):
    """Fix the crop by dragging the 4 corners over the original photo."""

    def __init__(self):
        super().__init__()
        self.corners = np.zeros((4, 2), np.float32)
        self._drag = -1
        self._img_size = (1, 1)
        self.setMouseTracking(True)

    def load(self, img: np.ndarray, corners: np.ndarray):
        self._img_size = (img.shape[1], img.shape[0])
        self.corners = scanner.order_corners(corners).copy()
        self.set_image(to_qimage(img))

    def _to_widget(self, pt) -> QPointF:
        r = self.image_rect()
        return QPointF(r.x() + pt[0] / self._img_size[0] * r.width(), r.y() + pt[1] / self._img_size[1] * r.height())

    def _to_image(self, pos: QPointF):
        r = self.image_rect()
        x = (pos.x() - r.x()) / r.width() * self._img_size[0]
        y = (pos.y() - r.y()) / r.height() * self._img_size[1]
        return [min(max(x, 0), self._img_size[0] - 1), min(max(y, 0), self._img_size[1] - 1)]

    def _hit(self, pos: QPointF) -> int:
        for i, c in enumerate(self.corners):
            q = self._to_widget(c)
            if (q.x() - pos.x()) ** 2 + (q.y() - pos.y()) ** 2 < 22 ** 2:
                return i
        return -1

    def paintEvent(self, e):
        super().paintEvent(e)
        if self._img.isNull():
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        pts = [self._to_widget(c) for c in self.corners]
        path = QPainterPath(pts[0])
        for q in pts[1:]:
            path.lineTo(q)
        path.closeSubpath()
        outside = QPainterPath()
        outside.addRect(self.image_rect())
        p.fillPath(outside.subtracted(path), QColor(0, 0, 0, 110))
        accent = self.palette().highlight().color()
        p.setPen(QPen(accent, 2))
        p.drawPath(path)
        for q in pts:
            p.setBrush(QColor(255, 255, 255))
            p.setPen(QPen(accent, 3))
            p.drawEllipse(q, 10, 10)

    def mousePressEvent(self, e):
        self._drag = self._hit(e.position())

    def mouseMoveEvent(self, e):
        if self._drag >= 0:
            self.corners[self._drag] = self._to_image(e.position())
            self.update()
        else:
            hit = self._hit(e.position()) >= 0
            self.setCursor(Qt.CursorShape.SizeAllCursor if hit else Qt.CursorShape.ArrowCursor)

    def mouseReleaseEvent(self, _):
        self._drag = -1


class DropPage(QWidget):
    clicked = Signal()

    def __init__(self):
        super().__init__()
        lay = QVBoxLayout(self)
        lay.setAlignment(Qt.AlignmentFlag.AlignCenter)
        icon = QLabel()
        icon.setPixmap(QIcon.fromTheme("document-scan", QIcon.fromTheme("scanner")).pixmap(96, 96))
        icon.setAlignment(Qt.AlignmentFlag.AlignCenter)
        title = QLabel("Drop a document photo here")
        f = title.font()
        f.setPointSizeF(f.pointSizeF() * 1.6)
        title.setFont(f)
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        hint = QLabel("paste with Ctrl+V, or click to choose — multiple photos work too")
        hint.setAlignment(Qt.AlignmentFlag.AlignCenter)
        hint.setEnabled(False)
        for w in (icon, title, hint):
            lay.addWidget(w)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def mouseReleaseEvent(self, _):
        self.clicked.emit()

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        c = self.palette().placeholderText().color()
        p.setPen(QPen(c, 2, Qt.PenStyle.DashLine))
        p.drawRoundedRect(QRectF(self.rect()).adjusted(24, 24, -24, -24), 16, 16)


# ---------------------------------------------------------------- main window

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("DocScan")
        self.setWindowIcon(QIcon.fromTheme("document-scan", QIcon.fromTheme("scanner")))
        self.resize(1100, 800)
        self.setAcceptDrops(True)
        self.pages: list[Page] = []
        self.pool = QThreadPool.globalInstance()
        self.mode = "color"

        self.stack = QStackedWidget()
        self.drop = DropPage()
        self.drop.clicked.connect(self.open_dialog)
        self.view = ImageView()
        self.editor = CornerEditor()

        self.list = QListWidget()
        self.list.setViewMode(QListWidget.ViewMode.IconMode)
        self.list.setFlow(QListWidget.Flow.TopToBottom)
        self.list.setIconSize(QSize(120, 160))
        self.list.setFixedWidth(160)
        self.list.setMovement(QListWidget.Movement.Static)
        self.list.currentRowChanged.connect(self.show_page)

        work = QWidget()
        wl = QHBoxLayout(work)
        wl.setContentsMargins(0, 0, 0, 0)
        wl.addWidget(self.list)
        self.inner = QStackedWidget()
        self.inner.addWidget(self.view)
        self.inner.addWidget(self.editor)
        wl.addWidget(self.inner, 1)

        self.stack.addWidget(self.drop)
        self.stack.addWidget(work)
        self.setCentralWidget(self.stack)
        self._build_toolbar()
        self._update_actions()

    # -- toolbar
    def _build_toolbar(self):
        tb = QToolBar("Tools")
        tb.setMovable(False)
        tb.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        self.addToolBar(tb)

        self.act_open = QAction(QIcon.fromTheme("document-open"), "Open…", self)
        self.act_open.setShortcut(QKeySequence.StandardKey.Open)
        self.act_open.triggered.connect(self.open_dialog)
        tb.addAction(self.act_open)

        self.act_paste = QAction(QIcon.fromTheme("edit-paste"), "Paste", self)
        self.act_paste.setShortcut(QKeySequence.StandardKey.Paste)
        self.act_paste.setShortcutContext(Qt.ShortcutContext.ApplicationShortcut)
        self.act_paste.triggered.connect(self.paste)
        tb.addAction(self.act_paste)
        tb.addSeparator()

        self.mode_group = QButtonGroup(self)
        for key, label in MODE_LABELS.items():
            b = QPushButton(label)
            b.setProperty("mode", key)
            b.setCheckable(True)
            b.setChecked(key == self.mode)
            b.setFlat(True)
            b.clicked.connect(lambda _=False, k=key: self.set_mode(k))
            self.mode_group.addButton(b)
            tb.addWidget(b)
        tb.addSeparator()

        self.act_crop = QAction(QIcon.fromTheme("transform-crop"), "Adjust corners", self)
        self.act_crop.setCheckable(True)
        self.act_crop.toggled.connect(self.toggle_crop)
        tb.addAction(self.act_crop)

        self.act_straighten = QAction(QIcon.fromTheme("format-justify-fill"), "Straighten", self)
        self.act_straighten.setToolTip("Straighten bent or curled pages using their text lines")
        self.act_straighten.setCheckable(True)
        self.act_straighten.setChecked(True)
        self.act_straighten.toggled.connect(self.set_straighten)
        tb.addAction(self.act_straighten)

        self.act_rotate = QAction(QIcon.fromTheme("object-rotate-right"), "Rotate", self)
        self.act_rotate.setShortcut("R")
        self.act_rotate.triggered.connect(self.rotate)
        tb.addAction(self.act_rotate)

        spacer = QWidget()
        spacer.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        tb.addWidget(spacer)

        self.act_save = QAction(QIcon.fromTheme("document-save-as"), "Save as…", self)
        self.act_save.setShortcut(QKeySequence.StandardKey.SaveAs)
        self.act_save.triggered.connect(self.save_as)
        tb.addAction(self.act_save)

        self.act_pdf = QAction(QIcon.fromTheme("application-pdf"), "Export PDF…", self)
        self.act_pdf.setShortcut("Ctrl+P")
        self.act_pdf.triggered.connect(self.save_pdf)
        tb.addAction(self.act_pdf)

        self.act_clear = QAction(QIcon.fromTheme("edit-clear-all"), "Clear", self)
        self.act_clear.triggered.connect(self.clear)
        tb.addAction(self.act_clear)

    def _update_actions(self):
        has = bool(self.pages)
        for a in (self.act_crop, self.act_straighten, self.act_rotate, self.act_save, self.act_pdf, self.act_clear):
            a.setEnabled(has)
        for b in self.mode_group.buttons():
            b.setEnabled(has)

    # -- input
    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls() or e.mimeData().hasImage():
            e.acceptProposedAction()

    def dropEvent(self, e):
        self._add_mime(e.mimeData())

    def keyPressEvent(self, e):
        # Fallback for when the action shortcut doesn't fire (e.g. no focused widget yet)
        if e.matches(QKeySequence.StandardKey.Paste):
            self.paste()
        else:
            super().keyPressEvent(e)

    def paste(self):
        if not self._add_mime(QGuiApplication.clipboard().mimeData()):
            self.statusBar().showMessage("Clipboard has no image or image file", 4000)

    def _add_mime(self, mime) -> bool:
        """Accepts copied files (Dolphin), file paths as text, or raw image data (browser, screenshot)."""
        files = [u.toLocalFile() for u in mime.urls() if u.isLocalFile()] if mime.hasUrls() else []
        if not files and mime.hasText():
            for line in mime.text().splitlines():
                line = line.strip()
                path = QUrl(line).toLocalFile() if line.startswith("file://") else line
                if path and os.path.isfile(path):
                    files.append(path)
        if files:
            return self.add_files(files)
        if mime.hasImage():
            qimg = QImage(mime.imageData())
            if not qimg.isNull():
                self.add_image(from_qimage(qimg))
                return True
        return False

    def open_dialog(self):
        files, _ = QFileDialog.getOpenFileNames(self, "Choose photos", os.path.expanduser("~"), IMAGE_FILTER)
        self.add_files(files)

    def add_files(self, files: list[str]) -> bool:
        files = [f for f in files if os.path.isfile(f) and OUTPUT_SUFFIX not in os.path.basename(f)]
        for f in files:
            self._add_page(Page(path=f, mode=self.mode, straighten=self.act_straighten.isChecked()))
        return bool(files)

    def add_image(self, img: np.ndarray):
        """A pasted image is saved to ~/Pictures/DocScan so the result has somewhere to go."""
        path = os.path.join(paste_dir(), time.strftime("pasted-%Y%m%d-%H%M%S") + ".png")
        scanner.imwrite(path, img)
        self._add_page(Page(path=path, original=img, mode=self.mode, straighten=self.act_straighten.isChecked()))

    def _add_page(self, page: Page):
        self.stack.setCurrentIndex(1)
        self.pages.append(page)
        item = QListWidgetItem(QIcon.fromTheme("image-loading"), os.path.basename(page.path))
        item.setTextAlignment(Qt.AlignmentFlag.AlignHCenter)
        self.list.addItem(item)
        self.list.setCurrentRow(self.list.count() - 1)
        self._run(page)
        self._update_actions()
        self.statusBar().showMessage("Processing…")

    # -- processing
    def _run(self, page: Page):
        job = ScanJob(page)
        job.signals.done.connect(self._finished)
        self.pool.start(job)

    def _finished(self, page: Page):
        if page not in self.pages:
            return
        row = self.pages.index(page)
        item = self.list.item(row)
        if page.error:
            item.setIcon(QIcon.fromTheme("dialog-error"))
            self.statusBar().showMessage(page.error)
            if row == self.list.currentRow():
                QMessageBox.warning(self, "DocScan", page.error)
            return
        page.preview = QPixmap.fromImage(to_qimage(page.result))
        item.setIcon(QIcon(page.preview.scaled(120, 160, Qt.AspectRatioMode.KeepAspectRatio,
                                               Qt.TransformationMode.SmoothTransformation)))
        if row == self.list.currentRow():
            self.show_page(row)
        self.statusBar().showMessage(f"Saved: {page.saved_to}")

    def current(self) -> Page | None:
        row = self.list.currentRow()
        return self.pages[row] if 0 <= row < len(self.pages) else None

    def show_page(self, row: int):
        if self.act_crop.isChecked():
            self.act_crop.setChecked(False)
        page = self.current()
        if not page:
            return
        for b in self.mode_group.buttons():
            b.setChecked(b.property("mode") == page.mode)
        self.act_straighten.blockSignals(True)
        self.act_straighten.setChecked(page.straighten)
        self.act_straighten.blockSignals(False)
        if page.result is not None:
            self.view.set_image(to_qimage(page.result))
            self.statusBar().showMessage(f"Saved: {page.saved_to}")

    def set_mode(self, mode: str):
        self.mode = mode
        page = self.current()
        if page and page.result is not None and page.mode != mode:
            page.mode = mode
            self._run(page)

    def set_straighten(self, on: bool):
        page = self.current()
        if page and page.result is not None and page.straighten != on:
            page.straighten = on
            self._run(page)

    def toggle_crop(self, on: bool):
        page = self.current()
        if on and page and page.result is not None:
            self.editor.load(page.original, page.corners)
            self.inner.setCurrentWidget(self.editor)
            self.act_crop.setText("Apply")
            self.statusBar().showMessage("Drag the corners, then press Apply")
        else:
            if page and self.inner.currentWidget() is self.editor:
                page.corners = self.editor.corners.copy()
                self._run(page)
            self.inner.setCurrentWidget(self.view)
            self.act_crop.setText("Adjust corners")

    def rotate(self):
        page = self.current()
        if not page or page.result is None:
            return
        import cv2
        h = page.original.shape[0]
        page.original = cv2.rotate(page.original, cv2.ROTATE_90_CLOCKWISE)
        # Rotate the corners too: (x, y) -> (h-1-y, x)
        page.corners = scanner.order_corners(np.stack([h - 1 - page.corners[:, 1], page.corners[:, 0]], axis=1))
        self._run(page)

    # -- saving
    def save_as(self):
        page = self.current()
        if not page or page.result is None:
            return
        path, _ = QFileDialog.getSaveFileName(self, "Save as", page.saved_to,
                                              "JPEG (*.jpg);;PNG (*.png);;PDF (*.pdf)")
        if not path:
            return
        if path.lower().endswith(".pdf"):
            write_pdf(path, [page.result])
        else:
            scanner.imwrite(path, page.result)
        self.statusBar().showMessage(f"Saved: {path}")

    def save_pdf(self):
        done = [p for p in self.pages if p.result is not None]
        if not done:
            return
        default = os.path.splitext(done[0].path)[0] + OUTPUT_SUFFIX + ".pdf"
        path, _ = QFileDialog.getSaveFileName(self, "Export PDF", default, "PDF (*.pdf)")
        if not path:
            return
        if not path.lower().endswith(".pdf"):
            path += ".pdf"
        write_pdf(path, [p.result for p in done])
        self.statusBar().showMessage(f"Saved {len(done)}-page PDF: {path}")

    def clear(self):
        self.pages.clear()
        self.list.clear()
        self.act_crop.setChecked(False)
        self.stack.setCurrentIndex(0)
        self.statusBar().clearMessage()
        self._update_actions()


# ------------------------------------------------------------------ entrypoint

def cli(args) -> int:
    images = []
    for f in args.files:
        out, _ = scanner.scan(load_image(f), args.mode, straighten=not args.no_straighten)
        if args.pdf:
            images.append(out)
        else:
            dst = output_path(f)
            scanner.imwrite(dst, out)
            print(dst)
    if args.pdf:
        write_pdf(args.pdf, images)
        print(args.pdf)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="docscan", description="Turns a document photo into a clean scanned document.")
    ap.add_argument("files", nargs="*", help="photo files")
    ap.add_argument("-m", "--mode", choices=scanner.MODES, default="color")
    ap.add_argument("--no-straighten", action="store_true", help="don't straighten bent pages")
    ap.add_argument("--cli", action="store_true", help="process without opening a window")
    ap.add_argument("--pdf", metavar="FILE", help="(with --cli) write everything into one PDF")
    args = ap.parse_args()

    if args.cli:
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    app = QApplication(sys.argv[:1])
    app.setApplicationName("DocScan")
    app.setDesktopFileName("docscan")
    if args.cli:
        return cli(args)

    win = MainWindow()
    win.mode = args.mode
    win.show()
    if args.files:
        win.add_files([os.path.abspath(f) for f in args.files])
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
