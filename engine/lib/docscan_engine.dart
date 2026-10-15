/// Dart bindings for DocScan's C++ engine (see src/docscan.h).
///
/// All calls are synchronous and CPU heavy: run them off the UI thread, e.g. with `Isolate.run`.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Output filter.
enum ScanMode { color, gray, blackWhite, original }

/// A JPEG produced by the engine.
class EncodedImage {
  final Uint8List bytes;
  final int width, height;
  const EncodedImage(this.bytes, this.width, this.height);
}

/// Result of document detection: 8 values (x, y) for top-left, top-right, bottom-right, bottom-left.
class Detection {
  final List<double> corners;
  final bool found;
  const Detection(this.corners, this.found);
}

class EngineException implements Exception {
  final String message;
  const EngineException(this.message);
  @override
  String toString() => 'EngineException: $message';
}

final class _DsImage extends Struct {
  external Pointer<Uint8> data;
  @Int32()
  external int size;
  @Int32()
  external int width;
  @Int32()
  external int height;
}

typedef _NormalizeC = Int32 Function(Pointer<Uint8>, Int32, Int32, Pointer<_DsImage>);
typedef _Normalize = int Function(Pointer<Uint8>, int, int, Pointer<_DsImage>);
typedef _NormalizeRgbaC = Int32 Function(Pointer<Uint8>, Int32, Int32, Int32, Pointer<_DsImage>);
typedef _NormalizeRgba = int Function(Pointer<Uint8>, int, int, int, Pointer<_DsImage>);
typedef _DetectC = Int32 Function(Pointer<Uint8>, Int32, Pointer<Float>);
typedef _Detect = int Function(Pointer<Uint8>, int, Pointer<Float>);
typedef _ProcessC = Int32 Function(Pointer<Uint8>, Int32, Pointer<Float>, Int32, Int32, Int32, Int32, Pointer<_DsImage>);
typedef _Process = int Function(Pointer<Uint8>, int, Pointer<Float>, int, int, int, int, Pointer<_DsImage>);
typedef _FreeC = Void Function(Pointer<_DsImage>);
typedef _Free = void Function(Pointer<_DsImage>);
typedef _StrC = Pointer<Utf8> Function();

const _libName = 'docscan_engine';

final DynamicLibrary _lib = () {
  if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.open('$_libName.framework/$_libName');
  if (Platform.isAndroid || Platform.isLinux) return DynamicLibrary.open('lib$_libName.so');
  if (Platform.isWindows) return DynamicLibrary.open('$_libName.dll');
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}();

final _normalize = _lib.lookupFunction<_NormalizeC, _Normalize>('ds_normalize');
final _normalizeRgba = _lib.lookupFunction<_NormalizeRgbaC, _NormalizeRgba>('ds_normalize_rgba');
final _detect = _lib.lookupFunction<_DetectC, _Detect>('ds_detect');
final _process = _lib.lookupFunction<_ProcessC, _Process>('ds_process');
final _free = _lib.lookupFunction<_FreeC, _Free>('ds_free');
final _lastError = _lib.lookupFunction<_StrC, _StrC>('ds_last_error');
final _version = _lib.lookupFunction<_StrC, _StrC>('ds_version');

/// The native scanning engine.
abstract final class DocScanEngine {
  static String get version => _version().toDartString();

  /// Decodes an image (applying EXIF rotation), caps its long side at [maxSide] and re-encodes it as JPEG.
  static EncodedImage normalize(Uint8List bytes, {int maxSide = 4000}) =>
      _withInput(bytes, (data) => _takeImage((out) => _normalize(data, bytes.length, maxSide, out)));

  /// Same as [normalize], from raw RGBA pixels (for formats only the platform can decode, e.g. HEIC).
  static EncodedImage normalizeRgba(Uint8List rgba, int width, int height, {int maxSide = 4000}) =>
      _withInput(rgba, (data) => _takeImage((out) => _normalizeRgba(data, width, height, maxSide, out)));

  /// Finds the document in a JPEG/PNG. Falls back to the full frame when no page is found.
  static Detection detect(Uint8List bytes) => _withInput(bytes, (data) {
        final corners = calloc<Float>(8);
        try {
          final r = _detect(data, bytes.length, corners);
          if (r < 0) throw EngineException(_lastError().toDartString());
          return Detection([for (var i = 0; i < 8; i++) corners[i]], r == 1);
        } finally {
          calloc.free(corners);
        }
      });

  /// Runs the full scan. [corners] are 8 values as returned by [detect]; null detects automatically.
  static EncodedImage process(
    Uint8List bytes, {
    List<double>? corners,
    ScanMode mode = ScanMode.color,
    bool straighten = true,
    int quarterTurns = 0,
    int jpegQuality = 92,
  }) =>
      _withInput(bytes, (data) {
        Pointer<Float> c = nullptr;
        if (corners != null) {
          assert(corners.length == 8);
          c = calloc<Float>(8);
          for (var i = 0; i < 8; i++) {
            c[i] = corners[i];
          }
        }
        try {
          return _takeImage((out) => _process(
              data, bytes.length, c, mode.index, straighten ? 1 : 0, quarterTurns, jpegQuality, out));
        } finally {
          if (c != nullptr) calloc.free(c);
        }
      });

  static T _withInput<T>(Uint8List bytes, T Function(Pointer<Uint8> data) body) {
    final data = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      return body(data);
    } finally {
      malloc.free(data);
    }
  }

  static EncodedImage _takeImage(int Function(Pointer<_DsImage> out) call) {
    final out = calloc<_DsImage>();
    try {
      if (call(out) != 0) throw EngineException(_lastError().toDartString());
      final img = out.ref;
      return EncodedImage(Uint8List.fromList(img.data.asTypedList(img.size)), img.width, img.height);
    } finally {
      _free(out);
      calloc.free(out);
    }
  }
}
