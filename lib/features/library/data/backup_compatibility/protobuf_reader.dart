import 'dart:convert';
import 'dart:typed_data';

/// Bounded protobuf wire reader. Unknown fields are skipped without interpreting
/// strings or running code; signed int64 values remain BigInt until converted.
class ProtoField {
  const ProtoField(this.wire, this.value);
  final int wire;
  final Object value;
}

class ProtoBudget {
  int fields = 0;
}

class ProtoMessage {
  ProtoMessage(Uint8List bytes, [ProtoBudget? shared])
    : budget = shared ?? ProtoBudget() {
    final input = ProtoInput(bytes);
    while (!input.done) {
      if (++budget.fields > 2000000) {
        throw const FormatException('Protobuf có quá nhiều trường.');
      }
      final tag = input.varint();
      if (tag > BigInt.from(0xffffffff)) {
        throw const FormatException('Tag protobuf vượt giới hạn.');
      }
      final number = tag.toInt() >> 3;
      final wire = tag.toInt() & 7;
      if (number == 0) {
        throw const FormatException('Tag protobuf không hợp lệ.');
      }
      final Object value;
      switch (wire) {
        case 0:
          value = input.varint();
        case 1:
          value = input.bytes(8);
        case 2:
          final count = input.varint();
          if (count > BigInt.from(input.remaining)) {
            throw const FormatException('Protobuf bị cắt ngắn.');
          }
          value = input.bytes(count.toInt());
        case 5:
          value = input.bytes(4);
        default:
          throw const FormatException('Wire type protobuf chưa được hỗ trợ.');
      }
      fields.putIfAbsent(number, () => []).add(ProtoField(wire, value));
    }
  }
  final ProtoBudget budget;
  final Map<int, List<ProtoField>> fields = {};

  ProtoField? one(int number) {
    final values = fields[number];
    if (values == null) return null;
    if (values.length != 1) {
      throw const FormatException('Trường protobuf đơn bị trùng.');
    }
    return values.single;
  }

  List<ProtoMessage> messages(int number, {int maximum = 10000}) {
    final values = fields[number] ?? [];
    if (values.length > maximum) {
      throw const FormatException('Protobuf có quá nhiều mục.');
    }
    return values.map((field) {
      if (field.wire != 2) {
        throw const FormatException('Message protobuf không hợp lệ.');
      }
      return ProtoMessage(field.value as Uint8List, budget);
    }).toList();
  }

  String string(int number, {String fallback = '', bool required = false}) {
    final field = one(number);
    if (field == null && !required) return fallback;
    if (field?.wire != 2) {
      throw const FormatException('Chuỗi protobuf không hợp lệ.');
    }
    final bytes = field!.value as Uint8List;
    if (bytes.length > 2 * 1024 * 1024) {
      throw const FormatException('Chuỗi protobuf vượt giới hạn 2 MB.');
    }
    return utf8.decode(bytes);
  }

  BigInt integer(int number, {bool required = false}) {
    final field = one(number);
    if (field == null && !required) return BigInt.zero;
    if (field?.wire != 0) {
      throw const FormatException('Số nguyên protobuf không hợp lệ.');
    }
    return (field!.value as BigInt).toSigned(64);
  }

  List<String> strings(int number, {int maximum = 10000}) {
    final values = fields[number] ?? const <ProtoField>[];
    if (values.length > maximum) {
      throw const FormatException('Protobuf có quá nhiều chuỗi.');
    }
    return values.map((field) {
      if (field.wire != 2 ||
          (field.value as Uint8List).length > 2 * 1024 * 1024) {
        throw const FormatException(
          'Chuỗi protobuf không hợp lệ hoặc vượt giới hạn.',
        );
      }
      return utf8.decode(field.value as Uint8List);
    }).toList();
  }

  bool boolean(int number, {bool fallback = false}) {
    if (one(number) == null) return fallback;
    final value = integer(number);
    if (value != BigInt.zero && value != BigInt.one) {
      throw const FormatException('Boolean protobuf không hợp lệ.');
    }
    return value == BigInt.one;
  }

  List<BigInt> integers(int number) {
    final result = <BigInt>[];
    for (final field in fields[number] ?? <ProtoField>[]) {
      if (result.length >= 10000) {
        throw const FormatException('Danh mục protobuf vượt giới hạn.');
      }
      if (field.wire == 0) {
        result.add((field.value as BigInt).toSigned(64));
      } else if (field.wire == 2) {
        final input = ProtoInput(field.value as Uint8List);
        while (!input.done) {
          if (result.length >= 10000) {
            throw const FormatException('Danh mục protobuf vượt giới hạn.');
          }
          result.add(input.varint().toSigned(64));
        }
      } else {
        throw const FormatException('Danh sách số protobuf không hợp lệ.');
      }
    }
    return result;
  }
}

class ProtoInput {
  ProtoInput(this.data);
  final Uint8List data;
  int position = 0;
  bool get done => position == data.length;
  int get remaining => data.length - position;
  BigInt varint() {
    var result = BigInt.zero;
    for (var i = 0; i < 10; i++) {
      if (done) throw const FormatException('Varint protobuf bị cắt ngắn.');
      final byte = data[position++];
      if (i == 9 && byte > 1) {
        throw const FormatException('Varint protobuf vượt 64 bit.');
      }
      result |= BigInt.from(byte & 0x7f) << (i * 7);
      if (byte & 0x80 == 0) return result;
    }
    throw const FormatException('Varint protobuf không hợp lệ.');
  }

  Uint8List bytes(int count) {
    if (count < 0 || count > remaining) {
      throw const FormatException('Protobuf bị cắt ngắn.');
    }
    final start = position;
    position += count;
    return Uint8List.sublistView(data, start, position);
  }
}
