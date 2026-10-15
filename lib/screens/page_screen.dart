import 'package:docscan_engine/docscan_engine.dart';
import 'package:flutter/material.dart';

import '../models/scan_page.dart';
import '../services/export.dart';
import '../state/session.dart';
import '../widgets/page_thumb.dart';
import 'crop_screen.dart';

/// One page at a time: filter, crop, straighten, rotate. Swipe for the other pages.
class PageScreen extends StatefulWidget {
  const PageScreen({super.key, required this.session, required this.initialIndex});

  final ScanSession session;
  final int initialIndex;

  @override
  State<PageScreen> createState() => _PageScreenState();
}

class _PageScreenState extends State<PageScreen> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  ScanSession get session => widget.session;

  static const _modes = {
    ScanMode.color: 'Color',
    ScanMode.gray: 'Gray',
    ScanMode.blackWhite: 'B&W',
    ScanMode.original: 'Original',
  };

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _crop(ScanPage page) async {
    final corners = await Navigator.of(context).push<List<double>>(MaterialPageRoute(
      builder: (_) => CropScreen(page: page),
      fullscreenDialog: true,
    ));
    if (corners != null) session.setCorners(page, corners);
  }

  void _delete(ScanPage page) {
    session.remove(page);
    if (session.pages.isEmpty) {
      Navigator.of(context).pop();
    } else {
      setState(() => _index = _index.clamp(0, session.pages.length - 1));
    }
  }

  Future<void> _share(BuildContext ctx, ScanPage page) async {
    final box = ctx.findRenderObject() as RenderBox?;
    await Export.shareImages([page], origin: box == null ? null : box.localToGlobal(Offset.zero) & box.size);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final pages = session.pages;
        if (pages.isEmpty) return const Scaffold();
        final page = pages[_index.clamp(0, pages.length - 1)];
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(
            title: Text('Page ${_index + 1} of ${pages.length}'),
            actions: [
              IconButton(tooltip: 'Delete page', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(page)),
              Builder(
                builder: (ctx) => IconButton(
                  tooltip: 'Share',
                  icon: const Icon(Icons.ios_share),
                  onPressed: page.result == null ? null : () => _share(ctx, page),
                ),
              ),
            ],
          ),
          body: Column(children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: pages.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: InteractiveViewer(
                    maxScale: 5,
                    child: pages[i].error != null
                        ? _ErrorView(onRetry: () => session.retry(pages[i]))
                        : PageImage(page: pages[i]),
                  ),
                ),
              ),
            ),
            if (!page.documentFound && page.result != null && page.corners != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('No page edges found, using the whole photo. Tap Crop to adjust.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(children: [
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ScanMode>(
                    showSelectedIcon: false,
                    segments: [
                      for (final m in _modes.entries) ButtonSegment(value: m.key, label: Text(m.value)),
                    ],
                    selected: {page.mode},
                    onSelectionChanged: (s) => session.setMode(page, s.first),
                  ),
                ),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                  _Tool(icon: Icons.crop, label: 'Crop', onTap: () => _crop(page)),
                  _Tool(
                    icon: Icons.format_line_spacing,
                    label: 'Straighten',
                    selected: page.straighten,
                    onTap: () => session.setStraighten(page, !page.straighten),
                  ),
                  _Tool(icon: Icons.rotate_right, label: 'Rotate', onTap: () => session.rotate(page)),
                ]),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.label, required this.onTap, this.selected});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool? selected; // null: plain action, otherwise a toggle

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = selected ?? false;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: on ? scheme.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: on ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ]),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.error_outline, size: 40, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 12),
        const Text('This page could not be processed.'),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
      ]),
    );
  }
}
