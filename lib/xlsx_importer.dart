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

  static XlsxWorkbookReader open(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxInputBytes) {
      throw const XlsxImportException('Workbook is empty or exceeds the 25 MB limit.');
    }
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) {
      throw const XlsxImportException('This is not an .xlsx ZIP workbook. Legacy .xls is unsupported.');
    }
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
        for (final code in match.group(1)!.codeUnits) col = col * 26 + code - 64;
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
      for (final entry in cells.entries) values[entry.key] = entry.value;
      result.add(values);
    }
    return result;
  }
}
