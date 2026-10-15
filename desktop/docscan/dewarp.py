"""Page dewarping: straightens bent or curled pages using text lines and ruled lines.

Instead of a full 3D page model, this fits a smooth *slope field* to the page:
  - every text line / horizontal rule tells us the local dy/dx at the points it covers,
  - every vertical rule tells us the local dx/dy.
A low-order 2D polynomial is fitted to those samples (robust least squares), then each
output row is traced through the field so it follows the bent line in the photo, and the
image is resampled with cv2.remap. Rows are corrected first, then columns.
"""

from __future__ import annotations

import cv2
import numpy as np

_WORK_WIDTH = 1400        # analysis runs at this width
_MIN_SAMPLES = 40         # fewer tangent samples than this: not enough evidence, skip
_MIN_SLOPE = 0.003        # largest correction below this (~0.17°): nothing to fix
_MAX_SLOPE = 0.2          # clamp so extrapolated areas can't go wild


# ----------------------------------------------------------------- ink mask

def _ink(gray: np.ndarray) -> np.ndarray:
    """Binary mask of dark marks (text, rules), robust to uneven lighting."""
    k = max(15, (gray.shape[1] // 40) | 1)
    bg = cv2.morphologyEx(gray, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
    flat = cv2.divide(gray, bg, scale=255)
    _, ink = cv2.threshold(flat, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    return ink


# --------------------------------------------------------- tangent samples

def _span_tangents(mask: np.ndarray, min_len: int, max_thick: float, step: int):
    """For each long thin blob, fits its centerline y(x) and returns (x, y, dy/dx, weight) samples."""
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    out = []
    for i in range(1, n):
        x, y, w, h, area = stats[i]
        if w < min_len or h > max_thick or h > w * 0.5:
            continue
        comp = labels[y:y + h, x:x + w] == i
        counts = comp.sum(axis=0)
        cols = np.nonzero(counts)[0]
        if len(cols) < min_len * 0.6:
            continue
        ys = (comp * np.arange(h)[:, None]).sum(axis=0)[cols] / counts[cols] + y
        xs = cols + x
        # Quadratic centerline with one round of outlier rejection (ascenders/descenders)
        deg = 2 if w > 3 * min_len else 1
        coef = np.polyfit(xs, ys, deg)
        resid = ys - np.polyval(coef, xs)
        keep = np.abs(resid) < max(1.0, 2.5 * resid.std())
        if keep.sum() > deg + 3:
            coef = np.polyfit(xs[keep], ys[keep], deg)
        d = np.polyder(coef)
        sx = np.arange(xs.min(), xs.max() + 1, step, dtype=np.float64)
        sy = np.polyval(coef, sx)
        out.append(np.column_stack([sx, sy, np.polyval(d, sx), np.full_like(sx, 1.0)]))
    return np.vstack(out) if out else np.zeros((0, 4))


def _row_samples(ink: np.ndarray) -> np.ndarray:
    h, w = ink.shape
    # Drop vertical rules so they don't glue text lines together
    vert = cv2.morphologyEx(ink, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (1, max(15, h // 40))))
    text = cv2.subtract(ink, vert)
    # Merge the letters of a line into one blob (horizontal-only, so lines never merge vertically)
    blobs = cv2.morphologyEx(text, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_RECT, (max(9, w // 70), 1)))
    blobs = cv2.morphologyEx(blobs, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
    # Typical line height, to reject blobs where two lines touch
    n, _, stats, _ = cv2.connectedComponentsWithStats(blobs, connectivity=8)
    wide = stats[1:][stats[1:, cv2.CC_STAT_WIDTH] > w * 0.08]
    line_h = float(np.median(wide[:, cv2.CC_STAT_HEIGHT])) if len(wide) else h * 0.02
    return _span_tangents(blobs, min_len=int(w * 0.08), max_thick=2.2 * line_h + 2, step=max(4, w // 150))


def _col_samples(ink: np.ndarray) -> np.ndarray:
    h, w = ink.shape
    vert = cv2.morphologyEx(ink, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (1, max(15, h // 25))))
    # Same routine on the transposed image: rows become columns
    s = _span_tangents(vert.T.copy(), min_len=int(h * 0.05), max_thick=max(6, w // 100), step=max(4, h // 150))
    return s[:, [1, 0, 2, 3]] if len(s) else s  # back to (x, y, dx/dy, w)


# ------------------------------------------------------------- field fitting

def _design(x: np.ndarray, y: np.ndarray, dx: int, dy: int) -> np.ndarray:
    return np.column_stack([x ** i * y ** j for i in range(dx + 1) for j in range(dy + 1)])


def _fit_field(samples: np.ndarray, size: tuple[int, int], deg_along: int, deg_across: int):
    """Robust polynomial fit of slope(x, y) in normalized coordinates. Returns a callable or None."""
    if len(samples) < _MIN_SAMPLES:
        return None
    w, h = size
    x, y, s, wt = (samples[:, i] for i in range(4))
    xn, yn = x / w * 2 - 1, y / h * 2 - 1
    a = _design(xn, yn, deg_along, deg_across)
    keep = np.abs(s) < _MAX_SLOPE
    coef = None
    for _ in range(3):
        aw = a[keep] * wt[keep, None]
        # Small ridge term keeps sparse areas from blowing up
        lhs = aw.T @ aw + 1e-5 * len(aw) * np.eye(a.shape[1])
        coef = np.linalg.solve(lhs, aw.T @ (s[keep] * wt[keep]))
        resid = s - a @ coef
        sigma = max(1e-4, 1.4826 * np.median(np.abs(resid[keep])))
        keep = np.abs(resid) < 3 * sigma
    def field(px, py):
        return np.clip(_design(px / w * 2 - 1, py / h * 2 - 1, deg_along, deg_across) @ coef,
                       -_MAX_SLOPE, _MAX_SLOPE)
    return field


def _trace_rows(field, w: int, h: int, n_cols: int = 48) -> np.ndarray:
    """For every output row, the source y at n_cols x-positions, traced from the page center outward."""
    xs = np.linspace(0, w - 1, n_cols)
    c = n_cols // 2
    ys = np.empty((h, n_cols))
    ys[:, c] = np.arange(h, dtype=np.float64)
    for direction in (1, -1):
        j = c
        while 0 <= j + direction < n_cols:
            x0, x1 = xs[j], xs[j + direction]
            y0 = ys[:, j]
            k1 = field(np.full(h, x0), y0)                       # RK2 (midpoint) step
            k2 = field(np.full(h, (x0 + x1) / 2), y0 + k1 * (x1 - x0) / 2)
            ys[:, j + direction] = y0 + k2 * (x1 - x0)
            j += direction
    return ys


def _max_correction(field, w: int, h: int) -> float:
    gx, gy = np.meshgrid(np.linspace(0, w - 1, 15), np.linspace(0, h - 1, 15))
    return float(np.abs(field(gx.ravel(), gy.ravel())).max())


# ----------------------------------------------------------------- public API

def dewarp(img: np.ndarray) -> tuple[np.ndarray, bool]:
    """Straightens bent text lines and rules. Returns (image, whether anything was changed)."""
    h, w = img.shape[:2]
    scale = min(1.0, _WORK_WIDTH / w)
    changed = False
    out = img

    # Pass 1: rows (text lines, horizontal rules)
    small = cv2.resize(out, (round(w * scale), round(h * scale)), interpolation=cv2.INTER_AREA)
    gray = small if small.ndim == 2 else cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    ink = _ink(gray)
    hs, ws = ink.shape
    field = _fit_field(_row_samples(ink), (ws, hs), deg_along=3, deg_across=3)
    if field is not None and _max_correction(field, ws, hs) >= _MIN_SLOPE:
        ys = _trace_rows(field, ws, hs)                                 # (hs, n_cols) in small coords
        map_y = cv2.resize((ys / scale).astype(np.float32), (w, h), interpolation=cv2.INTER_LINEAR)
        map_x = np.broadcast_to(np.arange(w, dtype=np.float32), (h, w)).copy()
        out = cv2.remap(out, map_x, map_y, cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)
        changed = True

    # Pass 2: columns (vertical rules), on the row-corrected image
    small = cv2.resize(out, (round(w * scale), round(h * scale)), interpolation=cv2.INTER_AREA)
    gray = small if small.ndim == 2 else cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    ink = _ink(gray)
    samples = _col_samples(ink)
    if len(samples) >= _MIN_SAMPLES:
        # Swap axes: trace "rows" of the transposed page
        t = samples[:, [1, 0, 2, 3]]
        field = _fit_field(t, (hs, ws), deg_along=2, deg_across=2)
        if field is not None and _max_correction(field, hs, ws) >= _MIN_SLOPE:
            xs = _trace_rows(field, hs, ws)                             # (ws, n_rows): source x per column
            map_x = cv2.resize((xs / scale).astype(np.float32).T, (w, h), interpolation=cv2.INTER_LINEAR)
            map_y = np.broadcast_to(np.arange(h, dtype=np.float32)[:, None], (h, w)).copy()
            out = cv2.remap(out, map_x, map_y, cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)
            changed = True

    return out, changed
