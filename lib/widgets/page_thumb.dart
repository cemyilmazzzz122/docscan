import 'package:flutter/material.dart';

import '../models/scan_page.dart';

/// A page's result image, with a spinner while it is being processed.
class PageImage extends StatelessWidget {
  const PageImage({super.key, required this.page, this.fit = BoxFit.contain});

  final ScanPage page;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (page.error != null) {
      return Center(child: Icon(Icons.error_outline, color: scheme.error, size: 32));
    }
    final result = page.result;
    if (result == null) {
      return Stack(fit: StackFit.expand, children: [
        // Show the photo underneath while the scan is being made
        Opacity(opacity: 0.35, child: Image.memory(page.source, fit: fit, gaplessPlayback: true)),
        const Center(child: SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 3))),
      ]);
    }
    return Image.memory(result, fit: fit, gaplessPlayback: true, filterQuality: FilterQuality.medium);
  }
}

/// Grid tile for the page list.
class PageThumb extends StatelessWidget {
  const PageThumb({super.key, required this.page, required this.number, required this.onTap});

  final ScanPage page;
  final int number;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        child: Stack(fit: StackFit.expand, children: [
          Padding(padding: const EdgeInsets.all(8), child: PageImage(page: page)),
          Positioned(
            left: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: scheme.inverseSurface, borderRadius: BorderRadius.circular(10)),
              child: Text('$number', style: TextStyle(color: scheme.onInverseSurface, fontSize: 12)),
            ),
          ),
        ]),
      ),
    );
  }
}
