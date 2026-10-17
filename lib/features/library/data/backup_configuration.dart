import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/library_categories.dart';
import '../domain/library_grouping.dart';
import '../domain/library_folders.dart';
import '../domain/book_reading_times.dart';
import '../presentation/library_filter_sheet.dart';
import '../../reader/domain/reader_options.dart';
import '../../sources/domain/source_filters.dart';
import '../../sources/domain/source_languages.dart';
import '../../settings/navigation_preferences.dart';

/// Portable public configuration only. Authentication, source cookies/secrets,
/// device locks, companion connections and live downloads stay on each device.
class BackupConfiguration {
  BackupConfiguration._(Map<String, Object> values)
    : values = Map.unmodifiable(values);
  final Map<String, Object> values;
  static const maxBytes = 2 * 1024 * 1024;
  static const _plain = {
    'dark',
    'libraryColumns',
    'downloadConcurrency',
    'fontSize',
    'lineHeight',
    'readerTheme',
    'font',
    'mangaMode',
    'pinnedSources',
    'recentSources',
    'readingGoalMinutes',
    'sourceCatalogueLayoutV1',
    'libraryGrouping',
    'appearanceV1',
    'taskNotificationsEnabledV1',
  };
  static const _json = {
    LibraryFolders.preferenceKey,
    BookReadingTimes.preferenceKey,
    'extensionRepositoriesV1',
    'libraryCategoriesV1',
    'libraryGroupOrderV1',
    'libraryFilterV1',
    'readerOptionsV1',
    'libraryUpdatePolicyV1',
    'downloadDeletionPolicyV1',
    'automaticBackupPolicyV1',
    'savedSourceFiltersV1',
    'navigationPreferencesV1',
    'sourceLanguagesV1',
  };
  static bool isPortableKey(String key) =>
      _plain.contains(key) ||
      _json.contains(key) ||
      key.startsWith('readSeconds:');

  factory BackupConfiguration.capture(SharedPreferences preferences) =>
      BackupConfiguration.fromJson({
        'version': 1,
        'preferences': {
          for (final key in preferences.getKeys().where(isPortableKey))
            key: preferences.get(key),
        },
      });

  factory BackupConfiguration.fromJson(Object? value) {
    final root = _object(value);
    if (root.keys.any((key) => !['version', 'preferences'].contains(key)) ||
        root['version'] != 1) {
      throw const FormatException('Phiên bản thiết lập sao lưu không hợp lệ.');
    }
    final prefs = _object(root['preferences']);
    if (prefs.length > 10000 ||
        utf8.encode(jsonEncode(root)).length > maxBytes) {
      throw const FormatException('Thiết lập sao lưu vượt giới hạn 2 MB.');
    }
    final result = <String, Object>{};
    for (final entry in prefs.entries) {
      if (!isPortableKey(entry.key)) {
        throw FormatException('Thiết lập không được phép nhập: ${entry.key}.');
      }
      final value = entry.value;
      _validate(entry.key, value);
      result[entry.key] = switch (entry.key) {
        'fontSize' || 'lineHeight' => (value as num).toDouble(),
        'pinnedSources' || 'recentSources' => List<String>.unmodifiable(
          (value as List).cast<String>(),
        ),
        _ => value as Object,
      };
    }
    return BackupConfiguration._(result);
  }

  Map<String, dynamic> toJson({bool canonical = false}) => {
    'version': 1,
    'preferences': {
      for (final key in values.keys.toList()..sort())
        key: canonical && _json.contains(key)
            ? jsonEncode(_canonical(jsonDecode(values[key] as String)))
            : values[key],
    },
  };
  String get fingerprint => sha256
      .convert(utf8.encode(jsonEncode(toJson(canonical: true))))
      .toString();

