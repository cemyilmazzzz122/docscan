# Mobile app

The Flutter app (`lib/`) is a thin interface over the engine. It has three screens and one piece of
shared state.

## Screens

**Home** (`screens/home_screen.dart`). The list of pages in a grid, with *Gallery* and *Camera*
buttons at the bottom. The gallery picker accepts several photos at once. *Export* opens a sheet:

- Save as PDF: one A4 page per scan (portrait or landscape to match), saved where the user chooses.
- Share PDF: the same PDF through the system share sheet.
- Save images to gallery: JPEGs in a "DocScan" album.
- Share images.

**Page** (`screens/page_screen.dart`). One page at a time, swipe for the others, pinch to zoom.

- Mode: Color, Gray, B&W, Original.
- Crop: opens the crop editor.
- Straighten: toggles the bent-page correction for this page.
- Rotate: 90 degrees clockwise.
- Share and delete in the app bar.

**Crop** (`screens/crop_screen.dart`). The original photo with the four corners. Drag a corner to
move it; a magnifier above the finger shows the exact edge. *Auto detect* restores the detected
corners and *Whole photo* selects the full frame.

## State

`ScanSession` (`state/session.dart`) is a `ChangeNotifier` that owns the list of `ScanPage`s. Screens
listen to it with `ListenableBuilder`; there is no state management package.

A `ScanPage` (`models/scan_page.dart`) holds:

| Field | Meaning |
| --- | --- |
| `source` | the normalized, upright JPEG of the photo |
| `corners`, `detectedCorners` | current and automatically detected corners |
| `mode`, `straighten`, `quarterTurns` | user settings |
| `result` | the processed JPEG, null while processing |
| `revision` | increases on every change; late results from old revisions are dropped |

The life of a page:

```
addImages ─► normalize ─► page added (spinner over the photo)
                │
                └─► detect ─► process ─► result shown
                                 ▲
         setMode / setStraighten / rotate / setCorners
```

## Processing

`services/processor.dart` runs every engine call in `Isolate.run`, so the UI stays at full frame rate
while a page is processed. Pages added together are processed concurrently.

If OpenCV cannot decode a file (for example HEIC photos on iOS), `Processor.normalize` decodes it with
the platform image codec and passes the raw pixels to `ds_normalize_rgba`.

## Export

`services/export.dart` builds PDFs with the `pdf` package, saves files through `file_picker`
(Storage Access Framework on Android, the Files app on iOS), writes to the gallery with `gal`, and
shares with `share_plus`. Files for the share sheet are written to a temporary folder that is
cleared before each share.

## Permissions

| Platform | Permission | Why |
| --- | --- | --- |
| iOS | `NSCameraUsageDescription` | taking photos |
| iOS | `NSPhotoLibraryUsageDescription` | picking photos |
| iOS | `NSPhotoLibraryAddUsageDescription` | saving scans |
| Android | `WRITE_EXTERNAL_STORAGE` (Android 9 and older only) | saving scans to the gallery |

On Android the system photo picker and camera app are used, so no runtime permission is needed on
current versions.
