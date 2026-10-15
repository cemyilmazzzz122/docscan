// C API wrapper around the scanning pipeline.
#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>
#include <vector>

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include "docscan.h"
#include "scanner.hpp"

namespace {

thread_local std::string lastError;

int32_t fail(const std::string& message) {
  lastError = message;
  return -1;
}

cv::Mat decode(const uint8_t* data, int32_t size) {
  if (!data || size <= 0) return {};
  const cv::Mat buf(1, size, CV_8U, const_cast<uint8_t*>(data));
  return cv::imdecode(buf, cv::IMREAD_COLOR);  // applies EXIF orientation
}

void shrink(cv::Mat& img, int32_t maxSide) {
  const int side = std::max(img.cols, img.rows);
  if (maxSide <= 0 || side <= maxSide) return;
  const double s = static_cast<double>(maxSide) / side;
  cv::resize(img, img, {(int)std::lround(img.cols * s), (int)std::lround(img.rows * s)}, 0, 0, cv::INTER_AREA);
}

int32_t encode(const cv::Mat& img, int32_t quality, ds_image* out) {
  std::vector<uchar> buf;
  const std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, quality > 0 ? quality : 92};
  if (!cv::imencode(".jpg", img, buf, params)) return fail("could not encode the image");
  out->data = static_cast<uint8_t*>(std::malloc(buf.size()));
  if (!out->data) return fail("out of memory");
  std::memcpy(out->data, buf.data(), buf.size());
  out->size = static_cast<int32_t>(buf.size());
  out->width = img.cols;
  out->height = img.rows;
  return 0;
}

template <typename F>
int32_t guarded(F&& body) {
  try {
    return body();
  } catch (const std::exception& e) {
    return fail(e.what());
  } catch (...) {
    return fail("unknown error");
  }
}

}  // namespace

extern "C" {

DS_API int32_t ds_normalize(const uint8_t* data, int32_t size, int32_t max_side, ds_image* out) {
  if (!out) return fail("out is null");
  *out = {};
  return guarded([&] {
    cv::Mat img = decode(data, size);
    if (img.empty()) return fail("unsupported or damaged image");
    shrink(img, max_side);
    return encode(img, 95, out);
  });
}

DS_API int32_t ds_normalize_rgba(const uint8_t* rgba, int32_t width, int32_t height, int32_t max_side,
                                 ds_image* out) {
  if (!out) return fail("out is null");
  *out = {};
  if (!rgba || width <= 0 || height <= 0) return fail("empty image");
  return guarded([&] {
    const cv::Mat src(height, width, CV_8UC4, const_cast<uint8_t*>(rgba));
    cv::Mat img;
    cv::cvtColor(src, img, cv::COLOR_RGBA2BGR);
    shrink(img, max_side);
    return encode(img, 95, out);
  });
}

DS_API int32_t ds_detect(const uint8_t* data, int32_t size, float* corners) {
  if (!corners) return fail("corners is null");
  return guarded([&] {
    const cv::Mat img = decode(data, size);
    if (img.empty()) return fail("unsupported or damaged image");
    const auto found = ds::detectDocument(img);
    const ds::Quad q = found.value_or(ds::fullFrame(img));
    for (int i = 0; i < 4; i++) {
      corners[2 * i] = q[i].x;
      corners[2 * i + 1] = q[i].y;
    }
    return found ? 1 : 0;
  });
}

DS_API int32_t ds_process(const uint8_t* data, int32_t size, const float* corners, int32_t mode,
                          int32_t straighten, int32_t quarter_turns, int32_t jpeg_quality, ds_image* out) {
  if (!out) return fail("out is null");
  *out = {};
  if (mode < DS_MODE_COLOR || mode > DS_MODE_ORIGINAL) return fail("unknown mode");
  return guarded([&] {
    const cv::Mat img = decode(data, size);
    if (img.empty()) return fail("unsupported or damaged image");
    std::optional<ds::Quad> quad;
    if (corners) {
      ds::Quad q;
      for (int i = 0; i < 4; i++) q[i] = {corners[2 * i], corners[2 * i + 1]};
      quad = q;
    }
    cv::Mat page = ds::scan(img, static_cast<ds::Mode>(mode), quad, straighten != 0);
    switch (((quarter_turns % 4) + 4) % 4) {
      case 1: cv::rotate(page, page, cv::ROTATE_90_CLOCKWISE); break;
      case 2: cv::rotate(page, page, cv::ROTATE_180); break;
      case 3: cv::rotate(page, page, cv::ROTATE_90_COUNTERCLOCKWISE); break;
      default: break;
    }
    return encode(page, jpeg_quality, out);
  });
}

DS_API void ds_free(ds_image* image) {
  if (!image) return;
  std::free(image->data);
  *image = {};
}

DS_API const char* ds_last_error(void) { return lastError.c_str(); }

DS_API const char* ds_version(void) { return "1.0.0"; }

}  // extern "C"
