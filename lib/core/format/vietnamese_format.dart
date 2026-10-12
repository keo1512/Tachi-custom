/// Presentation only. Storage keeps its original encoding and fingerprints.
String vietnameseDateTime(DateTime value, {bool includeTime = true}) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  final date = '${two(local.day)}/${two(local.month)}/${local.year}';
  return includeTime ? '$date ${two(local.hour)}:${two(local.minute)}' : date;
}

String vietnameseNumber(num value, {int decimals = 0}) {
  if (!value.isFinite || decimals < 0 || decimals > 6) {
    throw ArgumentError('Số hiển thị không hợp lệ.');
  }
  final parts = value.abs().toStringAsFixed(decimals).split('.');
  final grouped = parts.first.replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (match) => '${match[1]}.',
  );
  return '${value < 0 ? '-' : ''}$grouped${decimals > 0 ? ',${parts.last}' : ''}';
}
