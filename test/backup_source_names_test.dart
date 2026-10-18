import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/source_migration_library_screen.dart';
import 'package:tachi_books/features/sources/presentation/source_migration_view.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_source_label.dart';
import 'package:tachi_books/features/sources/data/extension_index.dart';
import 'package:tachi_books/features/sources/presentation/extension_catalogue_controller.dart';

class _NoRepositories extends ExtensionCatalogueController {
  @override
  Future<List<ExtensionIndex>> build() async => [];
}

class _NoInstalledSources extends SourceRepository {
  _NoInstalledSources() : super(tachimangaUrl: '', vbookUrl: '');
  @override
  Future<List<CatalogueSource>> listSources(SourceEngine engine) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'migration source groups and individual rows retain offline backup source names',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = MemoryLibraryRepository();
      await repository.save(
        LibraryBook(
          id: 'fixture',
          title: 'Fixture',
          kind: 'manga',
          engine: 'tachimanga',
          sourceId: '8222087175453285202',
          sourceName: 'Nguồn Tachimanga',
          sourceRef: '/fixture',
        ),
      );
      final sources = _NoInstalledSources();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          libraryRepositoryProvider.overrideWithValue(repository),
          sourceRepositoryProvider.overrideWithValue(sources),
          extensionCatalogueProvider.overrideWith(_NoRepositories.new),
        ],
      );
      addTearDown(() {
        container.dispose();
        sources.dispose();
      });
      await tester.runAsync(
        () => container.read(bundledSourceNamesProvider.future),
      );
      for (final child in <Widget>[
        const SourceMigrationLibraryScreen(),
        SourceMigrationView(
          sources: const [],
          onOpenSource: (_) async {},
          query: '',
        ),
      ]) {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(home: Scaffold(body: child)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('CuuTruyen'), findsOneWidget);
        expect(find.text('Nguồn Tachimanga'), findsNothing);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('backup names work offline with no installed extensions', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        extensionCatalogueProvider.overrideWith(_NoRepositories.new),
        librarySourceNamesProvider.overrideWith((_) async => {}),
      ],
    );
    addTearDown(container.dispose);
    final names = (await tester.runAsync(
      () => container.read(bundledSourceNamesProvider.future),
    ))!;
    expect(names.length, greaterThan(2000));
    const known = {
      '823638192569572166': 'CBHentai',
      '8222087175453285202': 'CuuTruyen',
      '2558772350527638641': 'MiMi',
      '8070257113818912648': 'MiMiHentai',
      '4572372176917567711': 'VinaHentai',
      '6495630445796108150': 'LXManga',
      '8689080191405841403': 'MoeTruyen',
      '4004369226840135398': 'ViHentai',
    };
    final books = [
      for (final id in known.keys)
        LibraryBook(
          id: id,
          title: 'Fixture',
          engine: 'tachimanga',
          sourceId: id,
          sourceName: 'Nguồn Tachimanga',
          sourceRef: '/fixture',
        ),
    ];
    final before = books.map((b) => b.toJson()).toList();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Column(
              children: [
                for (final book in books)
                  Text(resolvedLibrarySourceLabel(ref, book)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final entry in known.entries) {
      expect(names['tachimanga:${entry.key}'], entry.value);
      expect(find.text(entry.value), findsOneWidget);
    }
    expect(find.text('Nguồn Tachimanga'), findsNothing);
    expect(books.map((b) => b.toJson()).toList(), before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'preserved backup names win; unknown and cross-engine IDs stay honest',
    () {
      final book = LibraryBook(
        id: 'b',
        title: 'Fixture',
        engine: 'tachimanga',
        sourceId: '42',
        sourceName: 'Nguồn riêng đã ngừng hoạt động',
        sourceRef: '/fixture',
      );
      const names = {'tachimanga:42': 'New name', 'vbook:42': 'Novel source'};
      expect(librarySourceLabel(book, names: names), book.sourceName);
      for (final value in ['', '42', 'Nguồn Tachimanga', 'nguồn tachimanga']) {
        expect(
          librarySourceLabel(book.copyWith(sourceName: value), names: names),
          'New name',
        );
      }
      expect(
        librarySourceLabel(
          book.copyWith(sourceName: '', engine: 'vbook'),
          names: names,
        ),
        'Novel source',
      );
      expect(
        librarySourceLabel(
          book.copyWith(sourceName: '', sourceId: '999'),
          names: names,
        ),
        'Nguồn chưa xác định · 999',
      );
      expect(
        librarySourceLabel(
          book.copyWith(
            sourceName: '',
            sourceId: '999',
            sourceRef: 'https://retired.example/book',
          ),
          names: names,
        ),
        'retired.example',
      );
      expect(
        librarySourceLabel(book.copyWith(engine: 'local'), names: names),
        'Trong thiết bị',
      );
    },
  );
}
