import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

Future<String?> saveBytes(String suggestedName, Uint8List bytes) async {
  final location = await getSaveLocation(suggestedName: suggestedName);
  if (location == null) return null;
  await File(location.path).writeAsBytes(bytes);
  return location.path;
}
