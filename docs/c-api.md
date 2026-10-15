# C API

Header: [`engine/src/docscan.h`](../engine/src/docscan.h)

The engine's public interface is a handful of C functions. They are thread-safe, keep no state
between calls, and exchange encoded images (JPEG, PNG, and anything else OpenCV can decode).

## Types

```c
typedef struct {
  uint8_t* data;   /* JPEG bytes, owned by the engine */
  int32_t size;
  int32_t width;
  int32_t height;
} ds_image;
```

Every `ds_image` filled in by the engine must be released with `ds_free`. Releasing an empty image
(all zero) is allowed.

| Mode | Value | Output |
| --- | --- | --- |
| `DS_MODE_COLOR` | 0 | flat white paper, vivid ink |
| `DS_MODE_GRAY` | 1 | grayscale, flattened |
| `DS_MODE_BW` | 2 | black and white |
| `DS_MODE_ORIGINAL` | 3 | perspective-corrected and straightened only |

Corners are always 8 floats: `x, y` of top-left, top-right, bottom-right, bottom-left, in pixels of
the image passed in.

## Functions

### `ds_normalize`

```c
int32_t ds_normalize(const uint8_t* data, int32_t size, int32_t max_side, ds_image* out);
```

Decodes an image, applies its EXIF orientation, scales it down so the long side is at most
`max_side` (0 keeps the size) and re-encodes it as JPEG (quality 95). Use the result as the source
for every later call, so coordinates always match what the user sees.

Returns 0 on success, -1 on failure.

### `ds_normalize_rgba`

```c
int32_t ds_normalize_rgba(const uint8_t* rgba, int32_t width, int32_t height, int32_t max_side,
                          ds_image* out);
```

Same as `ds_normalize`, from tightly packed 8-bit RGBA pixels. Used for formats the platform can
decode but OpenCV cannot, such as HEIC.

### `ds_detect`

```c
int32_t ds_detect(const uint8_t* data, int32_t size, float* corners);
```

Finds the document and writes its corners. Returns 1 if a page was found, 0 if not (the corners are
then the full frame), and -1 on error.

### `ds_process`

```c
int32_t ds_process(const uint8_t* data, int32_t size, const float* corners, int32_t mode,
                   int32_t straighten, int32_t quarter_turns, int32_t jpeg_quality, ds_image* out);
```

Runs the full scan:

1. perspective correction from `corners` (pass `NULL` to detect automatically),
2. straightening if `straighten` is non-zero,
3. the filter `mode`,
4. rotation by `quarter_turns` x 90 degrees clockwise (any integer, taken modulo 4),
5. JPEG encoding at `jpeg_quality` (0 means the default, 92).

Returns 0 on success, -1 on failure.

### `ds_free`, `ds_last_error`, `ds_version`

```c
void ds_free(ds_image* image);
const char* ds_last_error(void);  /* message of the last failure on this thread */
const char* ds_version(void);
```

## Example

```c
#include "docscan.h"

ds_image src = {0}, page = {0};
if (ds_normalize(bytes, len, 4000, &src) != 0) {
  fprintf(stderr, "%s\n", ds_last_error());
  return;
}
float corners[8];
ds_detect(src.data, src.size, corners);
/* ...let the user adjust the corners... */
if (ds_process(src.data, src.size, corners, DS_MODE_COLOR, 1, 0, 92, &page) == 0) {
  write_file("scan.jpg", page.data, page.size);
}
ds_free(&page);
ds_free(&src);
```

## Dart bindings

`engine/lib/docscan_engine.dart` wraps the API for Flutter:

```dart
final src = DocScanEngine.normalize(bytes);
final det = DocScanEngine.detect(src.bytes);
final page = DocScanEngine.process(
  src.bytes,
  corners: det.corners,
  mode: ScanMode.blackWhite,
  straighten: true,
);
```

The calls are synchronous; the app runs them inside `Isolate.run`. Failures throw `EngineException`
with the engine's message.
