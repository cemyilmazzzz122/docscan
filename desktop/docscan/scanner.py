"""Document scanning engine.

Pipeline (the same one the C++ engine in engine/src implements):
  1. Find the document corners
  2. Correct the perspective
  3. Straighten bent/curled pages from their text lines
  4. Apply a filter (color / gray / black & white / original)
"""

from __future__ import annotations

import cv2
import numpy as np

from dewarp import dewarp

MODES = ("color", "gray", "bw", "original")

_DETECT_SIDE = 900  # corner search runs on a copy downscaled to this size


# ------------------------------------------------------------ corner detection

def order_corners(pts: np.ndarray) -> np.ndarray:
    """Orders points as top-left, top-right, bottom-right, bottom-left."""
    pts = np.asarray(pts, dtype=np.float32).reshape(4, 2)
    s = pts.sum(axis=1)
    d = np.diff(pts, axis=1).ravel()
    return np.array(
        [pts[np.argmin(s)], pts[np.argmin(d)], pts[np.argmax(s)], pts[np.argmax(d)]],
        dtype=np.float32,
    )


def _quad_from_contour(cnt: np.ndarray) -> np.ndarray | None:
    peri = cv2.arcLength(cnt, True)
    hull = cv2.convexHull(cnt)
    for eps in (0.02, 0.03, 0.04, 0.06, 0.08):
        approx = cv2.approxPolyDP(hull, eps * peri, True)
        if len(approx) == 4 and cv2.isContourConvex(approx):
            return approx.reshape(4, 2).astype(np.float32)
    # Not reducible to four corners: fall back to the minimum rotated rectangle
    return cv2.boxPoints(cv2.minAreaRect(hull)).astype(np.float32)


def _score_quad(quad: np.ndarray, cnt: np.ndarray, img_area: float) -> float:
    area = cv2.contourArea(quad)
    if area < 0.15 * img_area or area > 0.995 * img_area:
        return 0.0
    # How well the contour fills the quad (rejects trapezoid/curvy blobs)
    fill = min(cv2.contourArea(cnt) / area, area / max(cv2.contourArea(cnt), 1.0))
    q = order_corners(quad)
    angles = []
    for i in range(4):
        a, b, c = q[i - 1], q[i], q[(i + 1) % 4]
        v1, v2 = a - b, c - b
        cos = abs(np.dot(v1, v2) / (np.linalg.norm(v1) * np.linalg.norm(v2) + 1e-6))
        angles.append(cos)
    angle_pen = 1.0 - min(max(angles), 0.8)  # penalize corners far from 90°
    return (area / img_area) * fill * angle_pen


