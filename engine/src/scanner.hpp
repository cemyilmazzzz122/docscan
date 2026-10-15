// Document scanning pipeline:
//   1. find the document corners
//   2. correct the perspective
//   3. straighten bent/curled pages from their text lines (see dewarp.hpp)
//   4. apply a filter (color / gray / black & white / original)
#pragma once

#include <array>
#include <optional>

#include <opencv2/core.hpp>

namespace ds {

using Quad = std::array<cv::Point2f, 4>;  // top-left, top-right, bottom-right, bottom-left

enum class Mode { Color = 0, Gray = 1, BlackWhite = 2, Original = 3 };

Quad orderCorners(const std::vector<cv::Point2f>& pts);

// The document's corners in image coordinates, or nothing if no clear page was found.
std::optional<Quad> detectDocument(const cv::Mat& img);

Quad fullFrame(const cv::Mat& img);

// Perspective-corrects the quad into a flat page with its true aspect ratio.
cv::Mat warp(const cv::Mat& img, const Quad& corners, double inset = 0.006);

cv::Mat applyMode(const cv::Mat& img, Mode mode);

// The whole pipeline.
cv::Mat scan(const cv::Mat& img, Mode mode, const std::optional<Quad>& corners, bool straighten);

}  // namespace ds
