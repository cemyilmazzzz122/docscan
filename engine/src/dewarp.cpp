// Instead of a full 3D page model, this fits a smooth *slope field* to the page:
//   - every text line / horizontal rule tells us the local dy/dx at the points it covers,
//   - every vertical rule tells us the local dx/dy.
// A low-order 2D polynomial is fitted to those samples (robust least squares), then each
// output row is traced through the field so it follows the bent line in the photo, and the
// image is resampled with cv::remap. Rows are corrected first, then columns.
#include "dewarp.hpp"

#include <algorithm>
#include <cmath>
#include <functional>
#include <optional>
#include <vector>

#include <opencv2/imgproc.hpp>

namespace ds {
namespace {

constexpr int kWorkWidth = 1400;    // analysis runs at this width
constexpr size_t kMinSamples = 40;  // fewer tangent samples than this: not enough evidence, skip
constexpr double kMinSlope = 0.003; // largest correction below this (~0.17°): nothing to fix
constexpr double kMaxSlope = 0.2;   // clamp so extrapolated areas can't go wild
constexpr int kTraceCols = 48;      // trace resolution across the page

struct Sample {
  double x, y, slope;
};

double median(std::vector<double> v) {
  if (v.empty()) return 0;
  const size_t m = v.size() / 2;
  std::nth_element(v.begin(), v.begin() + m, v.end());
  if (v.size() % 2) return v[m];
  const double hi = v[m];
  return (*std::max_element(v.begin(), v.begin() + m) + hi) / 2;
}

double stddev(const std::vector<double>& v) {
  if (v.empty()) return 0;
  double mean = 0, s = 0;
  for (double x : v) mean += x;
  mean /= v.size();
  for (double x : v) s += (x - mean) * (x - mean);
  return std::sqrt(s / v.size());
}

// Least-squares polynomial in t = (x - x0) / span. Coefficients c[k] multiply t^k.
struct Poly {
  std::vector<double> c;
  double x0 = 0, span = 1;

