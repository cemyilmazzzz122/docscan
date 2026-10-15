import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/scan_page.dart';

/// Saving and sharing scans.
abstract final class Export {
  static String baseName() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Scan ${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}.${two(n.minute)}.${two(n.second)}';
  }

  /// One A4 page per scan, portrait or landscape to match the image.
  static Future<Uint8List> buildPdf(List<ScanPage> pages) async {
    final doc = pw.Document(title: 'Scanned document', creator: 'DocScan');
    for (final p in pages) {
      final bytes = p.result;
      if (bytes == null) continue;
      final landscape = p.resultWidth > p.resultHeight;
      doc.addPage(pw.Page(
        pageFormat: landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Center(child: pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain)),
      ));
    }
    return doc.save();
  }

  /// Lets the user pick where to save the PDF. Returns false if cancelled.
  static Future<bool> savePdf(List<ScanPage> pages) async {
    final bytes = await buildPdf(pages);
    final uri = await FilePicker.saveFile(
      fileName: '${baseName()}.pdf',
      bytes: bytes,
      mimeType: 'application/pdf',
      dialogTitle: 'Save PDF',
    );
    return uri != null;
  }

  static Future<void> sharePdf(List<ScanPage> pages, {Rect? origin}) async {
    final dir = await _shareDir();
    final file = await File('${dir.path}/${baseName()}.pdf').writeAsBytes(await buildPdf(pages), flush: true);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'application/pdf')],
      sharePositionOrigin: origin,
    ));
  }

  static Future<void> shareImages(List<ScanPage> pages, {Rect? origin}) async {
    final base = baseName();
    final dir = await _shareDir();
    final files = <XFile>[];
    for (var i = 0; i < pages.length; i++) {
      final bytes = pages[i].result;
      if (bytes == null) continue;
      final suffix = pages.length > 1 ? ' (${i + 1})' : '';
      final f = await File('${dir.path}/$base$suffix.jpg').writeAsBytes(bytes, flush: true);
      files.add(XFile(f.path, mimeType: 'image/jpeg'));
    }
    if (files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: files, sharePositionOrigin: origin));
  }

  /// Saves the pages to the photo gallery, in a "DocScan" album.
  static Future<void> saveToGallery(List<ScanPage> pages) async {
    if (!await Gal.hasAccess(toAlbum: true)) {
      if (!await Gal.requestAccess(toAlbum: true)) throw Exception('no permission to save photos');
    }
    final base = baseName();
    for (var i = 0; i < pages.length; i++) {
      final bytes = pages[i].result;
      if (bytes == null) continue;
      await Gal.putImageBytes(bytes, album: 'DocScan', name: '$base ${i + 1}');
    }
  }

  /// An empty temporary folder for files handed to the share sheet (cleared on each share).
  static Future<Directory> _shareDir() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/share');
    if (await dir.exists()) await dir.delete(recursive: true);
    return dir.create(recursive: true);
  }
}
