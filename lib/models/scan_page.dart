import 'dart:typed_data';

import 'package:docscan_engine/docscan_engine.dart';

/// One scanned page: the original photo plus the settings that turn it into the result.
class ScanPage {
  ScanPage({required this.id, required this.source, required this.width, required this.height});

  final int id;

  /// The photo, normalized to an upright JPEG (EXIF rotation applied).
  final Uint8List source;
  final int width, height;

  /// Document corners in [source] pixels: TL, TR, BR, BL as x,y pairs. Null until detected.
  List<double>? corners;

  /// What automatic detection found (the full frame if [documentFound] is false).
  List<double>? detectedCorners;
  bool documentFound = false;

  ScanMode mode = ScanMode.color;
  bool straighten = true;
  int quarterTurns = 0;

  /// The processed page (JPEG), null while it's being made.
  Uint8List? result;
  int resultWidth = 0, resultHeight = 0;
  String? error;

  /// Bumped on every settings change so stale results can be dropped.
  int revision = 0;
  bool get busy => result == null && error == null;
}
