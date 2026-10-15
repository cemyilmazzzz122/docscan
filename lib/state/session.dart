import 'package:docscan_engine/docscan_engine.dart';
import 'package:flutter/foundation.dart';

import '../models/scan_page.dart';
import '../services/processor.dart';

/// The pages being scanned, in document order.
class ScanSession extends ChangeNotifier {
  final List<ScanPage> pages = [];
  int _nextId = 0;
  int _importing = 0;

  /// Number of files still being read.
  int get importing => _importing;
  bool get isEmpty => pages.isEmpty && _importing == 0;
  bool get allReady => pages.isNotEmpty && pages.every((p) => p.result != null);

  /// Adds photos as new pages. Returns how many could not be read.
  Future<int> addImages(List<Uint8List> files) async {
    _importing += files.length;
    notifyListeners();
    var failed = 0;
    for (final bytes in files) {
      try {
        final img = await Processor.normalize(bytes);
        final page = ScanPage(id: _nextId++, source: img.bytes, width: img.width, height: img.height);
        pages.add(page);
        notifyListeners();
        _detectAndProcess(page);
      } catch (_) {
        failed++;
      } finally {
        _importing--;
        notifyListeners();
      }
    }
    return failed;
  }

  Future<void> _detectAndProcess(ScanPage page) async {
    try {
      final d = await Processor.detect(page.source);
      page.corners = d.corners;
      page.detectedCorners = d.corners;
      page.documentFound = d.found;
    } catch (e) {
      page.corners = fullFrame(page);
    }
    await _process(page);
  }

  Future<void> _process(ScanPage page) async {
    final rev = ++page.revision;
    page.result = null;
    page.error = null;
    notifyListeners();
    try {
      final out = await Processor.process(
        page.source,
        corners: page.corners ?? fullFrame(page),
        mode: page.mode,
        straighten: page.straighten,
        quarterTurns: page.quarterTurns,
      );
      if (rev != page.revision || !pages.contains(page)) return;
      page.result = out.bytes;
      page.resultWidth = out.width;
      page.resultHeight = out.height;
    } catch (e) {
      if (rev != page.revision) return;
      page.error = e.toString();
    }
    notifyListeners();
  }

  static List<double> fullFrame(ScanPage p) {
    final w = p.width - 1.0, h = p.height - 1.0;
    return [0, 0, w, 0, w, h, 0, h];
  }

  void setMode(ScanPage page, ScanMode mode) {
    if (page.mode == mode) return;
    page.mode = mode;
    _process(page);
  }

  void setStraighten(ScanPage page, bool on) {
    page.straighten = on;
    _process(page);
  }

  void rotate(ScanPage page) {
    page.quarterTurns = (page.quarterTurns + 1) % 4;
    _process(page);
  }

  void setCorners(ScanPage page, List<double> corners) {
    page.corners = corners;
    _process(page);
  }

  void retry(ScanPage page) => _process(page);

  void remove(ScanPage page) {
    pages.remove(page);
    notifyListeners();
  }

  void move(int from, int to) {
    final p = pages.removeAt(from);
    pages.insert(to, p);
    notifyListeners();
  }

  void clear() {
    pages.clear();
    notifyListeners();
  }
}
