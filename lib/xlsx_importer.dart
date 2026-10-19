import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

class XlsxImportException implements Exception {
  final String message;
  const XlsxImportException(this.message);
  @override
  String toString() => message;
}

class XlsxSheetInfo {
  final String name;
  final String path;
  final bool hidden;
  final int headerScore;
  const XlsxSheetInfo(this.name, this.path, this.hidden, this.headerScore);
  Map<String, Object> toJson() => {'name': name, 'hidden': hidden, 'headerScore': headerScore};
}

class XlsxWorkbookReader {
  static const int maxInputBytes = 25 * 1024 * 1024;
  static const int maxExpandedBytes = 150 * 1024 * 1024;
  static const int maxEntries = 3000;
  static const int maxRows = 5000;
  static const int maxColumns = 100;
  final Map<String, ArchiveFile> _files;
  final List<String> _sharedStrings;
  final List<XlsxSheetInfo> sheets;

  XlsxWorkbookReader._(this._files, this._sharedStrings, this.sheets);

  static Iterable<XmlElement> _all(XmlNode node, String local) =>
      node.descendants.whereType<XmlElement>().where((e) => e.name.local == local);
  static Iterable<XmlElement> _kids(XmlNode node, String local) =>
      node.children.whereType<XmlElement>().where((e) => e.name.local == local);
  static String? _attr(XmlElement element, String local) {
    for (final attribute in element.attributes) {
      if (attribute.name.local == local) return attribute.value;
    }
    return null;
  }
  static String _resolve(String base, String target) {
    final parts = <String>[];
    final raw = target.startsWith('/') ? target.substring(1) : '$base$target';
    for (final part in raw.replaceAll('\\', '/').split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isEmpty) throw const XlsxImportException('Workbook relationship escapes its package.');
        parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/');
  }

