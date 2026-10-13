import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/diagnostics/diagnostic_log.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

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
  test('native diagnostic types survive storage and different failures do not coalesce', () async {
    final store = await open();
    for (final type in [
      'NoSuchMethodError',
      'NoClassDefFoundError',
      'NoSuchMethodError',
    ]) {
      await store.record(
        DiagnosticEvent.error(
          'source',
          ApiException(
            'private token=secret',
            code: 'unsupported_extension',
            diagnosticType: type,
          ),
        ),
      );
    }
    expect(store.read().map((event) => event.type), [
      'NoSuchMethodError',
      'NoClassDefFoundError',
    ]);
    final data = jsonDecode(utf8.decode(store.export())) as Map;
    expect(data['version'], 1);
    expect(data['appVersion'], '1.0.0+9');
    expect((data['entries'] as List).map((entry) => entry['type']), [
      'NoSuchMethodError',
      'NoClassDefFoundError',
    ]);
    expect(utf8.decode(store.export()), isNot(contains('secret')));
  });
  test('unknown exception types are discarded on record and legacy or tampered export', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      DiagnosticLogStore.key,
      jsonEncode({
        'version': 1,
        'entries': [
          for (final type in [
            null,
            'NoSuchMethodError',
            'PrivateBook token=secret',
            {'private': 'secret'},
          ])
            {
              'category': 'source',
              'code': 'source_api_unsupported',
              'message': 'private',
              'at': '2026-10-12T01:00:00Z',
              'type': ?type,
            },
        ],
      }),
    );
    final store = await open();
    expect(store.read().map((event) => event.type), [
      null,
      'NoSuchMethodError',
      null,
      null,
    ]);
    expect(utf8.decode(store.export()), isNot(contains('secret')));
    await store.record(
      DiagnosticEvent.error(
        'source',
        const ApiException(
          'secret',
          code: 'extension_failed',
          diagnosticType: 'private_token_secret',
        ),
      ),
    );
    expect(store.read().last.type, isNull);
    expect(store.read().last.toJson().containsKey('type'), false);
  });
  test('Firebase permission and authentication errors keep distinct canonical codes', () async {
    final store = await open();
    for (final entry in {
      'permission-denied': 'sync_permission_denied',
      'operation-not-allowed': 'auth_provider_disabled',
      'unauthenticated': 'auth_session_expired',
      'resource-exhausted': 'sync_quota_exhausted',
      'unavailable': 'sync_network_unavailable',
    }.entries) {
      await store.record(
        DiagnosticEvent.error(
          'sync',
          FirebaseException(
            plugin: 'cloud_firestore',
            code: entry.key,
            message: 'PrivateAccount user@example.test token=secret',
          ),
        ),
      );
      expect(store.read().last.code, entry.value);
      expect(store.read().last.type, 'FirebaseException');
    }
    final output = utf8.decode(store.export());
    expect(output, isNot(contains('secret')));
    expect(output, isNot(contains('user@')));
    expect(output, isNot(contains('PrivateAccount')));
  });
  test('native source codes survive logging without extension messages or arbitrary codes', () async {
    final store = await open();
    final codes = {
      'source_requires_browser': 'source_browser_required',
      'unsupported_extension': 'source_api_unsupported',
      'engine_unavailable': 'source_engine_unavailable',
      'extension_failed': 'source_operation_failed',
      'invalid_request': 'source_invalid_request',
      'RESTORED_TITLE_UNRESOLVED': 'source_title_unresolved',
      'CHAPTER_IDENTITY_CHANGED': 'source_chapter_unresolved',
      'TIMEOUT': 'timeout',
    };
    for (final entry in codes.entries) {
      await store.record(
        DiagnosticEvent.error(
          'source',
          ApiException(
            'PrivateBook https://private.test/path?token=secret user@example.test',
            code: entry.key,
          ),
        ),
      );
    }
    await store.record(
      DiagnosticEvent.error(
        'source',
        const ApiException('private message', statusCode: 429),
      ),
    );
    await store.record(
      DiagnosticEvent.error(
        'source',
        const ApiException('secret', code: 'private_token_secret'),
      ),
    );
    expect(store.read().map((entry) => entry.code), [
      ...codes.values,
      'http_429',
      'operation_failed',
    ]);
    final output = utf8.decode(store.export());
    for (final private in [
      'PrivateBook',
      'private.test',
      'token=',
      'secret',
      'user@',
    ]) {
      expect(output, isNot(contains(private)));
    }
    for (final entry in store.read()) {
      expect(entry.message, DiagnosticEvent.safeMessage(entry.code));
    }
  });
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
