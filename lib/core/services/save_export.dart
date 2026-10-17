import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

/// Save a generated export where the user chooses; cancellation changes nothing.
Future<String?> saveExportAs(File source) async {
  final bytes = await source.readAsBytes();
  final extension = p.extension(source.path).replaceFirst('.', '');
  final target = await FilePicker.platform.saveFile(
    dialogTitle: 'Save export', fileName: p.basename(source.path),
    type: FileType.custom, allowedExtensions: [extension], bytes: bytes,
  );
  if (target == null) return null;
  if (!Platform.isAndroid && !Platform.isIOS) {
    await File(target).writeAsBytes(bytes, flush: true);
  }
  return target;
}
