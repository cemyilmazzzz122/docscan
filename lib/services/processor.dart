import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:docscan_engine/docscan_engine.dart';

/// Runs the native engine on a background isolate so the UI never stalls.
abstract final class Processor {
  /// Longest side kept from the camera; plenty for a 300 dpi A4 page.
  static const maxSide = 4000;

  /// Turns any picked file into an upright JPEG the engine can work with.
  static Future<EncodedImage> normalize(Uint8List bytes) async {
    try {
      return await Isolate.run(() => DocScanEngine.normalize(bytes, maxSide: maxSide));
    } on EngineException {
      // Formats OpenCV can't read (e.g. HEIC): let the platform decode, hand over raw pixels.
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = image.width, h = image.height;
      image.dispose();
      codec.dispose();
      if (data == null) rethrow;
      final rgba = data.buffer.asUint8List();
      return Isolate.run(() => DocScanEngine.normalizeRgba(rgba, w, h, maxSide: maxSide));
    }
  }

  static Future<Detection> detect(Uint8List jpeg) => Isolate.run(() => DocScanEngine.detect(jpeg));

  static Future<EncodedImage> process(
    Uint8List jpeg, {
    required List<double> corners,
    required ScanMode mode,
    required bool straighten,
    required int quarterTurns,
  }) =>
      Isolate.run(() => DocScanEngine.process(
            jpeg,
            corners: corners,
            mode: mode,
            straighten: straighten,
            quarterTurns: quarterTurns,
          ));
}
