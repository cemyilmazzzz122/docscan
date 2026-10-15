# DocScan

DocScan turns a photo of a document into a flat, clean scan. It finds the page, corrects the
perspective, straightens bent pages, removes shadows and uneven light, and exports images or PDFs.

It runs on Android (Flutter app on a C++ engine), iOS (native SwiftUI app with Liquid Glass on the
same engine) and Linux (Qt desktop app).

## Features

- Automatic page detection, with a corner editor and magnifier for manual adjustment
- Perspective correction that recovers the real paper proportions (A4, Letter and Legal are snapped)
- Straightening of curled or folded pages from their text lines and ruled lines
- Shadow and lighting removal
- Four output modes: Color, Gray, Black & white, Original
- Rotation, multi-page documents, PDF export, saving to the gallery, sharing
- Everything runs on the device; no network access

## Desktop app

The Linux app, built for KDE Plasma, takes photos by drag and drop, file picker or Ctrl+V, and adds
*Scan document* and *Scan document to PDF* to Dolphin's right-click menu.

## How it works

| Stage | Method |
| --- | --- |
| Page detection | text removed by morphological closing; edge, brightness and paper-color masks; best quadrilateral by area, fill and corner angles |
| Perspective | true aspect ratio from camera geometry (Zhang and He), snapped to standard paper sizes |
| Straightening | slope field fitted to text lines and rules, integrated per row, then remapped |
| Lighting | background estimated per channel and divided out, so the paper becomes uniformly white |
| Modes | levels and gamma, saturation, unsharp mask; denoising and Otsu threshold for black and white |

Details are in [docs/engine.md](docs/engine.md).

## Getting started

Download the latest APK or IPA from the releases page, or build it yourself:

```sh
scripts/fetch_opencv.sh        # prebuilt OpenCV for Android and iOS
flutter pub get
flutter build apk --release    # Android
```

Native iOS app (macOS, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

```sh
scripts/fetch_opencv.sh ios
xcodegen generate --spec ios-native/project.yml
open ios-native/DocScan.xcodeproj
```

Linux desktop app:

```sh
desktop/install.sh
```

Engine command line tool:

```sh
cmake -S engine/src -B build/engine -DCMAKE_BUILD_TYPE=Release -DDOCSCAN_CLI=ON
cmake --build build/engine
./build/engine/docscan-cli -m bw photo.jpg scan.jpg
```

See [docs/building.md](docs/building.md) for requirements and options.

## Project layout

```
engine/     C++ engine (OpenCV) with a C API, packaged as a Flutter FFI plugin
lib/        Flutter app
android/    Android host project
ios/        Flutter iOS host project (the released IPA is ios-native)
ios-native/ native iOS app (SwiftUI, iOS 26+, Liquid Glass)
desktop/    Linux desktop app (Python, PySide6)
scripts/    helper scripts
docs/       documentation
```

## Documentation

- [Architecture](docs/architecture.md)
- [Engine algorithms](docs/engine.md)
- [C API](docs/c-api.md)
- [Mobile app](docs/mobile-app.md)
- [Native iOS app](docs/ios-native.md)
- [Desktop app](docs/desktop.md)
- [Building and CI](docs/building.md)
