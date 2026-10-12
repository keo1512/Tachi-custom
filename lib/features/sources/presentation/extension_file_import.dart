import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/catalogue.dart';

const maxExtensionPackageBytes = 32 * 1024 * 1024;

/// A separate boundary keeps native Files picking out of presentation tests.
final extensionPackagePickerProvider = Provider<Future<Uint8List?> Function()>(
  (_) => pickExtensionPackage,
);

Future<Uint8List?> pickExtensionPackage() async {
  final selected = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: ['apk'],
    dialogTitle: 'Chọn extension Tachiyomi/Mihon',
  );
  if (selected == null) return null;
  final length = await selected.length();
  if (length != null && length > maxExtensionPackageBytes) {
    throw const ApiException('Gói APK vượt giới hạn 32 MiB.');
  }
  return readExtensionPackage(selected.readAsByteStream());
}

Future<Uint8List> readExtensionPackage(Stream<List<int>> input) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in input) {
    if (bytes.length + chunk.length > maxExtensionPackageBytes) {
      throw const ApiException('Gói APK vượt giới hạn 32 MiB.');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
