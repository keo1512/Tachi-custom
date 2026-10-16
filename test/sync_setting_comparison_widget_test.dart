import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/backup_validation.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/sync/application/sync_controller.dart';
import 'package:tachi_books/features/sync/data/google_session.dart';
import 'package:tachi_books/features/sync/presentation/sync_merge_screen.dart';
import 'package:tachi_books/features/sync/presentation/sync_setting_comparison.dart';

import 'support/sync_fakes.dart';

class _LibraryLocal extends FakeSyncLocal {
  _LibraryLocal(Uint8List value) : super(bytes: value);
  @override
  void validate(Uint8List bytes) =>
      BackupService(MemoryLibraryRepository()).validate(bytes);
}

Widget _app(Widget child) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(1.5)),
    child: child!,
  ),
  home: child,
);

void main() {
  testWidgets(
    'structured settings stay bounded and detailed choices survive cancel at 320px',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sources = List.generate(
        9000,
        (index) => 'tachimanga:$index:${'a' * 180}',
      );
      final cloudSources = [...sources]..[8999] = 'vbook:nguon-cuoi-tren-cloud';
      Uint8List image(int hours, int keep, List<String> pinned) =>
          LibrarySnapshot(
            [],
            configuration: BackupConfiguration.fromJson({
              'version': 1,
              'preferences': {
                'automaticBackupPolicyV1': jsonEncode({
                  'hours': hours,
                  'keep': keep,
                }),
                'pinnedSources': pinned,
              },
            }),
          ).encode();
      final local = _LibraryLocal(image(6, 2, sources));
      final remote = FakeSyncRemote()..seed(image(12, 6, cloudSources));
      final container = ProviderContainer(
        overrides: [
          syncAuthProvider.overrideWithValue(
            FakeSyncAuth()..user = const SyncUser(uid: 'alice'),
          ),
          syncLocalProvider.overrideWithValue(local),
          syncRemoteFactoryProvider.overrideWithValue((_) => remote),
        ],
      );
      addTearDown(container.dispose);
      await container.read(syncProvider.notifier).resume();
      await container.read(syncProvider.notifier).sync(enable: true);
      final conflict = container.read(syncProvider.notifier).pendingConflict!;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(SyncMergeScreen(conflict: conflict)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Chu kỳ tự động: 6 giờ'), findsOneWidget);
      expect(find.textContaining('Chu kỳ tự động: 12 giờ'), findsOneWidget);
      expect(find.textContaining('{"hours"'), findsNothing);
      // Main preview never lays out the thousands of source identities.
      expect(find.textContaining(sources.last), findsNothing);
      await tester.ensureVisible(find.text('Xem đầy đủ').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xem đầy đủ').first);
      await tester.pumpAndSettle();
      expect(find.text('Trên máy: 6 giờ'), findsOneWidget);
      expect(find.text('Trên cloud: 12 giờ'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Số bản');
      await tester.pumpAndSettle();
      expect(find.text('Trên máy: 2 bản sao lưu'), findsOneWidget);
      expect(find.text('Trên cloud: 6 bản sao lưu'), findsOneWidget);
      expect(find.text('Chu kỳ tự động'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Giữ trên cloud').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Giữ trên cloud').first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Thiết lập: Nguồn đã ghim'),
        100,
      );
      await tester.ensureVisible(find.text('Xem đầy đủ').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xem đầy đủ').last);
      await tester.pumpAndSettle();
      expect(find.text('Mục 9000'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Mục 9000');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SelectableText, 'Mục 9000'), findsOneWidget);
      expect(
        find.text('Trên cloud: vbook:nguon-cuoi-tren-cloud'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Mở mục'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mở mục'));
      await tester.pumpAndSettle();
      expect(find.text(sources.last), findsOneWidget);
      expect(find.text('vbook:nguon-cuoi-tren-cloud'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Giữ trên cloud').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Giữ trên cloud').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Hợp nhất và đồng bộ'), 100);
      await tester.ensureVisible(find.text('Hợp nhất và đồng bộ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hợp nhất và đồng bộ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(local.replaces, 0);
      expect(remote.publishes, 0);
      await tester.tap(find.text('Hợp nhất và đồng bộ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hợp nhất'));
      await tester.pumpAndSettle();
      final restored = BackupValidator(MemoryLibraryRepository())
          .validateSnapshot(local.bytes);
      expect(
        jsonDecode(
          restored.configuration!.values['automaticBackupPolicyV1'] as String,
        ),
        {'hours': 12, 'keep': 6},
      );
      expect(
        (restored.configuration!.values['pinnedSources'] as List).last,
        cloudSources.last,
      );
      expect(local.replaces, 1);
      expect(remote.publishes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nested public JSON with whitespace opens readable fields', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String value(String name) =>
        ' \n${jsonEncode({
          'categories': [
            {'name': name, 'update': 'include', 'download': 'exclude'},
          ],
          'defaultCategories': <String>[],
        })}';
    final config = BackupConfiguration.fromJson({
      'version': 1,
      'preferences': {'libraryCategoriesV1': value('Trên máy')},
    });
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SyncSettingComparison(
              settingKey: 'libraryCategoriesV1',
              label: 'Danh mục truyện',
              local: config.values['libraryCategoriesV1'],
              remote: value('Trên cloud'),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('Danh mục: 1 mục'), findsNWidgets(2));
    await tester.tap(find.text('Xem đầy đủ'));
    await tester.pumpAndSettle();
    expect(find.text('Danh mục'), findsOneWidget);
    await tester.ensureVisible(find.text('Mở mục').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mở mục').first);
    await tester.pumpAndSettle();
    expect(find.text('Mục 1'), findsOneWidget);
    await tester.ensureVisible(find.text('Mở mục'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mở mục'));
    await tester.pumpAndSettle();
    expect(find.text('Tên'), findsOneWidget);
    expect(find.text('Trên máy: Trên máy'), findsOneWidget);
    expect(find.text('Trên cloud: Trên cloud'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail search stays reachable in landscape with keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(568, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SyncSettingComparison(
              settingKey: 'automaticBackupPolicyV1',
              label: 'Sao lưu tự động',
              local: jsonEncode({'hours': 6, 'keep': 2}),
              remote: jsonEncode({'hours': 12, 'keep': 6}),
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('Xem đầy đủ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xem đầy đủ'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 160);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Số bản');
    await tester.pumpAndSettle();
    expect(find.text('Trên cloud: 6 bản sao lưu'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
