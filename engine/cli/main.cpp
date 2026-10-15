// docscan-cli: runs the engine on image files from the command line.
//
//   docscan-cli [-m color|gray|bw|original] [--no-straighten] [--corners] input [output]
//
// Without an output path the result is written next to the input as <name>_scanned.jpg.
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "docscan.h"

namespace {

bool readFile(const std::string& path, std::vector<uint8_t>& out) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  out.assign(std::istreambuf_iterator<char>(f), {});
  return true;
}

bool writeFile(const std::string& path, const uint8_t* data, size_t size) {
  std::ofstream f(path, std::ios::binary);
  return f.write(reinterpret_cast<const char*>(data), (std::streamsize)size).good();
}

std::string defaultOutput(const std::string& in) {
  const size_t dot = in.find_last_of('.');
  const size_t slash = in.find_last_of('/');
  const std::string stem = (dot != std::string::npos && (slash == std::string::npos || dot > slash)) ? in.substr(0, dot) : in;
  return stem + "_scanned.jpg";
}

int usage() {
  std::fprintf(stderr, "usage: docscan-cli [-m color|gray|bw|original] [--no-straighten] [--corners] input [output]\n");
  return 2;
}

}  // namespace

int main(int argc, char** argv) {
  int mode = DS_MODE_COLOR;
  bool straighten = true, printCorners = false;
  std::vector<std::string> files;
  for (int i = 1; i < argc; i++) {
    const std::string a = argv[i];
    if ((a == "-m" || a == "--mode") && i + 1 < argc) {
      const std::string m = argv[++i];
      if (m == "color") mode = DS_MODE_COLOR;
      else if (m == "gray") mode = DS_MODE_GRAY;
      else if (m == "bw") mode = DS_MODE_BW;
      else if (m == "original") mode = DS_MODE_ORIGINAL;
      else return usage();
    } else if (a == "--no-straighten") {
      straighten = false;
    } else if (a == "--corners") {
      printCorners = true;
    } else if (!a.empty() && a[0] == '-') {
      return usage();
    } else {
      files.push_back(a);
    }
  }
  if (files.empty() || files.size() > 2) return usage();

  std::vector<uint8_t> input;
  if (!readFile(files[0], input)) {
    std::fprintf(stderr, "cannot read %s\n", files[0].c_str());
    return 1;
  }
  float corners[8];
  const int found = ds_detect(input.data(), (int32_t)input.size(), corners);
  if (found < 0) {
    std::fprintf(stderr, "error: %s\n", ds_last_error());
    return 1;
  }
  if (printCorners) {
    std::printf("%s:", found ? "document" : "no document, full frame");
    for (int i = 0; i < 4; i++) std::printf(" (%.1f, %.1f)", corners[2 * i], corners[2 * i + 1]);
    std::printf("\n");
  }

  ds_image out{};
  if (ds_process(input.data(), (int32_t)input.size(), corners, mode, straighten, 0, 92, &out) != 0) {
    std::fprintf(stderr, "error: %s\n", ds_last_error());
    return 1;
  }
  const std::string outPath = files.size() > 1 ? files[1] : defaultOutput(files[0]);
  const bool ok = writeFile(outPath, out.data, (size_t)out.size);
  std::printf("%s -> %s (%dx%d)\n", files[0].c_str(), outPath.c_str(), out.width, out.height);
  ds_free(&out);
  return ok ? 0 : 1;
}
