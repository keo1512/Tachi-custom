import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/browse_widgets.dart';

void main() {
  testWidgets(
    'network icon failure keeps the 38px source icon and actions usable at 320px',
    (tester) async {
      final requested = <Uri>[];
      debugNetworkImageHttpClientProvider = () => _FailingIconClient(requested);
      addTearDown(() => debugNetworkImageHttpClientProvider = null);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.reset);
      final actions = <String>[];
      const source = CatalogueSource(
        id: '9007199254740995',
        name: 'Source with a long title',
        lang: 'vi',
        baseUrl: 'https://source.test',
        kind: ContentKind.manga,
        engine: SourceEngine.tachimanga,
        iconUrl: 'https://runtime.test/api/v1/extension/icon/fixture',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                SourceBrowseRow(
                  source: source,
                  pinned: false,
                  onOpen: () => actions.add('open'),
                  onPin: () => actions.add('pin'),
                  onInfo: () => actions.add('info'),
                  onPreferences: () => actions.add('preferences'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requested, [Uri.parse(source.iconUrl)]);
      expect(
        find.byKey(const ValueKey('source-icon-placeholder')),
        findsOneWidget,
      );
      expect(tester.getSize(find.byType(ClipRRect)), const Size(38, 38));
      final provider = tester.widget<Image>(find.byType(Image)).image;
      expect(provider, isA<ResizeImage>());
      expect((provider as ResizeImage).width, 114);
      expect(provider.height, 114);
      for (final label in [
        'Cấu hình ${source.name}',
        'Ghim ${source.name}',
        'Thông tin ${source.name}',
      ]) {
        await tester.tap(find.byTooltip(label));
        await tester.pump();
      }
      await tester.tap(find.text(source.name));
      expect(actions, ['preferences', 'pin', 'info', 'open']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugNetworkImageHttpClientProvider = null;
    },
  );

  testWidgets(
    'sources without a returned icon use a placeholder without a network image',
    (tester) async {
      const source = CatalogueSource(
        id: 'novel',
        name: 'Novel source',
        lang: 'vi',
        baseUrl: 'https://source.test',
        kind: ContentKind.novel,
        engine: SourceEngine.vbook,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourceBrowseRow(
              source: source,
              pinned: false,
              onOpen: () {},
              onPin: () {},
              onInfo: () {},
            ),
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(CupertinoIcons.book), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _FailingIconClient extends Fake implements HttpClient {
  _FailingIconClient(this.requested);
  final List<Uri> requested;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested.add(url);
    throw const SocketException('Fixture icon unavailable');
  }
}
