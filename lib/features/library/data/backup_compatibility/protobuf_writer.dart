import 'dart:convert';
import 'dart:typed_data';

/// The same wire/size limits as the bounded Mihon backup reader. A shared
/// budget includes fields in every nested message, not only the root message.
class ProtoWriteBudget {
  int fields = 0;
}

class ProtoWriter {
  ProtoWriter([ProtoWriteBudget? shared])
    : budget = shared ?? ProtoWriteBudget();

  static const maxBytes = 128 * 1024 * 1024;
  static final _minimum = -(BigInt.one << 63);
  static final _maximum = (BigInt.one << 63) - BigInt.one;
  final ProtoWriteBudget budget;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void integer(int field, BigInt value) {
    if (value < _minimum || value > _maximum) {
      throw const FormatException('Số nguyên sao lưu vượt giới hạn 64 bit.');
    }
    _tag(field, 0);
    _add(_varint(value));
  }

  void int64(int field, int value) => integer(field, BigInt.from(value));

  void boolean(int field, bool value) => int64(field, value ? 1 : 0);

  void string(int field, String value) {
    final encoded = utf8.encode(value);
    if (encoded.length > 2 * 1024 * 1024) {
      throw const FormatException('Chuỗi sao lưu vượt giới hạn 2 MB.');
    }
    message(field, Uint8List.fromList(encoded));
  }

  void message(int field, Uint8List value) {
    _tag(field, 2);
    _add(_varint(BigInt.from(value.length)));
    _add(value);
  }

  void float32(int field, double value) {
    final bytes = ByteData(4)..setFloat32(0, value, Endian.little);
    if (!value.isFinite || !bytes.getFloat32(0, Endian.little).isFinite) {
      throw const FormatException('Số chương sao lưu phải hữu hạn.');
    }
    _tag(field, 5);
    _add(bytes.buffer.asUint8List());
  }

  void packedIntegers(int field, List<BigInt> values) {
    if (values.length > 10000) {
      throw const FormatException('Danh mục sao lưu vượt giới hạn.');
    }
    final packed = BytesBuilder(copy: false);
    for (final value in values) {
      if (value < _minimum || value > _maximum) {
        throw const FormatException('ID danh mục vượt giới hạn 64 bit.');
      }
      packed.add(_varint(value));
    }
    if (values.isNotEmpty) message(field, packed.takeBytes());
  }

  Uint8List finish() => _bytes.toBytes();

  void _tag(int field, int wire) {
    if (field < 1 || field > 0x1fffffff || ++budget.fields > 2000000) {
      throw const FormatException('Sao lưu protobuf có quá nhiều trường.');
    }
    _add(_varint(BigInt.from((field << 3) | wire)));
  }

  void _add(List<int> bytes) {
    if (_bytes.length + bytes.length > maxBytes) {
      throw const FormatException('Bản sao lưu vượt giới hạn 128 MB.');
    }
    _bytes.add(bytes);
  }
}

Uint8List _varint(BigInt value) {
  var remaining = value.toUnsigned(64);
  final bytes = <int>[];
  do {
    final byte = (remaining & BigInt.from(127)).toInt();
    remaining >>= 7;
    bytes.add(byte | (remaining == BigInt.zero ? 0 : 128));
  } while (remaining != BigInt.zero);
  return Uint8List.fromList(bytes);
}
