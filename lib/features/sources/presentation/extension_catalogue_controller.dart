import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../settings/settings_controller.dart';
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
    final repositories = <({String url, SourceEngine engine})>[];
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
      final url = ExtensionIndexRepository.normalize(
        value['url'] as String,
        engine,
      ).toString();
      if (!identities.add('${engine.name}:$url')) {
        throw const FormatException(
          'Kho đã lưu bị trùng; dữ liệu gốc được giữ nguyên.',
        );
      }
      repositories.add((url: url, engine: engine));
    }
    final result = <ExtensionIndex>[];
    for (final value in repositories) {
      try {
        result.add(
          await ref
              .read(extensionIndexRepositoryProvider)
              .fetch(value.url, value.engine),
        );
      } catch (error) {
        result.add(
          ExtensionIndex(value.url, value.engine, const [], error: '$error'),
        );
      }
    }
    return result;
  }

  Future<void> add(SourceEngine engine, String url) => _serialized(() async {
    final current = await future;
    final fetched = await ref
        .read(extensionIndexRepositoryProvider)
        .fetch(url, engine);
    final next = [
      ...current.where((item) => item.identity != fetched.identity),
      fetched,
    ];
    if (next.length > 50) {
      throw const FormatException('Tối đa 50 kho extension.');
    }
    await _save(next);
    if (ref.mounted) state = AsyncData(next);
  });

  Future<void> remove(String identity) => _serialized(() async {
    final next = (await future)
        .where((item) => item.identity != identity)
        .toList();
    await _save(next);
    if (ref.mounted) state = AsyncData(next);
  });

  Future<void> refresh() => _serialized(() async {
    final current = await future;
    final next = <ExtensionIndex>[];
    for (final item in current) {
      try {
        next.add(
          await ref
              .read(extensionIndexRepositoryProvider)
              .fetch(item.url, item.engine),
        );
      } catch (error) {
        next.add(
          ExtensionIndex(item.url, item.engine, item.entries, error: '$error'),
        );
      }
    }
    if (ref.mounted) state = AsyncData(next);
  });

  Future<void> _save(List<ExtensionIndex> items) async {
    final saved = await ref
        .read(preferencesProvider)
        .setString(
          preferenceKey,
          jsonEncode(
            items
                .map((item) => {'url': item.url, 'engine': item.engine.name})
                .toList(),
          ),
        );
    if (!saved) throw StateError('Không lưu được danh sách kho extension.');
  }
}
