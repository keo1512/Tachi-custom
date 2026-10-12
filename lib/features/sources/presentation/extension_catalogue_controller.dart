import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../settings/settings_controller.dart';
import '../../library/data/coordinated_preferences.dart';
import '../data/extension_index.dart';
import '../domain/catalogue.dart';

final extensionIndexRepositoryProvider = Provider<ExtensionIndexRepository>((
  ref,
) {
  final client = http.Client();
  ref.onDispose(client.close);
  return ExtensionIndexRepository(client);
});
final extensionCatalogueProvider =
    AsyncNotifierProvider<ExtensionCatalogueController, List<ExtensionIndex>>(
      ExtensionCatalogueController.new,
      retry: (_, _) => null,
    );

class ExtensionCatalogueController extends AsyncNotifier<List<ExtensionIndex>> {
  static const preferenceKey = 'extensionRepositoriesV1';
  Future<void> _pending = Future.value();

  // Fetches can take seconds. Serialize edits so each edit sees the latest
  // saved list instead of overwriting an edit started during its HTTP request.
  Future<void> _serialized(Future<void> Function() operation) {
    final next = _pending.then((_) => operation());
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  Future<List<ExtensionIndex>> build() async {
    final raw = ref.watch(preferencesProvider).getString(preferenceKey);
    if (raw == null) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.length > 50) {
      throw const FormatException(
        'Danh sách kho đã lưu không hợp lệ; dữ liệu gốc được giữ nguyên.',
      );
    }
    final repositories = <({String url, SourceEngine engine, String label})>[];
    final identities = <String>{};
    for (final value in decoded) {
      if (value is! Map ||
          value['url'] is! String ||
          !SourceEngine.values.any((e) => e.name == value['engine'])) {
        throw const FormatException(
          'Kho đã lưu không hợp lệ; dữ liệu gốc được giữ nguyên.',
        );
      }
      final engine = SourceEngine.values.byName(value['engine'] as String);
      final label = value['name'] ?? '';
      if (label is! String ||
          label.length > 100 ||
          RegExp(r'[\x00-\x1f]').hasMatch(label)) {
        throw const FormatException(
          'Tên kho đã lưu không hợp lệ; dữ liệu gốc được giữ nguyên.',
        );
      }
      final url = ExtensionIndexRepository.normalize(
        value['url'] as String,
        engine,
      ).toString();
      if (!identities.add('${engine.name}:$url')) {
        throw const FormatException(
          'Kho đã lưu bị trùng; dữ liệu gốc được giữ nguyên.',
        );
      }
      repositories.add((url: url, engine: engine, label: label.trim()));
    }
    final result = <ExtensionIndex>[];
    for (final value in repositories) {
      try {
        result.add(
          (await ref
                  .read(extensionIndexRepositoryProvider)
                  .fetch(value.url, value.engine))
              .withLabel(value.label),
        );
      } catch (error) {
        result.add(
          ExtensionIndex(
            value.url,
            value.engine,
            const [],
            error: '$error',
            label: value.label,
          ),
        );
      }
    }
    return result;
  }

  Future<void> add(
    SourceEngine engine,
    String url, {
    bool Function()? isCurrent,
  }) => _serialized(() async {
    if (isCurrent?.call() == false) {
      throw const FormatException(
        'Thư viện hoặc thiết lập đã đổi. Hãy mở lại liên kết.',
      );
    }
    final current = await future;
    final fetched = await ref
        .read(extensionIndexRepositoryProvider)
        .fetch(url, engine);
    if (isCurrent?.call() == false) {
      throw const FormatException(
        'Thư viện hoặc thiết lập đã đổi. Hãy mở lại liên kết.',
      );
    }
    final next = [
      ...current.where((item) => item.identity != fetched.identity),
      fetched.withLabel(
        current
                .where((item) => item.identity == fetched.identity)
                .firstOrNull
                ?.label ??
            '',
      ),
    ];
    if (next.length > 50) {
      throw const FormatException('Tối đa 50 kho extension.');
    }
    await _save(next, isCurrent: isCurrent);
    if (ref.mounted) state = AsyncData(next);
  });

  Future<void> remove(String identity) => _serialized(() async {
    final next = (await future)
        .where((item) => item.identity != identity)
        .toList();
    await _save(next);
    if (ref.mounted) state = AsyncData(next);
  });

  Future<void> rename(String identity, String name) => _serialized(() async {
    final label = name.trim();
    if (label.length > 100 || RegExp(r'[\x00-\x1f]').hasMatch(label)) {
      throw const FormatException(
        'Tên kho tối đa 100 ký tự, không có ký tự điều khiển.',
      );
    }
    final current = await future;
    if (!current.any((item) => item.identity == identity)) {
      throw StateError('Kho không còn trong danh sách.');
    }
    final next = [
      for (final item in current)
        item.identity == identity ? item.withLabel(label) : item,
    ];
    await _save(next);
    if (ref.mounted) state = AsyncData(next);
  });

  Future<void> refresh() => _serialized(() async {
    final current = await future;
    final next = <ExtensionIndex>[];
    for (final item in current) {
      try {
        next.add(
          (await ref
                  .read(extensionIndexRepositoryProvider)
                  .fetch(item.url, item.engine))
              .withLabel(item.label),
        );
      } catch (error) {
        next.add(
          ExtensionIndex(
            item.url,
            item.engine,
            item.entries,
            error: '$error',
            name: item.name,
            label: item.label,
          ),
        );
      }
    }
    if (ref.mounted) state = AsyncData(next);
  });

  Future<void> _save(
    List<ExtensionIndex> items, {
    bool Function()? isCurrent,
  }) async {
    final preferences = ref.read(preferencesProvider);
    final raw = jsonEncode(
      items
          .map(
            (item) => {
              'url': item.url,
              'engine': item.engine.name,
              if (item.label.isNotEmpty) 'name': item.label,
            },
          )
          .toList(),
    );
    final saved = preferences is CoordinatedPreferences && isCurrent != null
        ? await preferences.setStringIfCurrent(preferenceKey, raw, isCurrent)
        : await preferences.setString(preferenceKey, raw);
    if (!saved) throw StateError('Không lưu được danh sách kho extension.');
  }
}
