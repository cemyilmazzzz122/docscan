# Architecture

DocScan turns a photo of a document into a flat, clean, print-like scan. The project has three parts
that share one image processing design:

| Part | Path | Language | Runs on |
| --- | --- | --- | --- |
| Engine | `engine/src` | C++17, OpenCV | Android, iOS, Linux (CLI) |
| Mobile app | `lib/`, `android/`, `ios/` | Dart, Flutter | Android, iOS |
| Desktop app | `desktop/` | Python, PySide6, OpenCV | Linux (KDE Plasma) |

## Repository layout

```
.
├── engine/                     C++ engine, packaged as a Flutter FFI plugin
│   ├── src/
│   │   ├── docscan.h           C API (the only public interface)
│   │   ├── api.cpp             C API implementation: decoding, encoding, error handling
│   │   ├── scanner.hpp/.cpp    detection, perspective correction, filters
│   │   ├── dewarp.hpp/.cpp     straightening of bent pages
│   │   └── CMakeLists.txt      used by Gradle (Android) and for desktop builds
│   ├── cli/main.cpp            docscan-cli, a command line front end for testing
│   ├── lib/docscan_engine.dart Dart FFI bindings
│   ├── android/build.gradle    builds src/ with the NDK
│   └── ios/                    podspec + forwarders that compile src/ with CocoaPods
├── lib/                        Flutter app
│   ├── main.dart               app entry, theme
│   ├── models/scan_page.dart   one page: source photo, settings, result
│   ├── state/session.dart      page list and processing orchestration
│   ├── services/processor.dart runs the engine on background isolates
│   ├── services/export.dart    PDF, gallery, share sheet
│   ├── screens/                home, page editor, crop editor
│   └── widgets/                shared widgets
├── desktop/                    Linux desktop app (Python reference implementation)
├── scripts/fetch_opencv.sh     downloads prebuilt OpenCV for Android and iOS
├── docs/                       this documentation
└── .github/workflows/build.yml CI: engine test, APK and IPA builds, releases
```

## Layers

```
 ┌──────────────────────────────────────────────┐
 │ Flutter UI (screens, widgets)                │  lib/screens, lib/widgets
 ├──────────────────────────────────────────────┤
 │ ScanSession (ChangeNotifier)                 │  lib/state
 │   page list, settings, revision tracking     │
 ├──────────────────────────────────────────────┤
 │ Processor / Export services                  │  lib/services
 │   Isolate.run(...) around every engine call  │
 ├──────────────────────────────────────────────┤
 │ docscan_engine Dart bindings (dart:ffi)      │  engine/lib
 ├──────────────────────────────────────────────┤
 │ C API  ds_normalize / ds_detect / ds_process │  engine/src/docscan.h
 ├──────────────────────────────────────────────┤
 │ C++ pipeline  ds::detectDocument, ds::warp,  │  engine/src
 │               ds::dewarp, ds::applyMode      │
 ├──────────────────────────────────────────────┤
 │ OpenCV 5 (core, imgproc, geometry,           │  static libraries
 │           imgcodecs, photo)                  │
 └──────────────────────────────────────────────┘
```

Each layer only talks to the one below it. The UI never touches pixels and the engine knows nothing
about Flutter.

## Design decisions

**C API at the boundary.** The engine exposes plain C functions that take and return encoded image
bytes (JPEG/PNG). This keeps the FFI surface tiny: no C++ types, no callbacks, no shared native
objects whose lifetime Dart would have to manage. The only native allocation that crosses the
boundary is the output buffer, which is always released with `ds_free`.

**Stateless engine.** Every call decodes its input and returns a new image. The app keeps the
normalized source JPEG of each page and re-runs the whole pipeline when a setting changes. This
costs a decode per change but makes every call independent, so calls can run in parallel on any
isolate with no locking.

**Background isolates.** Engine calls are synchronous and CPU heavy, so `Processor` wraps each one in
`Isolate.run`. Each isolate opens the native library on its own; the engine has no global state
except a thread-local error message.

**Normalization on import.** Photos are decoded once (applying EXIF orientation), capped at 4000 px on
the long side and re-encoded as JPEG. After that, the image the user sees, the corner coordinates and
the image the engine processes are all in the same upright pixel space. Formats OpenCV cannot read
(HEIC on iOS, for example) are decoded by the platform and handed over as raw RGBA through
`ds_normalize_rgba`.

**Revisioned results.** Changing a setting bumps `ScanPage.revision` and starts a new job. When a job
finishes, its result is dropped if the revision has moved on, so fast taps never show stale output.

**Static OpenCV.** OpenCV is linked statically into `libdocscan_engine` (Android) or the plugin
framework (iOS), with unused sections removed. Only the modules the engine needs are linked.

## Data flow

```
pick photo ─► ds_normalize ─► ScanPage.source (upright JPEG)
                                   │
                                   ├─► ds_detect ─► ScanPage.corners
                                   │                    ▲
                                   │        crop editor ┘ (user adjusts)
                                   ▼
             ds_process(source, corners, mode, straighten, quarterTurns)
                                   │
                                   ▼
                          ScanPage.result (JPEG)
                                   │
                ┌──────────────────┼────────────────────┐
                ▼                  ▼                    ▼
           PDF (A4 pages)    gallery album        share sheet
```

## The desktop app

`desktop/` holds the Linux app that the engine was first prototyped in. It implements the same
pipeline in Python with OpenCV and is kept as the reference: the C++ engine is checked against it
(see [engine.md](engine.md#verification)). It adds desktop features such as drag and drop,
pasting with Ctrl+V and a Dolphin context menu.
