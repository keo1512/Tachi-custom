import 'dart:typed_data';

import 'protobuf_reader.dart';

/// Official v0.20.4 BackupTracking field types. IDs remain signed 64-bit.
void validateMihonTracking(Uint8List bytes, [ProtoBudget? budget]) {
  final item = ProtoMessage(bytes, budget);
  for (final field in [1, 3, 7, 9]) {
    final number = item.integer(field, required: field == 1);
    if (number < -(BigInt.one << 31) ||
        number > (BigInt.one << 31) - BigInt.one) {
      throw const FormatException('Số nguyên tracker vượt giới hạn Int.');
    }
  }
  item.integer(2, required: true);
  for (final field in [10, 11, 100]) {
    item.integer(field);
  }
  for (final field in [4, 5]) {
    item.string(field);
  }
  for (final field in [6, 8]) {
    item.floatingPoint(field);
  }
  item.boolean(12);
}
