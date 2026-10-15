// Page dewarping: straightens bent or curled pages using text lines and ruled lines.
#pragma once

#include <opencv2/core.hpp>

namespace ds {

// Straightens bent text lines and rules. Returns true if the image was changed.
bool dewarp(const cv::Mat& src, cv::Mat& dst);

}  // namespace ds
