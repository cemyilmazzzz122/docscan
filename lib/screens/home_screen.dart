import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/export.dart';
import '../state/session.dart';
import '../widgets/page_thumb.dart';
import 'page_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.session});

  final ScanSession session;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _picker = ImagePicker();
  ScanSession get session => widget.session;

  Future<void> _add(ImageSource source) async {
    final List<XFile> files;
    try {
      if (source == ImageSource.camera) {
        final f = await _picker.pickImage(source: ImageSource.camera, requestFullMetadata: false);
        files = f == null ? [] : [f];
      } else {
        files = await _picker.pickMultiImage(requestFullMetadata: false);
      }
    } catch (e) {
      _toast('Could not open the ${source == ImageSource.camera ? 'camera' : 'gallery'}');
      return;
    }
    if (files.isEmpty) return;
    final bytes = [for (final f in files) await f.readAsBytes()];
    final failed = await session.addImages(bytes);
    if (failed > 0) _toast(failed == 1 ? 'One image could not be read' : '$failed images could not be read');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _export(Rect? origin) async {
    if (!session.allReady) {
      _toast('Pages are still being processed');
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text('Save as PDF'),
            onTap: () => Navigator.pop(context, 'save-pdf'),
          ),
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: const Text('Share PDF'),
            onTap: () => Navigator.pop(context, 'share-pdf'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Save images to gallery'),
            onTap: () => Navigator.pop(context, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('Share images'),
            onTap: () => Navigator.pop(context, 'share-images'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (choice == null) return;
    try {
      switch (choice) {
        case 'save-pdf':
          if (await Export.savePdf(session.pages)) _toast('PDF saved');
        case 'share-pdf':
          await Export.sharePdf(session.pages, origin: origin);
        case 'gallery':
          await Export.saveToGallery(session.pages);
          _toast(session.pages.length == 1 ? 'Saved to gallery' : '${session.pages.length} images saved to gallery');
        case 'share-images':
          await Export.shareImages(session.pages, origin: origin);
      }
    } catch (e) {
      _toast('Export failed: $e');
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove all pages?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) session.clear();
  }

  Rect? _originOf(BuildContext ctx) {
    final box = ctx.findRenderObject() as RenderBox?;
    return box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final pages = session.pages;
        return Scaffold(
          appBar: AppBar(
            title: const Text('DocScan'),
            actions: [
              if (pages.isNotEmpty) ...[
                IconButton(tooltip: 'Remove all', icon: const Icon(Icons.delete_sweep_outlined), onPressed: _clear),
                Builder(
                  builder: (ctx) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilledButton.tonalIcon(
                      onPressed: () => _export(_originOf(ctx)),
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: const Text('Export'),
                    ),
                  ),
                ),
              ],
            ],
          ),
          body: session.isEmpty ? _empty(context) : _grid(context),
          bottomNavigationBar: _bottomBar(context),
        );
      },
    );
  }

  Widget _empty(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.document_scanner_outlined, size: 72, color: scheme.primary),
          const SizedBox(height: 20),
          Text('Scan a document', style: t.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Take a photo or pick one from your gallery. Edges, perspective, bent pages '
            'and shadows are fixed automatically.',
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }

  Widget _grid(BuildContext context) {
    final pages = session.pages;
    final count = pages.length + session.importing;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        childAspectRatio: 0.72,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: count,
      itemBuilder: (context, i) {
        if (i >= pages.length) {
          return Card.filled(child: const Center(child: CircularProgressIndicator()));
        }
        return PageThumb(
          page: pages[i],
          number: i + 1,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PageScreen(session: session, initialIndex: i),
          )),
        );
      },
    );
  }

  Widget _bottomBar(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => _add(ImageSource.gallery),
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Gallery'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => _add(ImageSource.camera),
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('Camera'),
          ),
        ),
      ]),
    );
  }
}
