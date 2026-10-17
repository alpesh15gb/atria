import 'dart:io';
import 'dart:typed_data';

import 'package:atria/core/services/save_export.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

class _SavePicker extends FilePicker {
  _SavePicker(this.target);
  final String? target;
  String? suggested;
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    suggested = fileName;
    return target;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FilePicker.platform = _SavePicker(null);
  test('export saves exact bytes at the user selected location without opening a viewer', () async {
    final original = FilePicker.platform;
    addTearDown(() => FilePicker.platform = original);
    final dir = await Directory.systemTemp.createTemp('save-export-');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/report.xlsx');
    await source.writeAsBytes([80, 75, 1, 2]);
    final picker = _SavePicker('${dir.path}/chosen.xlsx');
    FilePicker.platform = picker;
    expect(await saveExportAs(source), picker.target);
    expect(await File(picker.target!).readAsBytes(), [80, 75, 1, 2]);
    expect(picker.suggested, 'report.xlsx');
  }, skip: Platform.isAndroid || Platform.isIOS);
  test('cancelling Save As does not create a destination file', () async {
    final original = FilePicker.platform;
    addTearDown(() => FilePicker.platform = original);
    final dir = await Directory.systemTemp.createTemp('save-export-');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/report.xlsx');
    await source.writeAsBytes([1, 2]);
    FilePicker.platform = _SavePicker(null);
    expect(await saveExportAs(source), isNull);
    expect(dir.listSync(), hasLength(1));
  });
}
