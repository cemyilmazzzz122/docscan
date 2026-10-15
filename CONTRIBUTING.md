# Contributing to DocScan

Bug reports, scans that come out wrong, and pull requests are welcome.

## Reporting a problem

Open an issue with the *Bug report* or *Bad scan* template. For a bad scan, the original photo is
the most useful thing you can attach: the engine is deterministic, so the same photo reproduces the
same result. Remove anything private from the photo first, or describe the scene if you can't share
it.

Please don't open public issues for security problems; use
[private vulnerability reporting](https://github.com/cemyilmazzzz122/docscan/security/advisories/new) instead.

## Making changes

1. Fork the repository and create a branch from `main`.
2. Set up the platform you are working on as described in [docs/building.md](docs/building.md).
3. Keep each pull request to one change, and describe what it fixes and how you tested it.

Where to look:

| Area | Code | Docs |
| --- | --- | --- |
| Detection, perspective, straightening, filters | `engine/src/` | [engine.md](docs/engine.md), [c-api.md](docs/c-api.md) |
| Android app (Flutter) | `lib/` | [mobile-app.md](docs/mobile-app.md) |
| iOS app (SwiftUI) | `ios-native/` | [ios-native.md](docs/ios-native.md) |
| Linux app (PySide6) | `desktop/` | [desktop.md](docs/desktop.md) |

The engine is shared by every app, so a change there affects all platforms. The CLI is the
quickest way to try one on many photos:

```sh
cmake -S engine/src -B build/engine -DCMAKE_BUILD_TYPE=Release -DDOCSCAN_CLI=ON
cmake --build build/engine
./build/engine/docscan-cli -m color photo.jpg scan.jpg
```

For engine changes, include before and after results for a few photos in the pull request.

## Checks

CI builds the engine, the Android APKs and the iOS app on every pull request. Before pushing, run
what applies to your change:

```sh
flutter analyze                      # Flutter app
cmake --build build/engine           # engine
```

Pull requests from forks are built with the debug signing key; release signing only happens on
this repository.

## Style

Follow the style of the surrounding code. Keep comments for things the code can't say on its own.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