def _candidate_masks(small: np.ndarray):
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    # Erase the text so the paper becomes one flat blob
    k = cv2.getStructuringElement(cv2.MORPH_RECT, (9, 9))
    closed = cv2.morphologyEx(gray, cv2.MORPH_CLOSE, k, iterations=3)
    blur = cv2.GaussianBlur(closed, (5, 5), 0)

    for lo, hi in ((30, 90), (60, 160), (10, 50)):
        edges = cv2.Canny(blur, lo, hi)
        yield cv2.dilate(edges, np.ones((3, 3), np.uint8), iterations=2)

    _, otsu = cv2.threshold(blur, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    yield otsu

    # Paper is usually less saturated and brighter than the table
    hsv = cv2.cvtColor(cv2.morphologyEx(small, cv2.MORPH_CLOSE, k, iterations=3), cv2.COLOR_BGR2HSV)
    paper = (255 - hsv[:, :, 1]).astype(np.float32) * hsv[:, :, 2].astype(np.float32) / 255.0
    paper = cv2.GaussianBlur(paper.astype(np.uint8), (7, 7), 0)
    _, sat = cv2.threshold(paper, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    yield sat


def detect_document(img: np.ndarray) -> np.ndarray | None:
    """Returns the document's 4 corners in original image coordinates, or None."""
    h, w = img.shape[:2]
    scale = _DETECT_SIDE / max(h, w)
    small = cv2.resize(img, (round(w * scale), round(h * scale)), interpolation=cv2.INTER_AREA) if scale < 1 else img
    scale = min(scale, 1.0)
    img_area = small.shape[0] * small.shape[1]

    best, best_score = None, 0.0
    for mask in _candidate_masks(small):
        contours, _ = cv2.findContours(mask, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        for cnt in sorted(contours, key=cv2.contourArea, reverse=True)[:8]:
            quad = _quad_from_contour(cnt)
            if quad is None:
                continue
            score = _score_quad(quad, cnt, img_area)
            if score > best_score:
                best, best_score = quad, score

    if best is None or best_score < 0.12:
        return None
    # Two or more corners on the frame edge means the document fills the shot;
    # the "edge" found is most likely a shadow boundary.
    sh, sw = small.shape[:2]
    m = 0.015 * max(sh, sw)
    on_border = sum(x < m or y < m or x > sw - 1 - m or y > sh - 1 - m for x, y in best)
    if on_border >= 2:
        return None
    return order_corners(best / scale)


def full_frame(img: np.ndarray) -> np.ndarray:
    h, w = img.shape[:2]
    return np.array([[0, 0], [w - 1, 0], [w - 1, h - 1], [0, h - 1]], dtype=np.float32)


# ------------------------------------------------------ perspective correction

_PAPER_RATIOS = (2 ** 0.5, 11 / 8.5, 14 / 8.5)  # A series, Letter, Legal


def _true_aspect(corners: np.ndarray, img_size: tuple[int, int]) -> float | None:
    """Estimates the real width/height ratio of the photographed quad from camera geometry
    (Zhang & He, "Whiteboard scanning and image enhancement")."""
    tl, tr, br, bl = order_corners(corners).astype(np.float64)
    m1, m2, m3, m4 = (np.append(p, 1.0) for p in (tl, tr, bl, br))
    k2 = np.dot(np.cross(m1, m4), m3) / np.dot(np.cross(m2, m4), m3)
    k3 = np.dot(np.cross(m1, m4), m2) / np.dot(np.cross(m3, m4), m2)
    n2 = k2 * m2 - m1
    n3 = k3 * m3 - m1
    u0, v0 = img_size[0] / 2.0, img_size[1] / 2.0
    w_px = np.linalg.norm(tr - tl) + np.linalg.norm(br - bl)
    h_px = np.linalg.norm(bl - tl) + np.linalg.norm(br - tr)

    if abs(n2[2]) < 1e-6 or abs(n3[2]) < 1e-6:  # parallel edges: no foreshortening
        return float(w_px / h_px)
    f2 = -((n2[0] * n3[0] - (n2[0] * n3[2] + n2[2] * n3[0]) * u0 + n2[2] * n3[2] * u0 * u0)
           + (n2[1] * n3[1] - (n2[1] * n3[2] + n2[2] * n3[1]) * v0 + n2[2] * n3[2] * v0 * v0)) / (n2[2] * n3[2])
    if not np.isfinite(f2) or f2 <= 0:
        return float(w_px / h_px)
    a_inv = np.linalg.inv(np.array([[np.sqrt(f2), 0, u0], [0, np.sqrt(f2), v0], [0, 0, 1]]))
    q = a_inv.T @ a_inv
    ratio = np.sqrt((n2 @ q @ n2) / (n3 @ q @ n3))
    if not np.isfinite(ratio) or not 0.2 < ratio < 5:
        return float(w_px / h_px)
    return float(ratio)


def warp(img: np.ndarray, corners: np.ndarray, inset: float = 0.006) -> np.ndarray:
    tl, tr, br, bl = order_corners(corners)
    w_px = max(np.linalg.norm(tr - tl), np.linalg.norm(br - bl))
    h_px = max(np.linalg.norm(bl - tl), np.linalg.norm(br - tr))
    ratio = _true_aspect(corners, (img.shape[1], img.shape[0])) or (w_px / h_px)
    # Snap to a standard paper ratio when very close
    for paper in _PAPER_RATIOS:
        for r in (paper, 1 / paper):
            if abs(ratio / r - 1) < 0.04:
                ratio = r
    # Keep resolution: take the long side from the longest edge in the photo
    long_side = max(w_px, h_px)
    if ratio >= 1:
        width, height = long_side, long_side / ratio
    else:
        width, height = long_side * ratio, long_side
    width, height = int(round(width)), int(round(height))

    # Push the target slightly outward so no strip of table remains at the edges
    dx, dy = width * inset, height * inset
    dst = np.array([[-dx, -dy], [width - 1 + dx, -dy], [width - 1 + dx, height - 1 + dy], [-dx, height - 1 + dy]],
                   dtype=np.float32)
    m = cv2.getPerspectiveTransform(np.array([tl, tr, br, bl]), dst)
    return cv2.warpPerspective(img, m, (width, height), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)


# --------------------------------------------------------------------- filters

def _background(channel: np.ndarray) -> np.ndarray:
    """Estimates the paper's illumination (shadows, light gradient), ignoring the text."""
    h, w = channel.shape
    s = 800 / max(h, w)
    small = cv2.resize(channel, (max(1, round(w * s)), max(1, round(h * s))), interpolation=cv2.INTER_AREA)
    # A kernel thicker than text strokes, thinner than shadow edges
    k = max(7, (max(small.shape) // 50) | 1)
    # Closing: erases text but, unlike dilate, doesn't shift shadow boundaries
    bg = cv2.morphologyEx(small, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
    bg = cv2.medianBlur(bg, k)
    bg = cv2.GaussianBlur(bg, (0, 0), k / 5)
    return cv2.resize(bg, (w, h), interpolation=cv2.INTER_CUBIC)


def _flatten(img: np.ndarray) -> np.ndarray:
    """Divides each channel by its own background, pulling the paper to flat white."""
    chans = cv2.split(img) if img.ndim == 3 else [img]
    out = []
    for c in chans:
        bg = _background(c).astype(np.float32)
        out.append(np.clip(c.astype(np.float32) / np.maximum(bg, 1.0) * 255.0, 0, 255))
    return cv2.merge(out) if len(out) > 1 else out[0]


def _levels(img: np.ndarray, black_pct: float = 1.5, gamma: float = 1.25) -> np.ndarray:
    """Pulls in the black point to darken ink while keeping whites white."""
    lum = img if img.ndim == 2 else cv2.cvtColor(img.astype(np.uint8), cv2.COLOR_BGR2GRAY)
    black = float(np.percentile(lum, black_pct))
    white = 245.0
    black = min(black, white - 40)
    x = np.clip((img.astype(np.float32) - black) / (white - black), 0, 1)
    x = x ** gamma
    return (x * 255).astype(np.uint8)


def _sharpen(img: np.ndarray, amount: float = 0.6, sigma: float = 1.2) -> np.ndarray:
    blur = cv2.GaussianBlur(img, (0, 0), sigma)
    return cv2.addWeighted(img, 1 + amount, blur, -amount, 0)


def _boost_saturation(img: np.ndarray, factor: float = 1.3) -> np.ndarray:
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV).astype(np.float32)
    hsv[:, :, 1] = np.clip(hsv[:, :, 1] * factor, 0, 255)
    return cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2BGR)


def enhance_color(img: np.ndarray) -> np.ndarray:
    flat = _flatten(img)
    out = _levels(flat)
    out = _boost_saturation(out)
    return _sharpen(out)


def enhance_gray(img: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    out = _levels(_flatten(gray))
    return _sharpen(out)


def enhance_bw(img: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    flat = _flatten(gray).astype(np.uint8)
    flat = cv2.fastNlMeansDenoising(flat, h=10)
    # On the flattened image a single threshold separates ink from paper
    t, _ = cv2.threshold(flat, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    _, bw = cv2.threshold(flat, min(t + 10, 235), 255, cv2.THRESH_BINARY)
    # Remove isolated specks
    n, labels, stats, _ = cv2.connectedComponentsWithStats(255 - bw, connectivity=8)
    min_area = max(3, (bw.shape[0] * bw.shape[1]) // 400000)
    specks = np.isin(labels, np.where(stats[:, cv2.CC_STAT_AREA] < min_area)[0][1:])
    bw[specks] = 255
    return bw


def apply_mode(img: np.ndarray, mode: str) -> np.ndarray:
    if mode == "color":
        return enhance_color(img)
    if mode == "gray":
        return enhance_gray(img)
    if mode == "bw":
        return enhance_bw(img)
    return img


# ------------------------------------------------------------------- file I/O

def imread(path: str) -> np.ndarray:
    data = np.fromfile(path, dtype=np.uint8)  # handles non-ASCII paths
    img = cv2.imdecode(data, cv2.IMREAD_COLOR)  # applies EXIF orientation
    if img is None:
        raise ValueError(f"Could not read image: {path}")
    return img


def imwrite(path: str, img: np.ndarray) -> None:
    ext = "." + path.rsplit(".", 1)[-1].lower()
    params = [cv2.IMWRITE_JPEG_QUALITY, 92] if ext in (".jpg", ".jpeg") else []
    ok, buf = cv2.imencode(ext, img, params)
    if not ok:
        raise ValueError(f"Could not save: {path}")
    buf.tofile(path)


def scan(img: np.ndarray, mode: str = "color", corners: np.ndarray | None = None,
         straighten: bool = True) -> tuple[np.ndarray, np.ndarray]:
    """Runs the whole pipeline. Returns (result, corners used)."""
    if corners is None:
        corners = detect_document(img)
        if corners is None:
            corners = full_frame(img)
    page = warp(img, corners)
    if straighten:
        page, _ = dewarp(page)
    return apply_mode(page, mode), corners
