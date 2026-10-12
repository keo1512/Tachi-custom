import 'dart:convert';

/// Data from verified external backup schemas. It is carried through a full
/// TachiBooks backup without executing source memos or contacting a tracker.
/// The original source identity is retained even after a source migration.
class ExternalBackupMetadata {
  ExternalBackupMetadata({
    required this.format,
    required this.engine,
    required this.sourceId,
    required this.sourceRef,
    List<String> tracking = const [],
    List<String> trackingArchive = const [],
    this.memo,
  }) : tracking = List.unmodifiable(tracking),
       trackingArchive = List.unmodifiable(trackingArchive) {
    _validate();
  }

  // Keep the encoded envelope below the existing per-book 2 MiB metadata cap.
  // Repository validation additionally checks the entire book, not just this
  // envelope. Oversized external input is rejected; no opaque data is trimmed.
  static const maxBytes = 1024 * 1024;
  static const maxMemoBytes = 768 * 1024;
  static const maxTrackers = 64;
  final String format, engine, sourceId, sourceRef;

  /// Exact BackupTracking protobuf messages, including unknown fields.
  final List<String> tracking;

  /// Original Tachimanga TrackRecord values as JSON bytes. This keeps REAL
  /// precision in full backups when Mihon's exchange schema uses float32.
  final List<String> trackingArchive;

  /// Original source-private memo bytes. Never used as configuration or code.
  final String? memo;

  bool belongsTo(String currentEngine, String currentSourceId, String ref) =>
      engine == currentEngine &&
      sourceId == currentSourceId &&
      sourceRef == ref;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'format': format,
    'engine': engine,
    'sourceId': sourceId,
    'sourceRef': sourceRef,
    'tracking': tracking,
    if (trackingArchive.isNotEmpty) 'trackingArchive': trackingArchive,
    if (memo != null) 'memo': memo,
  };

  factory ExternalBackupMetadata.fromJson(Object? value) {
    if (value is! Map ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value.keys.any(
          (key) => ![
            'version',
            'format',
            'engine',
            'sourceId',
            'sourceRef',
            'tracking',
            'trackingArchive',
            'memo',
          ].contains(key),
        ) ||
        value['format'] is! String ||
        value['engine'] is! String ||
        value['sourceId'] is! String ||
        value['sourceRef'] is! String ||
        value['tracking'] is! List ||
        (value['tracking'] as List).any((item) => item is! String) ||
        (value.containsKey('trackingArchive') &&
            (value['trackingArchive'] is! List ||
                (value['trackingArchive'] as List).any(
                  (item) => item is! String,
                ))) ||
        (value.containsKey('memo') && value['memo'] is! String)) {
      throw const FormatException('Dữ liệu tương thích sao lưu không hợp lệ.');
    }
    return ExternalBackupMetadata(
      format: value['format'] as String,
      engine: value['engine'] as String,
      sourceId: value['sourceId'] as String,
      sourceRef: value['sourceRef'] as String,
      tracking: (value['tracking'] as List).cast<String>(),
      trackingArchive: (value['trackingArchive'] as List? ?? const [])
          .cast<String>(),
      memo: value['memo'] as String?,
    );
  }

  void _validate() {
    final id = BigInt.tryParse(sourceId);
    if (!['mihon-protobuf-v0.20.4', 'tachimanga-build511'].contains(format) ||
        engine != 'tachimanga' ||
        id == null ||
        id.toString() != sourceId ||
        id < -(BigInt.one << 63) ||
        id > (BigInt.one << 63) - BigInt.one ||
        sourceRef.isEmpty ||
        utf8.encode(sourceRef).length > 2 * 1024 * 1024 ||
        tracking.length > maxTrackers ||
        trackingArchive.length > maxTrackers ||
        (trackingArchive.isNotEmpty &&
            trackingArchive.length != tracking.length)) {
      throw const FormatException('Dữ liệu tương thích nguồn vượt giới hạn.');
    }
    var total = 0;
    for (final item in [...tracking, ...trackingArchive, ?memo]) {
      // Check encoded size before allocating decoded bytes.
      if (item.length > ((maxMemoBytes + 2) ~/ 3) * 4) {
        throw const FormatException('Dữ liệu tracker hoặc memo quá lớn.');
      }
      final bytes = base64Decode(item);
      if (bytes.length > maxMemoBytes || base64Encode(bytes) != item) {
        throw const FormatException('Dữ liệu tracker hoặc memo không hợp lệ.');
      }
      total += bytes.length;
      if (total > maxBytes) {
        throw const FormatException('Dữ liệu tương thích sao lưu quá lớn.');
      }
    }
    if (utf8.encode(jsonEncode(toJson())).length > maxBytes) {
      throw const FormatException('Dữ liệu tương thích sao lưu quá lớn.');
    }
  }
}
