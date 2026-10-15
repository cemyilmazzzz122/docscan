import 'package:flutter/material.dart';

import '../models/scan_page.dart';
import '../state/session.dart';

/// Drag the four corners onto the page edges. Pops with the new corners, or null if cancelled.
class CropScreen extends StatefulWidget {
  const CropScreen({super.key, required this.page});

  final ScanPage page;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  late List<Offset> _pts = _fromList(widget.page.corners ?? ScanSession.fullFrame(widget.page));
  int? _dragging;
  Offset _dragPos = Offset.zero;

  static List<Offset> _fromList(List<double> c) => [for (var i = 0; i < 4; i++) Offset(c[2 * i], c[2 * i + 1])];
  static List<double> _toList(List<Offset> p) => [for (final o in p) ...[o.dx, o.dy]];

  void _set(List<double> c) => setState(() => _pts = _fromList(c));

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Crop'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: () => Navigator.pop(context, _toList(_pts)),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: LayoutBuilder(builder: (context, box) {
              // Fit the photo into the available space
              final s = (box.maxWidth / page.width).clamp(0.0, box.maxHeight / page.height);
              final size = Size(page.width * s, page.height * s);
              final origin = Offset((box.maxWidth - size.width) / 2, (box.maxHeight - size.height) / 2);
              Offset toView(Offset p) => origin + p * s;
              Offset toImage(Offset v) {
                final p = (v - origin) / s;
                return Offset(p.dx.clamp(0, page.width - 1.0), p.dy.clamp(0, page.height - 1.0));
              }

              final view = [for (final p in _pts) toView(p)];
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) {
                  // Grab the nearest corner within reach
                  var best = -1;
                  var bestDist = 48.0;
                  for (var i = 0; i < 4; i++) {
                    final dist = (view[i] - d.localPosition).distance;
                    if (dist < bestDist) {
                      best = i;
                      bestDist = dist;
                    }
                  }
                  if (best >= 0) {
                    setState(() {
                      _dragging = best;
                      _dragPos = view[best];
                    });
                  }
                },
                onPanUpdate: (d) {
                  final i = _dragging;
                  if (i == null) return;
                  setState(() {
                    _dragPos = toView(toImage(_dragPos + d.delta));
                    _pts = [..._pts]..[i] = toImage(_dragPos);
                  });
                },
                onPanEnd: (_) => setState(() => _dragging = null),
                onPanCancel: () => setState(() => _dragging = null),
                child: Stack(clipBehavior: Clip.none, children: [
                  Positioned.fromRect(
                    rect: origin & size,
                    child: Image.memory(page.source, fit: BoxFit.fill, gaplessPlayback: true),
                  ),
                  Positioned.fill(child: CustomPaint(painter: _QuadPainter(view, scheme.primary, _dragging))),
                  if (_dragging != null)
                    Positioned(
                      left: _dragPos.dx - 50,
                      top: _dragPos.dy - 150,
                      child: RawMagnifier(
                        size: const Size(100, 100),
                        magnificationScale: 2.5,
                        focalPointOffset: const Offset(0, 100),
                        decoration: MagnifierDecoration(
                          shape: CircleBorder(side: BorderSide(color: scheme.primary, width: 2)),
                        ),
                        child: Center(child: Icon(Icons.add, color: scheme.primary, size: 20)),
                      ),
                    ),
                ]),
              );
            }),
          ),
        ),
        SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: page.detectedCorners == null ? null : () => _set(page.detectedCorners!),
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('Auto detect'),
            ),
            const SizedBox(width: 16),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () => _set(ScanSession.fullFrame(page)),
              icon: const Icon(Icons.fullscreen),
              label: const Text('Whole photo'),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _QuadPainter extends CustomPainter {
  _QuadPainter(this.pts, this.color, this.active);

  final List<Offset> pts;
  final Color color;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    final quad = Path()..addPolygon(pts, true);
    // Dim everything outside the page
    final outside = Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), quad);
    canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.45));
    canvas.drawPath(
      quad,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (var i = 0; i < pts.length; i++) {
      // The dragged corner is left out so the magnifier shows the edge underneath
      if (i == active) continue;
      canvas.drawCircle(pts[i], 11, Paint()..color = Colors.white);
      canvas.drawCircle(
        pts[i],
        11,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
  }

  @override
  bool shouldRepaint(_QuadPainter old) => old.pts != pts || old.active != active || old.color != color;
}
