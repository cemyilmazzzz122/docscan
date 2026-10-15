# Engine

The engine (`engine/src`) is a C++17 library built on OpenCV. A scan runs four stages:

1. [Document detection](#1-document-detection): find the four corners of the page.
2. [Perspective correction](#2-perspective-correction): map the page to a flat rectangle with its
   real aspect ratio.
3. [Straightening](#3-straightening): undo the bend of curled or folded pages.
4. [Filters](#4-filters): remove shadows and uneven light, then render in the chosen mode.

`ds::scan` in `scanner.cpp` chains them. Each stage can also be called on its own.

## 1. Document detection

`ds::detectDocument(img)`

Detection runs on a copy scaled so its long side is 900 px. Several binary masks are built, each
good at a different kind of photo, and every mask is searched for the best page-shaped quadrilateral:

| Mask | How it is made | Good for |
| --- | --- | --- |
| Edges (x3) | Canny at three threshold pairs, dilated | clear paper edges |
| Brightness | Otsu threshold | white paper on a dark table |
| Paper-likeness | Otsu on `(255 - S) * V / 255` in HSV | white paper on a colorful or wooden table |

Before the masks are built, a morphological close (9x9, 3 iterations) erases the text, so the page
becomes one uniform blob instead of a field of letters.

For each mask, the 8 largest contours are turned into quadrilaterals: convex hull, then
`approxPolyDP` at increasing tolerances until it gives 4 convex points, and the minimum-area
rotated rectangle as a fallback. Each candidate is scored:

```
score = (area / image area) * fill * angle penalty
fill          = min(contour area / quad area, quad area / contour area)
angle penalty = 1 - min(max |cos(corner angle)|, 0.8)
```

Quads below 15% or above 99.5% of the frame are rejected. The best score wins if it is at least 0.12.

One special case: if two or more corners lie on the frame border, the page fills the shot and the
"edge" found is most likely a shadow line. Detection then reports no document, and the whole frame
is used.

## 2. Perspective correction

`ds::warp(img, corners)`

A photographed rectangle becomes a general quadrilateral, so its pixel width and height do not give
the paper's real proportions. The engine recovers the true aspect ratio from the camera geometry
(Zhang and He, *Whiteboard scanning and image enhancement*, 2007):

1. Express the corners as homogeneous points `m1..m4` and solve for the scale factors `k2`, `k3`
   that make them the projection of a rectangle.
2. From those, estimate the focal length `f`, with the principal point at the image center.
3. The aspect ratio is `|A^-1 n2| / |A^-1 n3|`, where `A` is the camera matrix and `n2`, `n3` are the
   projected edge vectors.

If the geometry is degenerate (parallel edges, imaginary focal length, ratio outside 0.2 to 5), the
plain ratio of averaged edge lengths is used instead.

A ratio within 4% of a standard paper size (A series 1:1.414, Letter, Legal) is snapped to it. The
long side of the output keeps the longest edge measured in the photo, so no resolution is lost. The
target is pushed outward by 0.6% on each side so no strip of table survives at the edges, and the
warp uses bicubic sampling with replicated borders.

## 3. Straightening

`ds::dewarp(src, dst)` in `dewarp.cpp`

A page lying in a curve, or still holding a fold, has text lines that bend even after the
perspective is corrected. Instead of fitting a 3D page model, the engine fits a smooth slope field
to the page and integrates it.

**Ink mask.** On a copy 1400 px wide, divide the gray image by its morphological closing (which
removes the text and leaves the light) and apply Otsu. This gives text and rules regardless of
shadows.

**Row samples.** Vertical rules are removed with an opening, then a horizontal-only closing merges the
letters of each line into one long blob. Lines never merge vertically, and blobs taller than 2.2
typical line heights (two lines touching) are skipped. For each remaining blob:

- compute the centerline `y(x)` as the mean row of its pixels in every column,
- fit a polynomial (degree 2 for long blobs, otherwise 1) with one round of outlier rejection, so
  ascenders and descenders do not tilt the line,
- sample its slope `dy/dx` every few pixels.

**Field fit.** All samples `(x, y, slope)` feed a robust least-squares fit of a 2D polynomial
`slope(x, y)`, degree 3 in each direction, with coordinates normalized to [-1, 1]. Three
reweighting rounds drop samples more than 3 robust standard deviations (1.4826 x MAD) from the fit,
and a small ridge term keeps sparse regions from swinging. Slopes are clamped to ±0.2.

**Tracing.** For every output row, the engine starts at the page center and walks left and right
across 48 columns with a midpoint (RK2) step, following the field. The result is the source `y`
of that row at each column. These 48 values per row are resized into a full map, and `cv::remap`
resamples the page so every bent line becomes straight.

**Columns.** The same is done for vertical rules on the transposed image (degree 2 field), after the
rows have been corrected.

**When it does nothing.** With fewer than 40 samples (photos, nearly empty pages) or a largest
correction below 0.003 (about 0.17°), the page is returned untouched. A flat page is never made worse
by trying.

## 4. Filters

`ds::applyMode(img, mode)`

All enhanced modes start by **flattening the light**. For each channel, the paper's illumination is
estimated on an 800 px copy with:

1. a morphological closing with an elliptical kernel larger than text strokes (erases the ink but,
   unlike dilation, does not shift shadow boundaries),
2. a median blur of the same size,
3. a light Gaussian blur.

The channel is divided by this background, so the paper becomes uniformly white while ink keeps its
contrast. Shadows from hands or phones disappear.

| Mode | Steps after flattening |
| --- | --- |
| Color | levels, saturation x1.3, unsharp mask |
| Gray | grayscale, levels, unsharp mask |
| Black & white | grayscale, non-local means denoising, Otsu threshold + 10, speck removal |
| Original | none (perspective and straightening only) |

**Levels** moves the black point to the 1.5th percentile of luminance and the white point to 245,
then applies a gamma of 1.25, so ink gets darker while the paper stays white.

**Unsharp mask:** `1.6 * image - 0.6 * gaussian(image, sigma 1.2)`.

**Speck removal** in black and white mode deletes dark connected components smaller than
`max(3, pixels / 400000)`.

## Verification

The C++ engine is a port of the Python implementation in `desktop/docscan`. Both were run on the same
photos and compared pixel by pixel:

| Photo | Mode | Mean abs. difference (0-255) |
| --- | --- | --- |
| Skewed invoice on a table | color / gray / bw / original | 0.29 / 0.28 / 0.13 / 0.14 |
| Bent form, hand-held | color / gray / bw / original | 0.35 / 0.31 / 0.02 / 0.01 |

The detected corners match to the printed precision. The small remaining differences come from
rounding in intermediate 8-bit steps and from JPEG encoding.

`docscan-cli` makes these checks easy to repeat:

```sh
docscan-cli --corners -m bw photo.jpg out.jpg
```

## Performance notes

- Detection works on a 900 px copy; straightening analysis on a 1400 px copy. Only the final warp,
  remap and filters touch the full resolution.
- Photos are capped at 4000 px on import, which keeps an A4 page well above 300 dpi.
- On a desktop CPU the full pipeline takes about 0.1 to 0.2 s per page.
