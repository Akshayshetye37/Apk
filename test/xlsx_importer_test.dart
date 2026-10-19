import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aurelia_pms/xlsx_importer.dart';

Uint8List workbookBytes({bool prefixed = true}) {
  final archive = Archive();
  final workbook = prefixed
      ? '<x:workbook xmlns:x="urn:spreadsheet" xmlns:r="urn:relationships"><x:sheets><x:sheet name="Guests" sheetId="1" r:id="rId1"/><x:sheet name="Hidden" sheetId="2" state="hidden" r:id="rId2"/></x:sheets></x:workbook>'
      : '<workbook xmlns="urn:spreadsheet" xmlns:r="urn:relationships"><sheets><sheet name="Guests" sheetId="1" r:id="rId1"/><sheet name="Hidden" sheetId="2" state="hidden" r:id="rId2"/></sheets></workbook>';
  final rels = '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Target="worksheets/sheet2.xml"/></Relationships>';
  final sheet1 = '<worksheet xmlns="urn:spreadsheet"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Guest Name</t></is></c><c r="B1" t="inlineStr"><is><t>Mobile Number</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>रमेश</t></is></c><c r="B2"><v>9876501234</v></c></row></sheetData></worksheet>';
  final sheet2 = '<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Name</t></is></c></row></sheetData></worksheet>';
  void add(String name, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  add('xl/workbook.xml', workbook);
  add('xl/_rels/workbook.xml.rels', rels);
  add('xl/worksheets/sheet1.xml', sheet1);
  add('xl/worksheets/sheet2.xml', sheet2);
  final encoded = ZipEncoder().encode(archive);
  if (encoded == null) throw StateError('Could not create test workbook');
  return Uint8List.fromList(encoded);
}

void main() {
  test('reads all worksheets and identifies hidden sheets', () {
    final reader = XlsxWorkbookReader.open(workbookBytes());
    expect(reader.sheets.map((s) => s.name), ['Guests', 'Hidden']);
    expect(reader.sheets[1].hidden, isTrue);
    expect(reader.sheets[0].headerScore, greaterThanOrEqualTo(2));
    expect(reader.readSheet(0)[1], ['रमेश', '9876501234']);
  });

  test('namespace prefixes and default namespaces produce equivalent data', () {
    final prefixed = XlsxWorkbookReader.open(workbookBytes(prefixed: true));
    final defaultNamespace = XlsxWorkbookReader.open(workbookBytes(prefixed: false));
    expect(prefixed.sheets.map((s) => s.name).toList(), defaultNamespace.sheets.map((s) => s.name).toList());
    expect(prefixed.readSheet(0), defaultNamespace.readSheet(0));
  });

  test('rejects a non-ZIP legacy workbook', () {
    expect(() => XlsxWorkbookReader.open(Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0])),
        throwsA(isA<XlsxImportException>()));
  });
}