  static void _validate(String key, Object? value) {
    Never invalid() => throw FormatException('Thiết lập $key không hợp lệ.');
    if (key.startsWith('readSeconds:')) {
      final match = RegExp(r'^readSeconds:(\d{4})-(\d{1,2})-(\d{1,2})$')
          .firstMatch(key);
      if (match == null) invalid();
      final year = int.parse(match.group(1)!),
          month = int.parse(match.group(2)!),
          day = int.parse(match.group(3)!);
      final date = DateTime(year, month, day);
      if (date.year != year ||
          date.month != month ||
          date.day != day ||
          value is! int ||
          value < 0 ||
          value > 9007199254740991) {
        invalid();
      }
      return;
    }
    if (_json.contains(key)) {
      if (value is! String) invalid();
      if (key == 'navigationPreferencesV1') {
        NavigationPreferences.decode(value);
        return;
      }
      if (key == 'sourceLanguagesV1') {
        SourceLanguages.decode(value);
        return;
      }
      final parsed = jsonDecode(value);
      _validateJson(key, parsed);
      return;
    }
    switch (key) {
      case 'dark':
      case 'taskNotificationsEnabledV1':
        if (value is! bool) invalid();
      case 'libraryColumns':
        if (value is! int || value < 2 || value > 8) invalid();
      case 'downloadConcurrency':
        if (value is! int || value < 1 || value > 4) invalid();
      case 'readingGoalMinutes':
        if (value is! int || value < 5 || value > 120) invalid();
      case 'fontSize':
        if (value is! num || !value.isFinite || value < 8 || value > 96) {
          invalid();
        }
      case 'lineHeight':
        if (value is! num || !value.isFinite || value < .5 || value > 5) {
          invalid();
        }
      case 'readerTheme':
        if (!['system', 'paper', 'sepia', 'night'].contains(value)) invalid();
      case 'appearanceV1':
        if (!['system', 'dark', 'light'].contains(value)) invalid();
      case 'font':
        if (!['NotoSans', 'NotoSerif', 'Arial', 'Georgia'].contains(value)) {
          invalid();
        }
      case 'mangaMode':
        if (!['vertical', 'paged', 'rtl'].contains(value)) invalid();
      case 'sourceCatalogueLayoutV1':
        if (!['comfortable', 'compact', 'list'].contains(value)) invalid();
      case 'libraryGrouping':
        if (!LibraryGrouping.values.any((mode) => mode.name == value)) {
          invalid();
        }
      case 'pinnedSources' || 'recentSources':
        _strings(value, max: 10000);
      default:
        invalid();
    }
  }