  /// Detect legacy .xls / encrypted OLE files from their signature, not extension.
  static void sniff(Uint8List bytes) {
    if (bytes.length >= 4 && bytes[0] == 0xD0 && bytes[1] == 0xCF &&
        bytes[2] == 0x11 && bytes[3] == 0xE0) {
      throw const XlsxImportException(
        'This looks like an old Excel (.xls) file or a password-protected workbook. '
        'Open it in Excel and use File → Save As → Excel Workbook (.xlsx). '
        'If it has a password, remove it first. On a phone, open it in Google Sheets, '
        'then Share & export → Save as Excel (.xlsx).',
      );
    }
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      throw const XlsxImportException(
        'This file is not an .xlsx workbook. Save it as Excel Workbook (.xlsx). '
        'CSV is data-only and does not preserve photos.',
      );
    }
  }

  static XlsxWorkbookReader open(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxInputBytes) {
      throw const XlsxImportException('Workbook is empty or exceeds the 25 MB limit.');
    }
    sniff(bytes);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (_) {
      throw const XlsxImportException('The workbook ZIP structure is invalid or damaged.');
    }
    if (archive.length > maxEntries) throw const XlsxImportException('Workbook contains too many ZIP entries.');
    var expanded = 0;
    final files = <String, ArchiveFile>{};
    for (final file in archive) {
      if (!file.isFile) continue;
      expanded += file.size;
      if (expanded > maxExpandedBytes) throw const XlsxImportException('Workbook expands beyond the 150 MB safety limit.');
      final name = file.name.replaceAll('\\', '/');
      if (name.startsWith('/') || name.split('/').contains('..')) {
        throw const XlsxImportException('Workbook contains an unsafe ZIP path.');
      }
      files[name] = file;
    }
    XmlDocument xml(String path) {
      final file = files[path];
      if (file == null) throw XlsxImportException('Workbook is missing $path.');
      try {
        return XmlDocument.parse(utf8.decode(file.content as List<int>));
      } catch (_) {
        throw XlsxImportException('Workbook XML is invalid: $path.');
      }
    }
    final workbook = xml('xl/workbook.xml');
    final relsDoc = xml('xl/_rels/workbook.xml.rels');
    final relationships = <String, String>{};
    for (final rel in _all(relsDoc, 'Relationship')) {
      final id = _attr(rel, 'Id'), target = _attr(rel, 'Target');
      if (id != null && target != null) relationships[id] = target;
    }
    final shared = <String>[];
    final sharedDocFile = files['xl/sharedStrings.xml'];
    if (sharedDocFile != null) {
      try {
        final doc = XmlDocument.parse(utf8.decode(sharedDocFile.content as List<int>));
        for (final item in _all(doc, 'si')) {
          shared.add(_all(item, 't').map((e) => e.innerText).join());
        }
      } catch (_) {
        throw const XlsxImportException('Workbook shared strings are invalid.');
      }
    }
    final sheets = <XlsxSheetInfo>[];
    for (final sheet in _all(workbook, 'sheet')) {
      final name = _attr(sheet, 'name') ?? 'Sheet ${sheets.length + 1}';
      final relId = _attr(sheet, 'id');
      final target = relId == null ? null : relationships[relId];
      if (target == null) continue;
      final path = _resolve('xl/', target);
      if (!files.containsKey(path)) throw XlsxImportException('Worksheet "$name" is missing.');
      final hidden = (_attr(sheet, 'state') ?? 'visible') != 'visible';
      final reader = XlsxWorkbookReader._(files, shared, const []);
      final rows = reader._readRows(path, limit: 30, truncate: true);
      final headerScore = _headerScore(rows);
      sheets.add(XlsxSheetInfo(name, path, hidden, headerScore));
    }
    if (sheets.isEmpty) throw const XlsxImportException('Workbook contains no readable worksheets.');
    return XlsxWorkbookReader._(files, shared, List.unmodifiable(sheets));
  }

  static int _headerScore(List<List<String>> rows) {
    const aliases = {
      'name','guest name','full name','guest full name','customer name','phone','mobile',
      'mobile number','contact','contact number','phone number','email','id type','id number',
      'identity number','document number','address','aadhaar number','aadhar number',
      'passport number','pan number','नाम','मोबाइल','पता'
    };
    var best = 0;
    for (final row in rows.take(20)) {
      final score = row.map((v) => v.toLowerCase().trim().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' '))
          .where((v) => aliases.contains(v)).length;
      if (score > best) best = score;
    }
    return best;
  }

  List<List<String>> readSheet(int index) {
    if (index < 0 || index >= sheets.length) throw const XlsxImportException('Invalid worksheet selection.');
    return _readRows(sheets[index].path, limit: maxRows);
  }

  List<List<String>> _readRows(String path, {required int limit, bool truncate = false}) {
    final file = _files[path];
    if (file == null) throw XlsxImportException('Worksheet is missing: $path');
    final XmlDocument doc;
    try { doc = XmlDocument.parse(utf8.decode(file.content as List<int>)); }
    catch (_) { throw XlsxImportException('Worksheet XML is invalid: $path'); }
    final result = <List<String>>[];
    for (final row in _all(doc, 'row')) {
      if (result.length >= limit) { if (truncate) break; throw const XlsxImportException('Worksheet exceeds the row limit. Split it into smaller sheets.'); }
      final cells = <int, String>{};
      var maxColumn = -1;
      for (final cell in _all(row, 'c')) {
        final ref = _attr(cell, 'r') ?? '';
        final match = RegExp(r'^([A-Z]+)').firstMatch(ref.toUpperCase());
        if (match == null) continue;
        var col = 0;
        for (final code in match.group(1)!.codeUnits) { col = col * 26 + code - 64; }
        col--;
        if (col < 0 || col >= maxColumns) throw const XlsxImportException('Worksheet exceeds 100 columns.');
        final type = _attr(cell, 't') ?? '';
        final valueNode = _kids(cell, 'v').firstOrNull;
        String value = '';
        if (type == 'inlineStr') {
          final inline = _kids(cell, 'is').firstOrNull;
          if (inline != null) value = _all(inline, 't').map((e) => e.innerText).join();
        } else if (valueNode != null) {
          value = valueNode.innerText;
          if (type == 's') {
            final idx = int.tryParse(value);
            value = idx != null && idx >= 0 && idx < _sharedStrings.length ? _sharedStrings[idx] : '';
          } else if (type == 'b') {
            value = value == '1' ? 'TRUE' : 'FALSE';
          }
        }
        cells[col] = value;
        if (col > maxColumn) maxColumn = col;
      }
      final values = List<String>.filled(maxColumn + 1, '');
      for (final entry in cells.entries) { values[entry.key] = entry.value; }
      result.add(values);
    }
    return result;
  }

  /// Extract photos attached to worksheet rows via floating drawing anchors
  /// and Excel richData "Place in Cell" representation. Row numbers are
  /// one-based physical Excel row numbers, including the header row.
  Map<int, Uint8List> photosForSheet(int index, List<String> warnings) {
    if (index < 0 || index >= sheets.length) throw const XlsxImportException('Invalid worksheet selection.');
    final path = sheets[index].path;
    final file = _files[path];
    if (file == null) return {};
    final sheet = XmlDocument.parse(utf8.decode(file.content as List<int>));
    final floating = _floatingImages(path, warnings);
    final inCell = _inCellImages(sheet, warnings);
    final merged = <int, Uint8List>{...floating};
    for (final entry in inCell.entries) {
      if (merged.containsKey(entry.key)) {
        warnings.add('multiple_photos_ambiguous:${entry.key}');
      } else {
        merged[entry.key] = entry.value;
      }
    }
    return merged;
  }

  Map<int, Uint8List> _floatingImages(String sheetPath, List<String> warnings) {
    final slash = sheetPath.lastIndexOf('/');
    final directory = sheetPath.substring(0, slash);
    final fileName = sheetPath.substring(slash + 1);
    final relsFile = _files['$directory/_rels/$fileName.rels'];
    if (relsFile == null) return {};
    XmlDocument parseFile(ArchiveFile source) => XmlDocument.parse(utf8.decode(source.content as List<int>));
    try {
      final rels = parseFile(relsFile);
      final drawingRel = _all(rels, 'Relationship').where(
        (r) => (_attr(r, 'Type') ?? '').endsWith('/drawing'),
      ).firstOrNull;
      final target = drawingRel == null ? null : _attr(drawingRel, 'Target');
      if (target == null) return {};
      final drawingPath = _resolve(directory, target);
      final drawingFile = _files[drawingPath];
      if (drawingFile == null) { warnings.add('drawing_missing:$drawingPath'); return {}; }
      final drawing = parseFile(drawingFile);
      final drawSlash = drawingPath.lastIndexOf('/');
      final drawDir = drawingPath.substring(0, drawSlash);
      final drawName = drawingPath.substring(drawSlash + 1);
      final drawingRelsFile = _files['$drawDir/_rels/$drawName.rels'];
      final mediaTargets = <String, String>{};
      if (drawingRelsFile != null) {
        for (final rel in _all(parseFile(drawingRelsFile), 'Relationship')) {
          final id = _attr(rel, 'Id'), relTarget = _attr(rel, 'Target');
          if (id != null && relTarget != null) mediaTargets[id] = relTarget;
        }
      }
      final out = <int, Uint8List>{};
      for (final anchor in _all(drawing, 'oneCellAnchor').followedBy(_all(drawing, 'twoCellAnchor'))) {
        final from = _kids(anchor, 'from').firstOrNull;
        final zeroRow = int.tryParse(from == null ? '' : _kids(from, 'row').firstOrNull?.innerText ?? '');
        final blip = _all(anchor, 'blip').firstOrNull;
        final embed = blip == null ? null : _attr(blip, 'embed');
        if (zeroRow == null || embed == null) { warnings.add('floating_photo_anchor_unreadable'); continue; }
        final row = zeroRow + 1;
        final mediaTarget = mediaTargets[embed];
        if (mediaTarget == null) { warnings.add('floating_photo_relationship_missing:$row'); continue; }
        final mediaPath = _resolve(drawDir, mediaTarget);
        final media = _files[mediaPath];
        if (media == null) { warnings.add('floating_photo_media_missing:$row'); continue; }
        final image = _supportedImage(mediaPath, media, row, warnings);
        if (image == null) continue;
        if (out.containsKey(row)) { warnings.add('multiple_photos_ambiguous:$row'); } else { out[row] = image; }
      }
      return out;
    } catch (_) {
      warnings.add('floating_photo_layout_unreadable');
      return {};
    }
  }

  Map<int, Uint8List> _inCellImages(XmlDocument sheet, List<String> warnings) {
    const required = ['xl/metadata.xml', 'xl/richData/rdrichvalue.xml',
      'xl/richData/rdrichvaluestructure.xml', 'xl/richData/richValueRel.xml',
      'xl/richData/_rels/richValueRel.xml.rels'];
    if (!required.every(_files.containsKey)) return {};
    try {
      XmlDocument read(String path) => XmlDocument.parse(utf8.decode(_files[path]!.content as List<int>));
      final relationshipTargets = <String, String>{};
      for (final rel in _all(read(required[4]), 'Relationship')) {
        final id = _attr(rel, 'Id'), target = _attr(rel, 'Target');
        if (id != null && target != null) relationshipTargets[id] = target;
      }
      final relIds = [for (final rel in _all(read(required[3]), 'rel')) _attr(rel, 'id')];
      final linkPositions = <int>[];
      for (final structure in _all(read(required[2]), 's')) {
        linkPositions.add(_kids(structure, 'k').map((k) => _attr(k, 'n')).toList().indexOf('_rvRel:LocalImageIdentifier'));
      }
      final richValueToRel = <int>[];
      for (final value in _all(read(required[1]), 'rv')) {
        final structureIndex = int.tryParse(_attr(value, 's') ?? '') ?? -1;
        final values = _kids(value, 'v').toList();
        final position = structureIndex >= 0 && structureIndex < linkPositions.length ? linkPositions[structureIndex] : -1;
        richValueToRel.add(position >= 0 && position < values.length ? int.tryParse(values[position].innerText) ?? -1 : -1);
      }
      final metadata = read(required[0]);
      final futureValues = <int>[];
      for (final future in _all(metadata, 'futureMetadata').where((e) => _attr(e, 'name') == 'XLRICHVALUE')) {
        for (final block in _kids(future, 'bk')) {
          final rvb = _all(block, 'rvb').firstOrNull;
          futureValues.add(int.tryParse(rvb == null ? '' : _attr(rvb, 'i') ?? '') ?? -1);
        }
      }
      final valueMetadata = _all(metadata, 'valueMetadata').firstOrNull;
      if (valueMetadata == null) return {};
      final valueIndexes = <int>[];
      for (final block in _kids(valueMetadata, 'bk')) {
        final rc = _all(block, 'rc').firstOrNull;
        valueIndexes.add(int.tryParse(rc == null ? '' : _attr(rc, 'v') ?? '') ?? -1);
      }
      final out = <int, Uint8List>{};
      for (final cell in _all(sheet, 'c')) {
        final vm = int.tryParse(_attr(cell, 'vm') ?? '');
        if (vm == null) continue;
        final row = int.tryParse(RegExp(r'\d+').firstMatch(_attr(cell, 'r') ?? '')?.group(0) ?? '');
        if (row == null) { warnings.add('in_cell_photo_unreadable:unknown_row'); continue; }
        try {
          final futureIndex = valueIndexes[vm - 1];
          final richIndex = futureValues[futureIndex];
          final relIndex = richValueToRel[richIndex];
          final relId = relIds[relIndex];
          final mediaPath = _resolve('xl/richData/', relationshipTargets[relId]!);
          final media = _files[mediaPath]!;
          final image = _supportedImage(mediaPath, media, row, warnings);
          if (image == null) continue;
          if (out.containsKey(row)) { warnings.add('multiple_photos_ambiguous:$row'); } else { out[row] = image; }
        } catch (_) { warnings.add('in_cell_photo_unreadable:$row'); }
      }
      return out;
    } catch (_) {
      warnings.add('in_cell_photo_layout_unreadable');
      return {};
    }
  }

  Uint8List? _supportedImage(String path, ArchiveFile file, int row, List<String> warnings) {
    final extension = path.split('.').last.toLowerCase();
    if (!const {'png', 'jpg', 'jpeg'}.contains(extension)) { warnings.add('unsupported_image_format:$extension'); return null; }
    if (file.size <= 0 || file.size > 8 * 1024 * 1024) { warnings.add('photo_size_invalid_or_too_large:$row'); return null; }
    final bytes = Uint8List.fromList(file.content as List<int>);
    final isPng = bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 &&
      bytes[2] == 0x4e && bytes[3] == 0x47 && bytes[4] == 0x0d && bytes[5] == 0x0a &&
      bytes[6] == 0x1a && bytes[7] == 0x0a;
    final isJpeg = bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff;
    if (!isPng && !isJpeg) { warnings.add('photo_magic_bytes_invalid:$row'); return null; }
    return bytes;
  }

}
