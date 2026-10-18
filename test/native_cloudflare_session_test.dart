import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

const source = CatalogueSource(
  id: '9223372036854775806',
  name: 'Fixture',
  lang: 'vi',
  baseUrl: 'https://fixture.test',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tachi-clearance-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  for (final response in [
    'verified',
    'cancelled',
    'unverified',
    'wrong-origin',
    'repeated',
    'cleared',
    'cleared-with-cookies',
  ]) {
    test(
      'challenge recovery handles $response without recursive retries',
      () async {
        var searches = 0, browsers = 0, sessions = 0;
        final requests = <Map<String, dynamic>>[];
        final repo = NativeTachiRepository(
          storageDirectory: directory,
          automaticallyVerifyChallenges: true,
          sessionBrowser: (options) async {
            browsers++;
            expect(options['automatic'], true);
            expect((options['seed'] as Map)['seedToken'], 'fixture-token');
            return {
              'url': response == 'wrong-origin'
                  ? 'https://other.test/'
                  : options['url'],
              'userAgent': 'FixtureBrowser/1',
              'cookies': response == 'cleared-with-cookies'
                  ? [
                      {'name': 'unexpected', 'value': 'not-a-logout'},
                    ]
                  : [],
              'verified': response == 'verified' || response == 'repeated',
              'cancelled': response == 'cancelled',
              if (response.startsWith('cleared')) 'cleared': true,
            };
          },
          executor: (raw) async {
            final request = jsonDecode(raw) as Map<String, dynamic>;
            requests.add(request);
            final method = request['method'];
            final args = request['args'] as Map<String, dynamic>;
            Object? result;
            if (method == 'search') {
              searches++;
              if (searches == 1 || response != 'verified') {
                return jsonEncode({
                  'ok': false,
                  'error': {
                    'code': 'source_requires_browser',
                    'message': 'Interactive verification',
                  },
                });
              }
              expect(args['query'], 'same query');
              expect(args['page'], 3);
              result = {'items': <Object>[], 'hasNextPage': false};
            } else if (method == 'sources') {
              result = [
                {
                  'id': source.id,
                  'name': source.name,
                  'baseUrl': source.baseUrl,
                  'lang': 'vi',
                },
              ];
            } else if (method == 'browserSeed') {
              result = {
                'url': args['url'],
                'cookies': [],
                'seedToken': 'fixture-token',
              };
            } else if (method == 'browserSession') {
              sessions++;
              expect(args['seedToken'], 'fixture-token');
              result = true;
            } else {
              result = <String, dynamic>{};
            }
            return jsonEncode({'ok': true, 'result': result});
          },
        );
        addTearDown(repo.dispose);
        final action = repo.search(source, 'same query', page: 3);
        if (response == 'verified') {
          expect(await action, isEmpty);
        } else {
          await expectLater(action, throwsA(isA<ApiException>()));
        }
        expect(browsers, 1);
        expect(
          sessions,
          response == 'verified' ||
                  response == 'repeated' ||
                  response == 'cleared'
              ? 1
              : 0,
        );
        expect(
          searches,
          response == 'verified' || response == 'repeated' ? 2 : 1,
        );
        if (response == 'cancelled') {
          await expectLater(
            repo.search(source, 'same query'),
            throwsA(isA<ApiException>()),
          );
          expect(browsers, 1, reason: 'Cancellation has a bounded cooldown.');
        }
      },
    );
  }
  for (final stale in [
    'epoch',
    'configuration',
    'background',
    'disposed',
    'reset-user-agents',
  ]) {
    test(
      'late browser $stale cannot publish cookies or replay source',
      () async {
        final gate = Completer<Map<String, dynamic>>();
        final opened = Completer<void>();
        var revision = 0, foreground = true, sessions = 0;
        final repo = NativeTachiRepository(
          storageDirectory: directory,
          automaticallyVerifyChallenges: true,
          canVerifyChallenge: () => foreground,
          browserSessionRevision: () => revision,
          sessionBrowser: (_) {
            opened.complete();
            return gate.future;
          },
          executor: (raw) async {
            final request = jsonDecode(raw), method = request['method'];
            final args = request['args'];
            if (method == 'search') {
              return jsonEncode({
                'ok': false,
                'error': {'code': 'source_requires_browser'},
              });
            }
            if (method == 'browserSession') sessions++;
            final result = method == 'sources'
                ? [
                    {
                      'id': source.id,
                      'name': source.name,
                      'baseUrl': source.baseUrl,
                    },
                  ]
                : method == 'browserSeed'
                ? {
                    'url': args['url'],
                    'cookies': [],
                    'seedToken': 'fixture-token',
                  }
                : <String, dynamic>{};
            return jsonEncode({'ok': true, 'result': result});
          },
        );
        addTearDown(repo.dispose);
        final action = repo.search(source, 'query');
        final assertion = expectLater(action, throwsA(isA<ApiException>()));
        await opened.future;
        if (stale == 'epoch') await repo.clearCookies();
        if (stale == 'reset-user-agents') await repo.resetUserAgents();
        if (stale == 'configuration') revision++;
        if (stale == 'background') foreground = false;
        if (stale == 'disposed') repo.dispose();
        gate.complete({
          'url': 'https://fixture.test/',
          'userAgent': 'Fixture/1',
          'cookies': [],
          'verified': true,
        });
        await assertion;
        expect(sessions, 0);
      },
    );
  }
  test('background requests never present a verification browser', () async {
    var browsers = 0;
    final repo = NativeTachiRepository(
      storageDirectory: directory,
      automaticallyVerifyChallenges: true,
      canVerifyChallenge: () => false,
      sessionBrowser: (_) async {
        browsers++;
        return {};
      },
      executor: (raw) async => jsonEncode(
        (jsonDecode(raw)['method'] == 'initialize')
            ? {'ok': true, 'result': {}}
            : {
                'ok': false,
                'error': {'code': 'source_requires_browser'},
              },
      ),
    );
    addTearDown(repo.dispose);
    await expectLater(repo.search(source, 'q'), throwsA(isA<ApiException>()));
    expect(browsers, 0);
  });

  for (final stale in ['configuration', 'background', 'disposed', 'epoch']) {
    test('queued browser publication rechecks $stale at lease entry', () async {
      final browser = Completer<Map<String, dynamic>>();
      final opened = Completer<void>();
      final entered = Completer<void>();
      final release = Completer<void>();
      var revision = 0, sessions = 0, foreground = true;
      final repo = NativeTachiRepository(
        storageDirectory: directory,
        automaticallyVerifyChallenges: true,
        browserSessionRevision: () => revision,
        canVerifyChallenge: () => foreground,
        sessionBrowser: (_) {
          opened.complete();
          return browser.future;
        },
        executor: (raw) async {
          final request = jsonDecode(raw), method = request['method'];
          final args = request['args'];
          if (method == 'search') {
            return jsonEncode({
              'ok': false,
              'error': {'code': 'source_requires_browser'},
            });
          }
          if (method == 'browserSession') sessions++;
          final result = method == 'sources'
              ? [
                  {
                    'id': source.id,
                    'name': source.name,
                    'baseUrl': source.baseUrl,
                  },
                ]
              : method == 'browserSeed'
              ? {
                  'url': args['url'],
                  'cookies': [],
                  'seedToken': 'fixture-token',
                }
              : <String, dynamic>{};
          return jsonEncode({'ok': true, 'result': result});
        },
      );
      addTearDown(repo.dispose);
      final action = repo.search(source, 'q');
      final assertion = expectLater(action, throwsA(isA<ApiException>()));
      await opened.future;
      final held = repo.exclusiveExtensionBackup(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      browser.complete({
        'url': 'https://fixture.test/',
        'userAgent': 'Fixture/1',
        'cookies': [],
        'verified': true,
      });
      // Let the browser result enqueue its publication behind the held restore.
      await Future<void>.delayed(Duration.zero);
      Future<void>? clear;
      if (stale == 'configuration') revision++;
      if (stale == 'background') foreground = false;
      if (stale == 'disposed') repo.dispose();
      if (stale == 'epoch') {
        clear = repo.resetUserAgents();
        await Future<void>.delayed(Duration.zero);
      }
      release.complete();
      await held;
      await clear;
      await assertion;
      expect(
        sessions,
        0,
        reason: 'A stale queued browser must never reach JNI.',
      );
    });
  }
}