  static void _validateJson(String key, Object? value) {
    if (key == 'extensionRepositoriesV1') {
      if (value is! List || value.length > 50) {
        throw const FormatException('Danh sách kho không hợp lệ.');
      }
      final identities = <String>{};
      for (final item in value) {
        final repo = _object(item);
        _keys(repo, {'url', 'engine', 'name'});
        final name = repo['name'];
        if (name != null &&
            (name is! String ||
                name.length > 100 ||
                RegExp(r'[\x00-\x1f]').hasMatch(name))) {
          throw const FormatException('Tên kho sao lưu không hợp lệ.');
        }
        final url = repo['url'];
        final uri = url is String ? Uri.tryParse(url) : null;
        if (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment ||
            !['tachimanga', 'vbook'].contains(repo['engine']) ||
            !identities.add('${repo['engine']}:$url')) {
          throw const FormatException(
            'Chỉ sao lưu URL kho công khai, không có tài khoản hoặc token.',
          );
        }
      }
      return;
    }
    final data = _object(value);
    switch (key) {
      case LibraryFolders.preferenceKey:
        LibraryFolders.decode(jsonEncode(data));
      case BookReadingTimes.preferenceKey:
        BookReadingTimes.decode(jsonEncode(data));
      case 'libraryCategoriesV1':
        _keys(data, {'categories', 'defaultCategories'});
        final registry = LibraryCategoryRegistry.fromJson(data);
        for (final category in data['categories'] as List) {
          _keys(_object(category), {'name', 'update', 'download'});
        }
        if (registry.categories.length > 10000) {
          throw const FormatException('Quá nhiều danh mục.');
        }
      case 'libraryGroupOrderV1':
        _keys(data, LibraryGrouping.values.map((value) => value.name).toSet());
        for (final order in data.values) {
          _strings(order, max: 10000);
        }
      case 'libraryFilterV1':
        _keys(data, {'filter', 'sorts', 'presets'});
        void filter(Object? value) {
          final map = _object(value);
          _keys(map, const LibraryFilter().toJson().keys.toSet());
          LibraryFilter.fromJson(map);
        }
        filter(data['filter']);
        final sorts = _object(data['sorts']);
        if (sorts.length > 10000) {
          throw const FormatException('Quá nhiều thiết lập sắp xếp.');
        }
        for (final entry in sorts.entries) {
          final scope = jsonDecode(entry.key);
          if (scope is! List ||
              scope.length != 2 ||
              !LibraryGrouping.values.any((mode) => mode.name == scope.first) ||
              (scope.last != null && scope.last is! String)) {
            throw const FormatException('Phạm vi sắp xếp không hợp lệ.');
          }
          filter(entry.value);
        }
        final presets = _object(data['presets'] ?? <String, dynamic>{});
        if (presets.length > 50) {
          throw const FormatException('Quá nhiều bộ lọc thư viện đã lưu.');
        }
        for (final entry in presets.entries) {
          if (entry.key.trim().isEmpty ||
              entry.key != entry.key.trim() ||
              entry.key.length > 80) {
            throw const FormatException('Tên bộ lọc thư viện không hợp lệ.');
          }
          filter(entry.value);
        }
      case 'readerOptionsV1':
        final defaults = const ReaderOptions().toJson();
        _keys(data, defaults.keys.toSet());
        final normalized = ReaderOptions.fromJson(data).toJson();
        for (final entry in data.entries) {
          if (entry.value != normalized[entry.key]) {
            throw FormatException('Thiết lập đọc ${entry.key} không hợp lệ.');
          }
        }
      case 'savedSourceFiltersV1':
        if (utf8.encode(jsonEncode(data)).length > 1024 * 1024) {
          throw const FormatException(
            'Bộ lọc nguồn đã lưu vượt giới hạn 1 MB.',
          );
        }
        void node(Object? value) {
          final filter = _object(value);
          _keys(filter, {
            'name',
            'type',
            'supported',
            'state',
            'values',
            'children',
            'className',
          });
          if (filter['type'] == 'sort' && filter['state'] != null) {
            _keys(_object(filter['state']), {'index', 'ascending'});
          }
          if ([
                'header',
                'separator',
                'group',
                'unsupported',
              ].contains(filter['type']) &&
              filter.containsKey('state')) {
            throw const FormatException(
              'Bộ lọc không hỗ trợ trạng thái tùy ý.',
            );
          }
          for (final child in filter['children'] as List? ?? const []) {
            node(child);
          }
        }
        for (final entry in data.entries) {
          if ((!entry.key.startsWith('tachimanga:') &&
                  !entry.key.startsWith('vbook:')) ||
              entry.key.length > 2048 ||
              entry.key.endsWith(':')) {
            throw const FormatException(
              'Danh tính nguồn của bộ lọc không hợp lệ.',
            );
          }
          final presets = _object(entry.value);
          if (presets.length > 30) {
            throw const FormatException('Quá nhiều bộ lọc cho một nguồn.');
          }
          for (final preset in presets.entries) {
            if (preset.key.trim().isEmpty || preset.key.length > 80) {
              throw const FormatException('Tên bộ lọc đã lưu không hợp lệ.');
            }
            final snapshot = _object(preset.value);
            _keys(snapshot, {'schema', 'filters'});
            try {
              SourceFilterSet.fromJson(snapshot);
            } catch (_) {
              throw const FormatException(
                'Trạng thái bộ lọc nguồn đã lưu không hợp lệ.',
              );
            }
            for (final filter in snapshot['filters'] as List) {
              node(filter);
            }
          }
        }
      case 'libraryUpdatePolicyV1':
        _keys(data, {
          'hours',
          'downloadAhead',
          'skipCompleted',
          'skipUnstarted',
          'skipUnread',
          'skipEarly',
          'downloadNew',
          'wifiOnly',
          'chargingOnly',
        });
        _booleans(data, except: {'hours', 'downloadAhead'});
        if (data.containsKey('hours') &&
            ![0, 6, 12, 24, 48, 72].contains(data['hours'])) {
          throw const FormatException('Lịch cập nhật không hợp lệ.');
        }
        final ahead = data['downloadAhead'];
        if (ahead != null && (ahead is! int || ahead < 0 || ahead > 10)) {
          throw const FormatException('Số chương tải trước không hợp lệ.');
        }
      case 'downloadDeletionPolicyV1':
        _keys(data, {'afterReading', 'afterManualRead', 'protectBookmarks'});
        _booleans(data);
      case 'automaticBackupPolicyV1':
        _keys(data, {'hours', 'keep'});
        if (![0, 6, 12, 24, 48, 72].contains(data['hours']) ||
            data['keep'] is! int ||
            (data['keep'] as int) < 1 ||
            (data['keep'] as int) > 10) {
          throw const FormatException('Lịch sao lưu không hợp lệ.');
        }
      default:
        throw const FormatException('Thiết lập JSON không hợp lệ.');
    }
  }

  static void _booleans(
    Map<String, dynamic> values, {
    Set<String> except = const {},
  }) {
    if (values.entries.any(
      (entry) => !except.contains(entry.key) && entry.value is! bool,
    )) {
      throw const FormatException('Chính sách phải dùng giá trị bật/tắt.');
    }
  }

  static void _strings(Object? value, {required int max}) {
    if (value is! List ||
        value.length > max ||
        value.any(
          (item) => item is! String || item.isEmpty || item.length > 2048,
        ) ||
        value.toSet().length != value.length) {
      throw const FormatException('Danh sách thiết lập không hợp lệ.');
    }
  }

  static Map<String, dynamic> _object(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Thiết lập phải là JSON object.');
    }
    return value;
  }

  static void _keys(Map<String, dynamic> value, Set<String> allowed) {
    if (value.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Thiết lập chứa trường không được hỗ trợ.');
    }
  }
}

Object? _canonical(Object? value) {
  if (value is Map<String, dynamic>) {
    return {
      for (final key in value.keys.toList()..sort())
        key: _canonical(value[key]),
    };
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