  double operator()(double x) const {
    const double t = (x - x0) / span;
    double v = 0;
    for (size_t k = c.size(); k-- > 0;) v = v * t + c[k];
    return v;
  }
  double derivative(double x) const {
    const double t = (x - x0) / span;
    double v = 0;
    for (size_t k = c.size(); k-- > 1;) v = v * t + k * c[k];
    return v / span;
  }
};

Poly polyfit(const std::vector<double>& xs, const std::vector<double>& ys, int deg) {
  Poly p;
  double lo = *std::min_element(xs.begin(), xs.end()), hi = *std::max_element(xs.begin(), xs.end());
  p.x0 = (lo + hi) / 2;
  p.span = std::max((hi - lo) / 2, 1.0);
  cv::Mat a((int)xs.size(), deg + 1, CV_64F), b((int)xs.size(), 1, CV_64F, const_cast<double*>(ys.data())), c;
  for (int i = 0; i < a.rows; i++) {
    const double t = (xs[i] - p.x0) / p.span;
    double v = 1;
    for (int k = 0; k <= deg; k++, v *= t) a.at<double>(i, k) = v;
  }
  cv::solve(a, b, c, cv::DECOMP_QR);
  p.c.assign(c.begin<double>(), c.end<double>());
  return p;
}

// ----------------------------------------------------------------- ink mask

// Binary mask of dark marks (text, rules), robust to uneven lighting.
cv::Mat ink(const cv::Mat& gray) {
  const int k = std::max(15, (gray.cols / 40) | 1);
  cv::Mat bg, flat, out;
  cv::morphologyEx(gray, bg, cv::MORPH_CLOSE, cv::getStructuringElement(cv::MORPH_ELLIPSE, {k, k}));
  cv::divide(gray, bg, flat, 255);
  cv::threshold(flat, out, 0, 255, cv::THRESH_BINARY_INV | cv::THRESH_OTSU);
  return out;
}

// --------------------------------------------------------- tangent samples

// For each long thin blob, fits its centerline y(x) and returns (x, y, dy/dx) samples.
std::vector<Sample> spanTangents(const cv::Mat& mask, int minLen, double maxThick, int step) {
  cv::Mat labels, stats, centroids;
  const int n = cv::connectedComponentsWithStats(mask, labels, stats, centroids, 8, CV_32S);

  // Pick the blobs worth measuring, and give each a per-column accumulator.
  struct Blob {
    int x, w;
    std::vector<double> sumY;
    std::vector<int> count;
  };
  std::vector<int> slot(n, -1);
  std::vector<Blob> blobs;
  for (int i = 1; i < n; i++) {
    const int bx = stats.at<int>(i, cv::CC_STAT_LEFT), bw = stats.at<int>(i, cv::CC_STAT_WIDTH);
    const int bh = stats.at<int>(i, cv::CC_STAT_HEIGHT);
    if (bw < minLen || bh > maxThick || bh > bw * 0.5) continue;
    slot[i] = (int)blobs.size();
    blobs.push_back({bx, bw, std::vector<double>(bw, 0.0), std::vector<int>(bw, 0)});
  }
  if (blobs.empty()) return {};
  for (int y = 0; y < labels.rows; y++) {
    const int* l = labels.ptr<int>(y);
    for (int x = 0; x < labels.cols; x++) {
      const int s = l[x] ? slot[l[x]] : -1;
      if (s < 0) continue;
      Blob& b = blobs[s];
      b.sumY[x - b.x] += y;
      b.count[x - b.x]++;
    }
  }

  std::vector<Sample> out;
  for (const Blob& b : blobs) {
    std::vector<double> xs, ys;
    for (int c = 0; c < b.w; c++) {
      if (b.count[c]) {
        xs.push_back(c + b.x);
        ys.push_back(b.sumY[c] / b.count[c]);
      }
    }
    if (xs.size() < minLen * 0.6) continue;
    // Quadratic centerline with one round of outlier rejection (ascenders/descenders)
    const int deg = b.w > 3 * minLen ? 2 : 1;
    Poly p = polyfit(xs, ys, deg);
    std::vector<double> resid(xs.size());
    for (size_t i = 0; i < xs.size(); i++) resid[i] = ys[i] - p(xs[i]);
    const double lim = std::max(1.0, 2.5 * stddev(resid));
    std::vector<double> kx, ky;
    for (size_t i = 0; i < xs.size(); i++) {
      if (std::abs(resid[i]) < lim) {
        kx.push_back(xs[i]);
        ky.push_back(ys[i]);
      }
    }
    if ((int)kx.size() > deg + 3) p = polyfit(kx, ky, deg);
    for (double sx = xs.front(); sx < xs.back() + 1; sx += step) out.push_back({sx, p(sx), p.derivative(sx)});
  }
  return out;
}

std::vector<Sample> rowSamples(const cv::Mat& inkMask) {
  const int h = inkMask.rows, w = inkMask.cols;
  cv::Mat vert, text, blobs;
  // Drop vertical rules so they don't glue text lines together
  cv::morphologyEx(inkMask, vert, cv::MORPH_OPEN, cv::getStructuringElement(cv::MORPH_RECT, {1, std::max(15, h / 40)}));
  cv::subtract(inkMask, vert, text);
  // Merge the letters of a line into one blob (horizontal-only, so lines never merge vertically)
  cv::morphologyEx(text, blobs, cv::MORPH_CLOSE, cv::getStructuringElement(cv::MORPH_RECT, {std::max(9, w / 70), 1}));
  cv::morphologyEx(blobs, blobs, cv::MORPH_OPEN, cv::getStructuringElement(cv::MORPH_RECT, {2, 2}));

  // Typical line height, to reject blobs where two lines touch
  cv::Mat labels, stats, centroids;
  const int n = cv::connectedComponentsWithStats(blobs, labels, stats, centroids, 8, CV_32S);
  std::vector<double> heights;
  for (int i = 1; i < n; i++) {
    if (stats.at<int>(i, cv::CC_STAT_WIDTH) > w * 0.08) heights.push_back(stats.at<int>(i, cv::CC_STAT_HEIGHT));
  }
  const double lineH = heights.empty() ? h * 0.02 : median(heights);
  return spanTangents(blobs, (int)(w * 0.08), 2.2 * lineH + 2, std::max(4, w / 150));
}

// Vertical-rule samples in transposed form: (y, x, dx/dy).
std::vector<Sample> columnSamplesTransposed(const cv::Mat& inkMask) {
  const int h = inkMask.rows, w = inkMask.cols;
  cv::Mat vert, t;
  cv::morphologyEx(inkMask, vert, cv::MORPH_OPEN, cv::getStructuringElement(cv::MORPH_RECT, {1, std::max(15, h / 25)}));
  // Same routine on the transposed image: rows become columns
  cv::transpose(vert, t);
  return spanTangents(t, (int)(h * 0.05), std::max(6, w / 100), std::max(4, h / 150));
}

// ------------------------------------------------------------- field fitting

using Field = std::function<double(double, double)>;

// Robust polynomial fit of slope(x, y) in normalized coordinates.
std::optional<Field> fitField(const std::vector<Sample>& smp, int w, int h, int degAlong, int degAcross) {
  const size_t n = smp.size();
  if (n < kMinSamples) return std::nullopt;
  const int terms = (degAlong + 1) * (degAcross + 1);
  auto design = [=](double x, double y, double* row) {
    const double xn = x / w * 2 - 1, yn = y / h * 2 - 1;
    double xi = 1;
    for (int i = 0, k = 0; i <= degAlong; i++, xi *= xn) {
      double yj = 1;
      for (int j = 0; j <= degAcross; j++, yj *= yn) row[k++] = xi * yj;
    }
  };

  cv::Mat a((int)n, terms, CV_64F);
  for (size_t i = 0; i < n; i++) design(smp[i].x, smp[i].y, a.ptr<double>((int)i));
  std::vector<char> keep(n);
  for (size_t i = 0; i < n; i++) keep[i] = std::abs(smp[i].slope) < kMaxSlope;
  cv::Mat coef = cv::Mat::zeros(terms, 1, CV_64F);
  auto predict = [&](const double* row) {
    double v = 0;
    for (int k = 0; k < terms; k++) v += row[k] * coef.at<double>(k);
    return v;
  };

  for (int iter = 0; iter < 3; iter++) {
    cv::Mat lhs = cv::Mat::zeros(terms, terms, CV_64F), rhs = cv::Mat::zeros(terms, 1, CV_64F);
    int m = 0;
    for (size_t i = 0; i < n; i++) {
      if (!keep[i]) continue;
      m++;
      const double* r = a.ptr<double>((int)i);
      for (int p = 0; p < terms; p++) {
        rhs.at<double>(p) += r[p] * smp[i].slope;
        for (int q = 0; q < terms; q++) lhs.at<double>(p, q) += r[p] * r[q];
      }
    }
    if (m == 0) return std::nullopt;
    // Small ridge term keeps sparse areas from blowing up
    lhs += cv::Mat::eye(terms, terms, CV_64F) * (1e-5 * m);
    cv::solve(lhs, rhs, coef, cv::DECOMP_CHOLESKY);
    std::vector<double> resid(n), kept;
    for (size_t i = 0; i < n; i++) {
      resid[i] = smp[i].slope - predict(a.ptr<double>((int)i));
      if (keep[i]) kept.push_back(std::abs(resid[i]));
    }
    const double sigma = std::max(1e-4, 1.4826 * median(kept));
    for (size_t i = 0; i < n; i++) keep[i] = std::abs(resid[i]) < 3 * sigma;
  }

  std::vector<double> c(coef.begin<double>(), coef.end<double>());
  return Field([=](double x, double y) {
    double row[16];
    design(x, y, row);
    double v = 0;
    for (int k = 0; k < terms; k++) v += row[k] * c[k];
    return std::clamp(v, -kMaxSlope, kMaxSlope);
  });
}

// For every output row, the source y at kTraceCols x-positions, traced from the page center outward.
cv::Mat traceRows(const Field& field, int w, int h) {
  std::vector<double> xs(kTraceCols);
  for (int j = 0; j < kTraceCols; j++) xs[j] = j * (w - 1.0) / (kTraceCols - 1);
  const int c = kTraceCols / 2;
  cv::Mat ys(h, kTraceCols, CV_64F);
  for (int r = 0; r < h; r++) ys.at<double>(r, c) = r;
  for (int dir : {1, -1}) {
    for (int j = c; j + dir >= 0 && j + dir < kTraceCols; j += dir) {
      const double x0 = xs[j], x1 = xs[j + dir], dx = x1 - x0, xm = (x0 + x1) / 2;
      for (int r = 0; r < h; r++) {
        const double y0 = ys.at<double>(r, j);
        const double k1 = field(x0, y0);  // RK2 (midpoint) step
        const double k2 = field(xm, y0 + k1 * dx / 2);
        ys.at<double>(r, j + dir) = y0 + k2 * dx;
      }
    }
  }
  return ys;
}

double maxCorrection(const Field& field, int w, int h) {
  double m = 0;
  for (int i = 0; i < 15; i++) {
    for (int j = 0; j < 15; j++) m = std::max(m, std::abs(field(j * (w - 1) / 14.0, i * (h - 1) / 14.0)));
  }
  return m;
}

cv::Mat analysisInk(const cv::Mat& img, double scale) {
  cv::Mat small, gray;
  cv::resize(img, small, {(int)std::lround(img.cols * scale), (int)std::lround(img.rows * scale)}, 0, 0, cv::INTER_AREA);
  if (small.channels() == 1) {
    gray = small;
  } else {
    cv::cvtColor(small, gray, cv::COLOR_BGR2GRAY);
  }
  return ink(gray);
}

}  // namespace

bool dewarp(const cv::Mat& src, cv::Mat& dst) {
  const int h = src.rows, w = src.cols;
  const double scale = std::min(1.0, static_cast<double>(kWorkWidth) / w);
  bool changed = false;
  cv::Mat out = src;

  // Pass 1: rows (text lines, horizontal rules)
  cv::Mat inkMask = analysisInk(out, scale);
  const int hs = inkMask.rows, ws = inkMask.cols;
  if (auto field = fitField(rowSamples(inkMask), ws, hs, 3, 3); field && maxCorrection(*field, ws, hs) >= kMinSlope) {
    cv::Mat ys, mapY, next;
    traceRows(*field, ws, hs).convertTo(ys, CV_32F, 1.0 / scale);  // (hs x kTraceCols)
    cv::resize(ys, mapY, {w, h}, 0, 0, cv::INTER_LINEAR);
    cv::Mat mapX(h, w, CV_32F);
    for (int y = 0; y < h; y++) {
      float* p = mapX.ptr<float>(y);
      for (int x = 0; x < w; x++) p[x] = (float)x;
    }
    cv::remap(out, next, mapX, mapY, cv::INTER_CUBIC, cv::BORDER_REPLICATE);
    out = next;
    changed = true;
  }

  // Pass 2: columns (vertical rules), on the row-corrected image
  inkMask = analysisInk(out, scale);
  const auto t = columnSamplesTransposed(inkMask);  // "rows" of the transposed page
  if (auto field = fitField(t, hs, ws, 2, 2); field && maxCorrection(*field, hs, ws) >= kMinSlope) {
    cv::Mat xs, xsT, mapX, next;
    traceRows(*field, hs, ws).convertTo(xs, CV_32F, 1.0 / scale);  // (ws x kTraceCols): source x per column
    cv::transpose(xs, xsT);
    cv::resize(xsT, mapX, {w, h}, 0, 0, cv::INTER_LINEAR);
    cv::Mat mapY(h, w, CV_32F);
    for (int y = 0; y < h; y++) mapY.row(y).setTo((float)y);
    cv::remap(out, next, mapX, mapY, cv::INTER_CUBIC, cv::BORDER_REPLICATE);
    out = next;
    changed = true;
  }

  dst = changed ? out : src;
  return changed;
}

}  // namespace ds
