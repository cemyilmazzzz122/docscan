/*
 * DocScan engine - C API.
 *
 * A small, stateless interface so it can be called from any language (Dart FFI, Swift, JNI, ...).
 * Every function is thread-safe. Images that the engine returns must be released with ds_free().
 */
#ifndef DOCSCAN_H
#define DOCSCAN_H

#include <stdint.h>

#if defined(_WIN32)
#define DS_API __declspec(dllexport)
#else
#define DS_API __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Output filters */
enum {
  DS_MODE_COLOR = 0,    /* flat white paper, vivid ink */
  DS_MODE_GRAY = 1,     /* grayscale, flattened */
  DS_MODE_BW = 2,       /* black & white, like a photocopy */
  DS_MODE_ORIGINAL = 3  /* perspective-corrected only */
};

/* An encoded image (JPEG) owned by the engine. */
typedef struct {
  uint8_t* data;
  int32_t size;
  int32_t width;
  int32_t height;
} ds_image;

/* Decodes any supported image (applies EXIF rotation), shrinks it so the long side is at most
 * max_side (0 = keep), and re-encodes it as JPEG. Returns 0 on success. */
DS_API int32_t ds_normalize(const uint8_t* data, int32_t size, int32_t max_side, ds_image* out);

/* Same as ds_normalize, but from raw RGBA pixels (for formats the engine cannot decode). */
DS_API int32_t ds_normalize_rgba(const uint8_t* rgba, int32_t width, int32_t height, int32_t max_side,
                                 ds_image* out);

/* Finds the document. Writes 8 floats (x,y of top-left, top-right, bottom-right, bottom-left).
 * Returns 1 if a document was found, 0 if not (corners are then the full frame), -1 on error. */
DS_API int32_t ds_detect(const uint8_t* data, int32_t size, float* corners);

/* Runs the scan: perspective correction from corners (NULL = detect automatically), optional
 * straightening of bent pages, the filter, then quarter_turns x 90 degrees clockwise rotation.
 * Returns 0 on success. */
DS_API int32_t ds_process(const uint8_t* data, int32_t size, const float* corners, int32_t mode,
                          int32_t straighten, int32_t quarter_turns, int32_t jpeg_quality, ds_image* out);

/* Releases an image returned by the engine. Safe to call on an empty image. */
DS_API void ds_free(ds_image* image);

/* Message for the last failure on the calling thread. */
DS_API const char* ds_last_error(void);

DS_API const char* ds_version(void);

#ifdef __cplusplus
}
#endif

#endif /* DOCSCAN_H */
