# Native iOS app

`ios-native/` is a SwiftUI app for iOS 26 and later, styled with Liquid Glass. It has the same
features as the Flutter app and calls the same C++ engine; the engine sources in `engine/src` are
compiled straight into the app and linked against `engine/ios/opencv2.framework`.

```
ios-native/
├── project.yml                  XcodeGen spec (the .xcodeproj is generated, not checked in)
└── DocScan/
    ├── App/                     entry point, bridging header for docscan.h
    ├── Engine/Engine.swift      Swift wrapper around the C API
    ├── Model/                   ScanPage, ScanSession
    ├── Services/Exporter.swift  PDF, Photos, share sheet files
    ├── Views/                   home, page editor, crop editor, shared components
    └── Assets.xcassets
```

## Screens

| Screen | File | Glass elements |
| --- | --- | --- |
| Home | `HomeView.swift` | *Library* and *Camera* buttons in a `GlassEffectContainer`, page number badges, toolbar with *Remove All* and the *Export* menu |
| Page | `PageEditorView.swift` | a glass panel with the mode picker and the Crop, Straighten and Rotate buttons (Straighten turns prominent when on) |
| Crop | `CropView.swift` | glass loupe over the dragged corner, *Auto Detect* and *Whole Photo* buttons |

Long-press a page on the home screen to move, share or delete it. In the page view, pinch or
double-tap to zoom.

## State and processing

`ScanSession` is a main-actor `@Observable` class that owns the `ScanPage`s, and works like the
Flutter `ScanSession`. Every engine call runs in `Task.detached`, so the interface stays responsive.
Each settings change increases the page's `revision`, and results from older revisions are dropped.
While a new version of a page is being made, the old result stays on screen with a spinner over it.

Engine failures appear as `EngineError` with the engine's message. If OpenCV cannot decode a file
(HEIC, for example), `Engine.normalize` decodes it with ImageIO (EXIF orientation applied, size
capped at 4000 px) and passes the pixels to `ds_normalize_rgba`.

## Export

- **Save as PDF**: `fileExporter`, one A4 page per scan. The page is landscape when the scan is
  wider than tall. The JPEGs are embedded without recompression.
- **Share PDF / Share Images**: files are written to a temporary `share` folder, which is cleared
  before each share, and passed to `UIActivityViewController`.
- **Save Images to Photos**: saves to a "DocScan" album with full access, and without an album with
  limited or add-only access.
