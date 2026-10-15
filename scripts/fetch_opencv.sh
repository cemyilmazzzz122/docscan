#!/usr/bin/env bash
# Downloads the prebuilt OpenCV packages the engine links against.
#
#   scripts/fetch_opencv.sh            # both
#   scripts/fetch_opencv.sh android    # engine/third_party/OpenCV-android-sdk
#   scripts/fetch_opencv.sh ios        # engine/ios/opencv2.framework
set -euo pipefail

VERSION="5.0.0"
BASE="https://github.com/opencv/opencv/releases/download/${VERSION}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch_android() {
  local dest="$ROOT/engine/third_party/OpenCV-android-sdk"
  if [[ -d "$dest" ]]; then echo "Android SDK already present: $dest"; return; fi
  echo "Downloading OpenCV ${VERSION} Android SDK..."
  curl -fL --retry 3 -o "$TMP/android.zip" "$BASE/opencv-${VERSION}-android-sdk-16kb-page-fix.zip"
  unzip -q "$TMP/android.zip" -d "$TMP/android"
  mkdir -p "$(dirname "$dest")"
  mv "$TMP/android/OpenCV-android-sdk" "$dest"
  # The Java bindings and samples are not needed (the native libs are referenced by OpenCVConfig.cmake)
  rm -rf "$dest/samples" "$dest/sdk/java"
}

fetch_ios() {
  local dest="$ROOT/engine/ios/opencv2.framework"
  if [[ -d "$dest" ]]; then echo "iOS framework already present: $dest"; return; fi
  echo "Downloading OpenCV ${VERSION} iOS framework..."
  curl -fL --retry 3 -o "$TMP/ios.zip" "$BASE/opencv-${VERSION}-ios-framework.zip"
  unzip -q "$TMP/ios.zip" -d "$TMP/ios"
  mv "$TMP/ios/opencv2.framework" "$dest"
}

case "${1:-all}" in
  android) fetch_android ;;
  ios) fetch_ios ;;
  all) fetch_android; fetch_ios ;;
  *) echo "usage: $0 [android|ios|all]" >&2; exit 2 ;;
esac
