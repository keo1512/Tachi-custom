import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/book_detail_header.dart';
import 'package:tachi_books/features/library/presentation/book_detail_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/deep_links/domain/app_deep_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final reading in [false, true]) {
    testWidgets(
      'copy title or current chapter link resolves stable identity reading=$reading',
      (tester) async {
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final fixture = await _mount(
          tester,
          const Size(320, 568),
          Brightness.dark,
        );
        final fingerprint = (await fixture.repository.snapshot()).fingerprint;
        await tester.tap(find.byTooltip('Tùy chọn'));
        await tester.pumpAndSettle();
        final action = find.text(
          reading
              ? 'Sao chép liên kết chương đang đọc'
              : 'Sao chép liên kết TachiBooks',
        );
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.tap(action);
        await tester.pumpAndSettle();
        final link = AppDeepLink.parse(copied!)! as LibraryDeepLink;
        expect(link.bookId, fixture.book.id);
        expect(link.reader, reading);
        expect(
          link.chapterId,
          reading
              ? fixture.book.chapters[fixture.book.currentChapter].id
              : null,
        );
        expect((await fixture.repository.snapshot()).fingerprint, fingerprint);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
  for (final action in [
    'completed',
    'collection',
    'notes',
    'remove',
    'download',
  ]) {
    testWidgets(
      'a stale $action popup cannot change the restored book or queue',
      (tester) async {
        final fixture = await _mount(
          tester,
          const Size(430, 932),
          Brightness.dark,
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(BookDetailScreen)),
        );
        await tester.tap(
          find.byTooltip(action == 'download' ? 'Tải chương' : 'Tùy chọn'),
        );
        await tester.pumpAndSettle();
        if (action == 'collection' || action == 'notes' || action == 'remove') {
          await tester.ensureVisible(
            find.text(switch (action) {
              'collection' => 'Đổi bộ sưu tập',
              'notes' => 'Ghi chú cá nhân',
              _ => 'Xóa khỏi thư viện',
            }),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(switch (action) {
              'collection' => 'Đổi bộ sưu tập',
              'notes' => 'Ghi chú cá nhân',
              _ => 'Xóa khỏi thư viện',
            }),
          );
          await tester.pumpAndSettle();
          if (action != 'remove') {
            await tester.enterText(
              find.byType(CupertinoTextField),
              'Stale edit',
            );
          }
        }
        final replacement = fixture.book.copyWith(
          title: 'Restored title',
          collection: 'Restored shelf',
          notes: 'Restored notes',
        );
        await fixture.repository.clear();
        await fixture.repository.save(replacement);
        await container.read(libraryProvider.notifier).refresh();
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.text(switch (action) {
            'completed' => 'Đánh dấu hoàn thành',
            'collection' || 'notes' => 'Lưu',
            'remove' => 'Xóa',
            _ => 'Tất cả chương chưa tải',
          }),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(switch (action) {
            'completed' => 'Đánh dấu hoàn thành',
            'collection' || 'notes' => 'Lưu',
            'remove' => 'Xóa',
            _ => 'Tất cả chương chưa tải',
          }),
        );
        await tester.pumpAndSettle();
        expect(
          (await fixture.repository.find(replacement.id))!.toJson(),
          replacement.toJson(),
        );
        expect(container.read(downloadQueueProvider).tasks, isEmpty);
        expect(
          find.textContaining('Thư viện đã được thay đổi hoặc khôi phục'),
          findsOneWidget,
        );
        expect(find.byType(BookDetailScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
  for (final size in const [Size(320, 568), Size(430, 932)]) {
    for (final brightness in Brightness.values) {
      testWidgets('cover-backed details respect $brightness and $size', (
        tester,
      ) async {
        final fixture = await _mount(tester, size, brightness);
        expect(
          find.byKey(const ValueKey('book-detail-background')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('book-detail-cover')), findsOneWidget);
        final rawImages = tester.widgetList<RawImage>(
          find.descendant(
            of: find.byType(BookDetailHeader),
            matching: find.byType(RawImage),
          ),
        );
        expect(rawImages.where((image) => image.image != null), hasLength(2));
        final coverSize = tester.getSize(
          find.byKey(const ValueKey('book-detail-cover')),
        );
        expect(coverSize.width, lessThan(size.width * .35));
        expect(coverSize.height / coverSize.width, closeTo(1.43, .001));
        expect(find.text('Trong thư viện'), findsOneWidget);
        expect(find.text('Theo dõi'), findsNothing);
        expect(find.text('Đang tiến hành'), findsNothing);
        expect(find.text('Họa sĩ: Họa sĩ mẫu'), findsOneWidget);
        final scaffold = tester.widget<Scaffold>(
          find.descendant(
            of: find.byType(BookDetailScreen),
            matching: find.byType(Scaffold),
          ),
        );
        expect(scaffold.extendBodyBehindAppBar, isTrue);
        await tester.scrollUntilVisible(
          find.widgetWithText(ListTile, 'Chương cuối'),
          150,
          scrollable: find
              .descendant(
                of: find
                    .descendant(
                      of: find.byType(BookDetailScreen),
                      matching: find.byType(ListView),
                    )
                    .first,
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        final unreadTitle = tester.widget<Text>(
          find.descendant(
            of: find.widgetWithText(ListTile, 'Chương cuối'),
            matching: find.text('Chương cuối'),
          ),
        );
        expect(
          unreadTitle.style!.color,
          Theme.of(tester.element(find.byType(BookDetailScreen)))
              .colorScheme
              .onSurface,
        );
        tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find
                        .descendant(
                          of: find.byType(BookDetailScreen),
                          matching: find.byType(ListView),
                        )
                        .first,
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        final description = tester.widget<Text>(
          find.byKey(const ValueKey('book-detail-description')),
        );
        expect(description.maxLines, 3);
        await tester.ensureVisible(find.byTooltip('Mở rộng giới thiệu'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Mở rộng giới thiệu'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('book-detail-description')),
              )
              .maxLines,
          isNull,
        );
        await tester.ensureVisible(find.byTooltip('Thu gọn giới thiệu'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Thu gọn giới thiệu'));
        await tester.pumpAndSettle();
        expect(
          (await fixture.repository.find(fixture.book.id))!.toJson(),
          fixture.book.toJson(),
        );
        expect(
          tester
              .widgetList<RawImage>(
                find.descendant(
                  of: find.byType(BookDetailHeader),
                  matching: find.byType(RawImage),
                ),
              )
              .where((image) => image.image != null),
          hasLength(2),
        );
        if (size.width == 430) {
          final scroll = tester.state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          scroll.position.jumpTo(0);
          await tester.pumpAndSettle();
          await _savePreview(tester, brightness);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets(
    'details copy the actual source address and keep favorite behavior',
    (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final fixture = await _mount(
        tester,
        const Size(320, 568),
        Brightness.dark,
      );
      expect(
        find.widgetWithText(SelectableText, fixture.book.sourceRef),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Sao chép địa chỉ nguồn'));
      await tester.pumpAndSettle();
      expect(copied, fixture.book.sourceRef);
      await Scrollable.ensureVisible(
        tester.element(find.text('Yêu thích')),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yêu thích'));
      await tester.pumpAndSettle();
      expect(
        (await fixture.repository.find(fixture.book.id))!.toJson(),
        fixture.book.copyWith(favorite: true).toJson(),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'new chapter toolbar sorts and filters without changing original route indexes',
    (tester) async {
      final fixture = await _mount(
        tester,
        const Size(430, 932),
        Brightness.dark,
      );
      await tester.ensureVisible(find.byTooltip('Chương mới trước'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Chương mới trước'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lọc và sắp xếp chương'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<String>),
          matching: find.text('Đã tải'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      final tiles = find.descendant(
        of: find.byType(BookDetailScreen),
        matching: find.byType(ListTile),
      );
      expect(
        tester
            .widgetList<ListTile>(tiles)
            .map((tile) => (tile.title as Text).data),
        ['Chương cuối', 'Chương đầu'],
      );
      expect(
        (await fixture.repository.find(fixture.book.id))!
            .copyWith(chapterListPreferences: const {})
            .toJson(),
        fixture.book.copyWith(chapterListPreferences: const {}).toJson(),
      );
      final last = find.widgetWithText(ListTile, 'Chương cuối');
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(find.text('Original chapter: 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

Future<({MemoryLibraryRepository repository, LibraryBook book})> _mount(
  WidgetTester tester,
  Size size,
  Brightness brightness,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final cover = await tester.runAsync(_cover);
  await tester.runAsync(() async {
    final font = FontLoader('NotoSans')
      ..addFont(rootBundle.load('assets/fonts/notosans.ttf'));
    await font.load();
    for (final family in ['CupertinoSystemText', 'CupertinoSystemDisplay']) {
      final cupertinoFont = FontLoader(family)
        ..addFont(rootBundle.load('assets/fonts/notosans.ttf'));
      await cupertinoFont.load();
    }
    final icons = FontLoader('packages/cupertino_icons/CupertinoIcons')
      ..addFont(
        rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      );
    await icons.load();
  });
  final book = LibraryBook(
    id: 'detail-layout',
    title: 'Một câu chuyện dành cho những ngày bình yên',
    author: 'Tác giả mẫu',
    artist: 'Họa sĩ mẫu',
    cover: cover!,
    engine: 'vbook',
    sourceId: 'sample-source',
    sourceRef: 'https://example.test/truyen/mot-cau-chuyen',
    currentChapter: 1,
    progress: .5,
    lastRead: DateTime(2026, 10, 10),
    bookmarks: const ['1:0.5000'],
    genres: const ['Đời thường', 'Phiêu lưu', 'Học đường'],
    description: List.filled(
      8,
      'Linh tìm thấy một cuốn sách và bắt đầu chuyến đi qua những câu chuyện của thành phố.',
    ).join(' '),
    chapters: const [
      BookChapter(
        id: 'original-a',
        title: 'Chương đầu',
        index: 0,
        downloaded: true,
        read: true,
      ),
      BookChapter(
        id: 'original-b',
        title: 'Chương giữa',
        index: 1,
        read: false,
      ),
      BookChapter(
        id: 'original-c',
        title: 'Chương cuối',
        index: 2,
        downloaded: true,
        read: false,
      ),
    ],
  );
  final repository = MemoryLibraryRepository();
  await repository.save(book);
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: '/book/${book.id}',
    routes: [
      GoRoute(
        path: '/book/:id',
        builder: (_, state) =>
            BookDetailScreen(id: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/read/:id',
        builder: (_, state) => Scaffold(
          body: Text(
            'Original chapter: ${state.uri.queryParameters['chapter']}',
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        preferencesProvider.overrideWithValue(preferences),
      ],
      child: RepaintBoundary(
        key: const ValueKey('detail-preview'),
        child: MaterialApp.router(
          theme: appTheme(brightness).copyWith(
            textTheme: appTheme(brightness).textTheme
                .apply(fontFamily: 'NotoSans'),
            listTileTheme: appTheme(brightness).listTileTheme.copyWith(
              titleTextStyle: const TextStyle(fontFamily: 'NotoSans'),
            ),
          ),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => precacheImage(
      MemoryImage(base64Decode(cover.substring(cover.indexOf(',') + 1))),
      tester.element(find.byType(BookDetailScreen)),
    ),
  );
  await tester.pumpAndSettle();
  return (repository: repository, book: book);
}

Future<String> _cover() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 120, 172),
    Paint()..color = const Color(0xFF54798F),
  );
  canvas.drawRect(
    const Rect.fromLTWH(14, 12, 92, 148),
    Paint()..color = const Color(0xFFAFC4FF),
  );
  canvas.drawCircle(
    const Offset(60, 64),
    28,
    Paint()..color = const Color(0xFFFFDEB0),
  );
  canvas.drawRect(
    const Rect.fromLTWH(22, 108, 76, 32),
    Paint()..color = const Color(0xFF304255),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(120, 172);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final output = File('artifacts/book-detail-fixture-cover.png');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(data!.buffer.asUint8List(), flush: true);
    return 'data:image/png;base64,${base64Encode(data.buffer.asUint8List())}';
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<void> _savePreview(WidgetTester tester, Brightness brightness) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('detail-preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File('artifacts/book-detail-${brightness.name}-430.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(data!.buffer.asUint8List(), flush: true);
    } finally {
      image.dispose();
    }
  });
}
