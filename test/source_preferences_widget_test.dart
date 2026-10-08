import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/presentation/connection_dialog.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/source_preferences_dialog.dart';

void main() {
  testWidgets(
    'hidden preferences preserve original positions and password values are obscured',
    (tester) async {
      final requests = <Map<String, dynamic>>[];
      final repository = SourceRepository(
        tachimangaUrl: 'http://127.0.0.1:4567',
        vbookUrl: '',
        client: MockClient((request) async {
          if (request.method == 'POST') {
            requests.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response('{}', 200);
          }
          return http.Response(
            jsonEncode([
              {
                'type': 'EditTextPreference',
                'props': {
                  'visible': false,
                  'key': 'Hidden',
                  'currentValue': 'keep',
                },
              },
              {
                'type': 'EditTextPreference',
                'props': {
                  'title': 'Password',
                  'key': 'Password',
                  'currentValue': 'old-fixture-secret',
                  'enabled': true,
                },
              },
            ]),
            200,
          );
        }),
      );
      const source = CatalogueSource(
        id: '1',
        name: 'Komga fixture',
        lang: 'all',
        baseUrl: 'https://example.test',
        kind: ContentKind.manga,
        engine: SourceEngine.tachimanga,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sourceRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showSourcePreferences(context, source),
                  child: const Text('Configure'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Configure'));
      await tester.pumpAndSettle();
      expect(find.text('Hidden'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isTrue,
      );
      await tester.enterText(find.byType(TextField), 'new-fixture-secret');
      await tester.tap(find.byTooltip('Lưu Password'));
      await tester.pumpAndSettle();
      expect(requests, [
        {'position': 1, 'value': 'new-fixture-secret'},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid connection input displays an error and leaves the dialog usable',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [preferencesProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () => showConnections(context, ref),
                  child: const Text('Connect'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'ftp://invalid.example',
      );
      await tester.tap(find.text('Kiểm tra'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(prefs.getString('tachimangaUrl'), isNull);
    },
  );
}
