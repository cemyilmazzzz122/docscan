# Building

## Requirements

| Target | Needs |
| --- | --- |
| Android APK | Flutter 3.47+, JDK 17 or 21, Android SDK (the NDK and CMake are installed by Gradle) |
| iOS app (native) | macOS, Xcode 26+, XcodeGen |
| iOS app (Flutter) | macOS, Xcode 16+, CocoaPods, Flutter 3.47+ |
| Engine CLI | CMake 3.10+, a C++17 compiler, OpenCV 4.9+ or 5.x development files |
| Desktop app | Python 3.10+, PySide6, OpenCV for Python |

OpenCV for Android and iOS is not stored in the repository. Download the prebuilt packages once:

```sh
scripts/fetch_opencv.sh          # both
scripts/fetch_opencv.sh android  # -> engine/third_party/OpenCV-android-sdk
scripts/fetch_opencv.sh ios      # -> engine/ios/opencv2.framework
```

## Android

```sh
scripts/fetch_opencv.sh android
flutter pub get
flutter build apk --release                  # one APK for all devices
flutter build apk --release --split-per-abi  # smaller APK per CPU type
```

The APKs land in `build/app/outputs/flutter-apk/`. Most phones need `app-arm64-v8a-release.apk`.

### Signing

Release builds are signed with the release key when one is configured, and with the debug key
otherwise (so forks and pull requests still build). The key is read from `android/key.properties`
(ignored by git):

```properties
storeFile=/absolute/path/to/release.jks
storePassword=...
keyAlias=...
keyPassword=...
```

or from the `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and
`ANDROID_KEY_PASSWORD` environment variables. CI decodes the keystore from the
`ANDROID_KEYSTORE_BASE64` secret and passes the rest from secrets of the same names.

APKs signed with different keys cannot update each other, so keep the release keystore and its
password backed up: losing it means users have to uninstall before installing a new version.

## iOS (native)

The IPA that CI publishes is the SwiftUI app in `ios-native/`. Its Xcode project is generated from
`ios-native/project.yml` and is not checked in.

```sh
scripts/fetch_opencv.sh ios
brew install xcodegen
xcodegen generate --spec ios-native/project.yml
open ios-native/DocScan.xcodeproj       # pick a team under Signing & Capabilities, then run

# unsigned device build, as CI does it
xcodebuild -project ios-native/DocScan.xcodeproj -scheme DocScan -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

It needs iOS 26 or later. The prebuilt OpenCV framework has no arm64 simulator slice, so on Apple
silicon Macs test on a device (the iOS 26 simulator no longer runs x86_64 apps).

## iOS (Flutter)

```sh
scripts/fetch_opencv.sh ios
flutter pub get
flutter build ios --release            # signed, needs a development team set in Xcode
flutter build ios --release --no-codesign
```

To install on a device, open `ios/Runner.xcworkspace` in Xcode, choose a team under *Signing &
Capabilities*, and run. The unsigned IPA from CI can be signed with a tool such as AltStore or
Sideloadly.

The prebuilt OpenCV framework contains device (arm64) and Intel simulator (x86_64) slices, so the
app runs on real devices and on the simulator of Intel Macs. On Apple silicon Macs, run the
simulator under Rosetta or test on a device.

## Engine CLI (Linux)

```sh
# Arch / CachyOS: sudo pacman -S opencv   Debian / Ubuntu: sudo apt install libopencv-dev
cmake -S engine/src -B build/engine -DCMAKE_BUILD_TYPE=Release -DDOCSCAN_CLI=ON
cmake --build build/engine
./build/engine/docscan-cli --corners photo.jpg
```

Options:

```
docscan-cli [-m color|gray|bw|original] [--no-straighten] [--corners] input [output]
```

Without an output path the scan is written next to the input as `<name>_scanned.jpg`. If OpenCV is
not installed system-wide, pass `-DOpenCV_DIR=<prefix>/lib/cmake/opencv5`.

## Desktop app (Linux)

```sh
desktop/install.sh           # installs the docscan command, menu entry and Dolphin actions
desktop/install.sh --remove  # uninstalls
```

See [desktop.md](desktop.md).

## Continuous integration

`.github/workflows/build.yml` runs on every push to `main`, on pull requests and on demand:

| Job | Runner | Output |
| --- | --- | --- |
| C++ engine | ubuntu-latest | builds the engine and CLI against the system OpenCV, runs a smoke test |
| Android APK | ubuntu-latest | `android-apk` artifact: universal, arm64-v8a, armeabi-v7a and x86_64 APKs, signed with the release key |
| iOS IPA | macos-26 | `ios-ipa` artifact: `DocScan-unsigned.ipa`, built from `ios-native/` with the latest stable Xcode |
| Release | ubuntu-latest | on `v*` tags, a GitHub release with all APKs and the IPA |

To publish a release:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The OpenCV downloads are cached between runs.
