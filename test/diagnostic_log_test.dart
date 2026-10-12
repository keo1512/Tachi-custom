import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/diagnostics/diagnostic_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<DiagnosticLogStore> open({bool Function()? canRecord}) async {
    final store = DiagnosticLogStore(
      await SharedPreferences.getInstance(),
      canRecord: canRecord,
    );
    addTearDown(store.dispose);
    return store;
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'raw exception secrets never enter persisted or exported diagnostic events',
    () async {
      final store = await open();
      await store.record(
        DiagnosticEvent.error(
          'source',
          StateError(
            'HTTP 403 https://private.example cookie=secret user@example.com PrivateBook',
          ),
        ),
      );
      await store.record(
        DiagnosticEvent.error(
          'backup',
          const FormatException('private path token=secret'),
        ),
      );
      final exported = utf8.decode(store.export());
      expect(exported, contains('http_403'));
      for (final secret in [
        'private.example',
        'cookie=',
        'secret',
        '@',
        'PrivateBook',
        'private path',
      ]) {
        expect(exported, isNot(contains(secret)));
      }
      expect(store.read()[1].code, 'invalid_data');
      expect(
        store.read()[1].message,
        DiagnosticEvent.safeMessage('invalid_data'),
      );
    },
  );
  test('persisted untrusted messages are canonicalized and invalid code bytes stay untouched', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      DiagnosticLogStore.key,
      jsonEncode({
        'version': 1,
        'entries': [
          {
            'category': 'sync',
            'code': 'operation_failed',
            'message': 'user@example.com cookie=secret',
            'at': '2026-10-12T01:00:00Z',
          },
        ],
      }),
    );
    final store = await open();
    expect(utf8.decode(store.export()), isNot(contains('secret')));
    final invalid = jsonEncode({
      'version': 1,
      'entries': [
        {
          'category': 'sync',
          'code': 'private_token_secret',
          'message': 'secret',
          'at': 'invalid',
        },
      ],
    });
    await preferences.setString(DiagnosticLogStore.key, invalid);
    expect(store.read, throwsFormatException);
    expect(store.export, throwsFormatException);
    await expectLater(
      store.record(DiagnosticEvent.error('app', TimeoutException('secret'))),
      throwsFormatException,
    );
    expect(preferences.getString(DiagnosticLogStore.key), invalid);
  });
  test('serial log writes keep newest 100 events and suppress repeated same error for a minute', () async {
    final store = await open();
    final start = DateTime.utc(2026, 10, 12);
    final writes = [
      for (var i = 0; i < 110; i++)
        store.record(
          DiagnosticEvent(
            'download',
            'operation_failed',
            'untrusted',
            start.add(Duration(minutes: i)),
          ),
        ),
    ];
    await Future.wait(writes);
    expect(store.read(), hasLength(100));
    expect(store.read().first.at, start.add(const Duration(minutes: 10)));
    final last = start.add(const Duration(minutes: 109));
    await store.record(
      DiagnosticEvent(
        'download',
        'operation_failed',
        'repeat',
        last.add(const Duration(seconds: 59)),
      ),
    );
    expect(store.read().last.at, last);
    await store.record(
      DiagnosticEvent(
        'download',
        'operation_failed',
        'next',
        last.add(const Duration(seconds: 60)),
      ),
    );
    expect(store.read().last.at, last.add(const Duration(seconds: 60)));
    expect(store.export().length, lessThan(DiagnosticLogStore.maxBytes));
  });
  test(
    'privacy and lock gates are rechecked when queued write executes',
    () async {
      var allowed = true;
      final store = await open(canRecord: () => allowed);
      final work = store.record(
        DiagnosticEvent.error('app', StateError('secret')),
      );
      allowed = false;
      await work;
      expect(store.read(), isEmpty);
      allowed = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('incognitoMode', true);
      await store.record(DiagnosticEvent.error('app', StateError('secret')));
      expect(store.read(), isEmpty);
      await prefs.setBool('incognitoMode', false);
      await store.record(DiagnosticEvent.error('app', StateError('secret')));
      expect(store.read(), hasLength(1));
    },
  );
  test(
    'confirmed clear recovers invalid log data and new writes still work',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final invalid = 'x' * (DiagnosticLogStore.maxBytes + 1);
      await prefs.setString(DiagnosticLogStore.key, invalid);
      final store = await open();
      expect(store.export, throwsFormatException);
      expect(prefs.getString(DiagnosticLogStore.key), invalid);
      await store.clear();
      await store.record(
        DiagnosticEvent.error('background', TimeoutException('secret')),
      );
      expect(store.read().single.category, 'background');
      expect(prefs.getString(DiagnosticLogStore.key), isNot(invalid));
    },
  );
}
