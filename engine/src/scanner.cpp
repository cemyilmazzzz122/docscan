#include "scanner.hpp"

#include <algorithm>
#include <cmath>
#include <vector>

#include <opencv2/imgproc.hpp>
#include <opencv2/photo.hpp>
#if __has_include(<opencv2/geometry.hpp>)
#include <opencv2/geometry.hpp>  // OpenCV 5: contours and transforms live here
#endif

#include "dewarp.hpp"

namespace ds {
namespace {

constexpr int kDetectSide = 900;  // corner search runs on a copy downscaled to this size

// ------------------------------------------------------------ corner detection

std::vector<cv::Point2f> quadFromContour(const std::vector<cv::Point>& cnt) {
  const double peri = cv::arcLength(cnt, true);
  std::vector<cv::Point> hull;
  cv::convexHull(cnt, hull);
  for (double eps : {0.02, 0.03, 0.04, 0.06, 0.08}) {
    std::vector<cv::Point> approx;
    cv::approxPolyDP(hull, approx, eps * peri, true);
    if (approx.size() == 4 && cv::isContourConvex(approx)) {
      return {approx.begin(), approx.end()};
    }
  }
  // Not reducible to four corners: fall back to the minimum rotated rectangle
  cv::Point2f box[4];
  cv::minAreaRect(hull).points(box);
  return {box, box + 4};
}

double scoreQuad(const std::vector<cv::Point2f>& quad, const std::vector<cv::Point>& cnt, double imgArea) {
  const double area = cv::contourArea(quad);
  if (area < 0.15 * imgArea || area > 0.995 * imgArea) return 0.0;
  // How well the contour fills the quad (rejects trapezoid/curvy blobs)
  const double cntArea = cv::contourArea(cnt);
  const double fill = std::min(cntArea / area, area / std::max(cntArea, 1.0));
  const Quad q = orderCorners(quad);
  double worst = 0.0;
  for (int i = 0; i < 4; i++) {
    const cv::Point2f a = q[(i + 3) % 4], b = q[i], c = q[(i + 1) % 4];
    const cv::Point2f v1 = a - b, v2 = c - b;
    const double cos = std::abs(v1.dot(v2) / (cv::norm(v1) * cv::norm(v2) + 1e-6));
    worst = std::max(worst, cos);
  }
  const double anglePen = 1.0 - std::min(worst, 0.8);  // penalize corners far from 90°
  return (area / imgArea) * fill * anglePen;
}

std::vector<cv::Mat> candidateMasks(const cv::Mat& small) {
  std::vector<cv::Mat> masks;
  cv::Mat gray, closed, blur;
  cv::cvtColor(small, gray, cv::COLOR_BGR2GRAY);
  // Erase the text so the paper becomes one flat blob
  const cv::Mat k = cv::getStructuringElement(cv::MORPH_RECT, {9, 9});
  cv::morphologyEx(gray, closed, cv::MORPH_CLOSE, k, {-1, -1}, 3);
  cv::GaussianBlur(closed, blur, {5, 5}, 0);

  const cv::Mat k3 = cv::getStructuringElement(cv::MORPH_RECT, {3, 3});
  for (auto [lo, hi] : {std::pair{30, 90}, {60, 160}, {10, 50}}) {
    cv::Mat edges;
    cv::Canny(blur, edges, lo, hi);
    cv::dilate(edges, edges, k3, {-1, -1}, 2);
    masks.push_back(edges);
  }

  cv::Mat otsu;
  cv::threshold(blur, otsu, 0, 255, cv::THRESH_BINARY | cv::THRESH_OTSU);
  masks.push_back(otsu);

  // Paper is usually less saturated and brighter than the table
  cv::Mat closedColor, hsv;
  cv::morphologyEx(small, closedColor, cv::MORPH_CLOSE, k, {-1, -1}, 3);
  cv::cvtColor(closedColor, hsv, cv::COLOR_BGR2HSV);
  cv::Mat paper(hsv.size(), CV_8UC1);
  for (int y = 0; y < hsv.rows; y++) {
    const auto* p = hsv.ptr<cv::Vec3b>(y);
    auto* o = paper.ptr<uchar>(y);
    for (int x = 0; x < hsv.cols; x++) {
      o[x] = static_cast<uchar>((255.0f - p[x][1]) * p[x][2] / 255.0f);
    }
  }
  cv::GaussianBlur(paper, paper, {7, 7}, 0);
  cv::Mat sat;
  cv::threshold(paper, sat, 0, 255, cv::THRESH_BINARY | cv::THRESH_OTSU);
  masks.push_back(sat);
  return masks;
}

// ------------------------------------------------------ perspective correction

constexpr double kPaperRatios[] = {1.4142135623730951, 11.0 / 8.5, 14.0 / 8.5};  // A series, Letter, Legal

// Estimates the real width/height ratio of the photographed quad from camera geometry
// (Zhang & He, "Whiteboard scanning and image enhancement").
double trueAspect(const Quad& corners, cv::Size imgSize) {
  const cv::Point2d tl = corners[0], tr = corners[1], br = corners[2], bl = corners[3];
  const cv::Vec3d m1(tl.x, tl.y, 1), m2(tr.x, tr.y, 1), m3(bl.x, bl.y, 1), m4(br.x, br.y, 1);
  const double k2 = m1.cross(m4).dot(m3) / m2.cross(m4).dot(m3);
  const double k3 = m1.cross(m4).dot(m2) / m3.cross(m4).dot(m2);
  const cv::Vec3d n2 = k2 * m2 - m1, n3 = k3 * m3 - m1;
  const double u0 = imgSize.width / 2.0, v0 = imgSize.height / 2.0;
  const double wPx = cv::norm(tr - tl) + cv::norm(br - bl);
  const double hPx = cv::norm(bl - tl) + cv::norm(br - tr);
  const double fallback = wPx / hPx;

  if (std::abs(n2[2]) < 1e-6 || std::abs(n3[2]) < 1e-6) return fallback;  // parallel edges
  const double f2 = -((n2[0] * n3[0] - (n2[0] * n3[2] + n2[2] * n3[0]) * u0 + n2[2] * n3[2] * u0 * u0) +
                      (n2[1] * n3[1] - (n2[1] * n3[2] + n2[2] * n3[1]) * v0 + n2[2] * n3[2] * v0 * v0)) /
                    (n2[2] * n3[2]);
  if (!std::isfinite(f2) || f2 <= 0) return fallback;
  // |A^-1 n|^2 with A = [[f,0,u0],[0,f,v0],[0,0,1]]
  const double f = std::sqrt(f2);
  auto len2 = [&](const cv::Vec3d& n) {
    const double a = (n[0] - u0 * n[2]) / f, b = (n[1] - v0 * n[2]) / f, c = n[2];
    return a * a + b * b + c * c;
  };
  const double ratio = std::sqrt(len2(n2) / len2(n3));
  if (!std::isfinite(ratio) || ratio <= 0.2 || ratio >= 5) return fallback;
  return ratio;
}

// --------------------------------------------------------------------- filters

// Estimates the paper's illumination (shadows, light gradient), ignoring the text.
cv::Mat background(const cv::Mat& channel) {
  const int h = channel.rows, w = channel.cols;
  const double s = 800.0 / std::max(h, w);
  cv::Mat small;
  cv::resize(channel, small, {std::max(1, (int)std::lround(w * s)), std::max(1, (int)std::lround(h * s))}, 0, 0,
             cv::INTER_AREA);
  // A kernel thicker than text strokes, thinner than shadow edges
  const int k = std::max(7, (std::max(small.rows, small.cols) / 50) | 1);
  cv::Mat bg;
  // Closing: erases text but, unlike dilate, doesn't shift shadow boundaries
  cv::morphologyEx(small, bg, cv::MORPH_CLOSE, cv::getStructuringElement(cv::MORPH_ELLIPSE, {k, k}));
  cv::medianBlur(bg, bg, k);
  cv::GaussianBlur(bg, bg, {0, 0}, k / 5.0);
  cv::Mat out;
  cv::resize(bg, out, channel.size(), 0, 0, cv::INTER_CUBIC);
  return out;
}

// Divides each channel by its own background, pulling the paper to flat white. Returns CV_32F.
cv::Mat flatten(const cv::Mat& img) {
  std::vector<cv::Mat> chans;
  cv::split(img, chans);
  for (auto& c : chans) {
    cv::Mat bg, cf;
    background(c).convertTo(bg, CV_32F);
    bg = cv::max(bg, 1.0);
    c.convertTo(cf, CV_32F);
    cv::divide(cf, bg, cf, 255.0);
    c = cv::min(cv::max(cf, 0.0), 255.0);
  }
  cv::Mat out;
  cv::merge(chans, out);
  return out;
}

double percentile8(const cv::Mat& gray, double pct) {
  int hist[256] = {0};
  for (int y = 0; y < gray.rows; y++) {
    const uchar* p = gray.ptr<uchar>(y);
    for (int x = 0; x < gray.cols; x++) hist[p[x]]++;
  }
  const double pos = pct / 100.0 * (static_cast<double>(gray.total()) - 1);
  const auto at = [&](long long k) {
    long long acc = 0;
    for (int v = 0; v < 256; v++) {
      acc += hist[v];
      if (acc > k) return v;
    }
    return 255;
  };
  const long long lo = static_cast<long long>(std::floor(pos));
  const double frac = pos - lo;
  const int a = at(lo), b = frac > 0 ? at(lo + 1) : a;
  return a + (b - a) * frac;
}

// Pulls in the black point to darken ink while keeping whites white. Float input, 8-bit output.
cv::Mat levels(const cv::Mat& img, double blackPct = 1.5, double gamma = 1.25) {
  cv::Mat lum8;
  if (img.channels() == 1) {
    img.convertTo(lum8, CV_8U);
  } else {
    cv::Mat u8;
    img.convertTo(u8, CV_8U);
    cv::cvtColor(u8, lum8, cv::COLOR_BGR2GRAY);
  }
  const double white = 245.0;
  const double black = std::min(percentile8(lum8, blackPct), white - 40);
  cv::Mat x;
  img.convertTo(x, CV_32F, 1.0 / (white - black), -black / (white - black));
  x = cv::min(cv::max(x, 0.0), 1.0);
  cv::pow(x, gamma, x);
  cv::Mat out;
  x.convertTo(out, CV_8U, 255.0);
  return out;
}

cv::Mat sharpen(const cv::Mat& img, double amount = 0.6, double sigma = 1.2) {
  cv::Mat blur, out;
  cv::GaussianBlur(img, blur, {0, 0}, sigma);
  cv::addWeighted(img, 1 + amount, blur, -amount, 0, out);
  return out;
}

cv::Mat boostSaturation(const cv::Mat& img, double factor = 1.3) {
  cv::Mat hsv;
  cv::cvtColor(img, hsv, cv::COLOR_BGR2HSV);
  std::vector<cv::Mat> ch;
  cv::split(hsv, ch);
  cv::Mat lut(1, 256, CV_8U);
  for (int i = 0; i < 256; i++) lut.at<uchar>(i) = static_cast<uchar>(std::min(255.0, i * factor));
  cv::LUT(ch[1], lut, ch[1]);
  cv::merge(ch, hsv);
  cv::Mat out;
  cv::cvtColor(hsv, out, cv::COLOR_HSV2BGR);
  return out;
}

cv::Mat toGray(const cv::Mat& img) {
  if (img.channels() == 1) return img;
  cv::Mat g;
  cv::cvtColor(img, g, cv::COLOR_BGR2GRAY);
  return g;
}

cv::Mat enhanceColor(const cv::Mat& img) {
  if (img.channels() == 1) return sharpen(levels(flatten(img)));
  return sharpen(boostSaturation(levels(flatten(img))));
}

cv::Mat enhanceGray(const cv::Mat& img) { return sharpen(levels(flatten(toGray(img)))); }

cv::Mat enhanceBlackWhite(const cv::Mat& img) {
  cv::Mat flat;
  flatten(toGray(img)).convertTo(flat, CV_8U);
  cv::fastNlMeansDenoising(flat, flat, 10);
  // On the flattened image a single threshold separates ink from paper
  cv::Mat tmp, bw;
  const double t = cv::threshold(flat, tmp, 0, 255, cv::THRESH_BINARY | cv::THRESH_OTSU);
  cv::threshold(flat, bw, std::min(t + 10, 235.0), 255, cv::THRESH_BINARY);
  // Remove isolated specks
  cv::Mat labels, stats, centroids;
  const int n = cv::connectedComponentsWithStats(255 - bw, labels, stats, centroids, 8, CV_32S);
  const int minArea = std::max(3, static_cast<int>(bw.total() / 400000));
  std::vector<uchar> speck(n, 0);
  for (int i = 1; i < n; i++) speck[i] = stats.at<int>(i, cv::CC_STAT_AREA) < minArea;
  for (int y = 0; y < bw.rows; y++) {
    const int* l = labels.ptr<int>(y);
    uchar* p = bw.ptr<uchar>(y);
    for (int x = 0; x < bw.cols; x++) {
      if (speck[l[x]]) p[x] = 255;
    }
  }
  return bw;
}

}  // namespace

Quad orderCorners(const std::vector<cv::Point2f>& pts) {
  CV_Assert(pts.size() == 4);
  auto pick = [&](auto key, bool max) {
    size_t best = 0;
    for (size_t i = 1; i < 4; i++) {
      if (max ? key(pts[i]) > key(pts[best]) : key(pts[i]) < key(pts[best])) best = i;
    }
    return pts[best];
  };
  auto sum = [](const cv::Point2f& p) { return p.x + p.y; };
  auto diff = [](const cv::Point2f& p) { return p.y - p.x; };
  return {pick(sum, false), pick(diff, false), pick(sum, true), pick(diff, true)};
}

std::optional<Quad> detectDocument(const cv::Mat& img) {
  const int h = img.rows, w = img.cols;
  double scale = static_cast<double>(kDetectSide) / std::max(h, w);
  cv::Mat small = img;
  if (scale < 1) {
    cv::resize(img, small, {(int)std::lround(w * scale), (int)std::lround(h * scale)}, 0, 0, cv::INTER_AREA);
  }
  scale = std::min(scale, 1.0);
  if (small.channels() == 1) cv::cvtColor(small, small, cv::COLOR_GRAY2BGR);
  const double imgArea = static_cast<double>(small.rows) * small.cols;

  std::vector<cv::Point2f> best;
  double bestScore = 0.0;
  for (const cv::Mat& mask : candidateMasks(small)) {
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(mask, contours, cv::RETR_LIST, cv::CHAIN_APPROX_SIMPLE);
    std::vector<std::pair<double, size_t>> byArea;
    for (size_t i = 0; i < contours.size(); i++) byArea.emplace_back(cv::contourArea(contours[i]), i);
    std::sort(byArea.begin(), byArea.end(), [](auto& a, auto& b) { return a.first > b.first; });
    for (size_t r = 0; r < std::min<size_t>(8, byArea.size()); r++) {
      const auto& cnt = contours[byArea[r].second];
      const auto quad = quadFromContour(cnt);
      const double score = scoreQuad(quad, cnt, imgArea);
      if (score > bestScore) {
        best = quad;
        bestScore = score;
      }
    }
  }

  if (best.empty() || bestScore < 0.12) return std::nullopt;
  // Two or more corners on the frame edge means the document fills the shot;
  // the "edge" found is most likely a shadow boundary.
  const double m = 0.015 * std::max(small.rows, small.cols);
  int onBorder = 0;
  for (const auto& p : best) {
    onBorder += p.x < m || p.y < m || p.x > small.cols - 1 - m || p.y > small.rows - 1 - m;
  }
  if (onBorder >= 2) return std::nullopt;
  for (auto& p : best) p *= static_cast<float>(1.0 / scale);
  return orderCorners(best);
}

Quad fullFrame(const cv::Mat& img) {
  const float w = img.cols - 1.0f, h = img.rows - 1.0f;
  return {cv::Point2f{0, 0}, {w, 0}, {w, h}, {0, h}};
}

cv::Mat warp(const cv::Mat& img, const Quad& corners, double inset) {
  const Quad q = orderCorners({corners.begin(), corners.end()});
  const auto [tl, tr, br, bl] = q;
  const double wPx = std::max(cv::norm(tr - tl), cv::norm(br - bl));
  const double hPx = std::max(cv::norm(bl - tl), cv::norm(br - tr));
  double ratio = trueAspect(q, img.size());
  // Snap to a standard paper ratio when very close
  for (double paper : kPaperRatios) {
    for (double r : {paper, 1 / paper}) {
      if (std::abs(ratio / r - 1) < 0.04) ratio = r;
    }
  }
  // Keep resolution: take the long side from the longest edge in the photo
  const double longSide = std::max(wPx, hPx);
  const int width = (int)std::lround(ratio >= 1 ? longSide : longSide * ratio);
  const int height = (int)std::lround(ratio >= 1 ? longSide / ratio : longSide);

  // Push the target slightly outward so no strip of background remains at the edges
  const float dx = width * inset, dy = height * inset;
  const cv::Point2f src[4] = {tl, tr, br, bl};
  const cv::Point2f dst[4] = {{-dx, -dy}, {width - 1 + dx, -dy}, {width - 1 + dx, height - 1 + dy}, {-dx, height - 1 + dy}};
  const cv::Mat m = cv::getPerspectiveTransform(src, dst);
  cv::Mat out;
  cv::warpPerspective(img, out, m, {width, height}, cv::INTER_CUBIC, cv::BORDER_REPLICATE);
  return out;
}

cv::Mat applyMode(const cv::Mat& img, Mode mode) {
  switch (mode) {
    case Mode::Color: return enhanceColor(img);
    case Mode::Gray: return enhanceGray(img);
    case Mode::BlackWhite: return enhanceBlackWhite(img);
    case Mode::Original: break;
  }
  return img;
}

cv::Mat scan(const cv::Mat& img, Mode mode, const std::optional<Quad>& corners, bool straighten) {
  const Quad c = corners ? *corners : detectDocument(img).value_or(fullFrame(img));
  cv::Mat page = warp(img, c);
  if (straighten) {
    cv::Mat flat;
    if (dewarp(page, flat)) page = flat;
  }
  return applyMode(page, mode);
}

}  // namespace ds
