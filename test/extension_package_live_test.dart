import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/extension_backup_store.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/extension_backup.dart';

const _apkDigest =
    'd93ce4bf0d522bc84c21448aa5eb0b2de087e46b46e78211b7ebccfbcc319e4b';
const _hostDigest =
    'b97640e9d74c432e74920a0564dee35079808ac334c331ab73fe8177a7feac3c';
const _choicesDigest =
    'd25a647dfa2a68ec2e1d4aa8983a1d8d26594df7cc5a4fb8046be833b4b5837a';

// Opt-in executes the real host/original APK. No companion server is started.
// This verifies the Windows Java8 interpreter, not the iOS JNI/runtime bridge.
class _JavaHost {
  _JavaHost(this.process)
    : lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ) {
    stderr = process.stderr.transform(utf8.decoder).join();
  }
  final Process process;
  final StreamIterator<String> lines;
  late final Future<String> stderr;
  final methods = <String>[];
  Future<String> execute(String request) async {
    final method = (jsonDecode(request) as Map)['method'] as String;
    methods.add(method);
    process.stdin.writeln(request);
    await process.stdin.flush();
    try {
      while (await lines.moveNext().timeout(const Duration(seconds: 90))) {
        if (lines.current.startsWith('TACHI_COVERAGE\t')) {
          final response = lines.current.substring('TACHI_COVERAGE\t'.length);
          jsonDecode(
            response,
          ); // Diagnose the test transport before the adapter.
          return response;
        }
      }
    } on FormatException catch (error) {
      throw StateError('Java proof transport failed during $method: $error');
    }
    throw StateError('Java host exited before returning its response.');
  }

  Future<String> close() async {
    await process.stdin.close();
    while (await lines.moveNext().timeout(const Duration(seconds: 30))) {}
    final exit = await process.exitCode.timeout(const Duration(seconds: 30));
    final diagnostic = await stderr;
    expect(exit, 0, reason: diagnostic);
    expect(
      RegExp(
        r'TACHI_UNCAUGHT|\bStub!|VerifyError|NoClassDefFoundError|ClassNotFoundException|UnsatisfiedLinkError|NoSuchMethodError|NoSuchFieldError|AbstractMethodError|ExceptionInInitializerError|NullPointerException',
        caseSensitive: false,
      ).hasMatch(diagnostic),
      false,
      reason: diagnostic,
    );
    return diagnostic;
  }
}

void main() {
  test(
    'original Komga and MANGA Plus APK full Dart backup export, offline reinstall and fresh Java8 JVM restart preserve bytes, String IDs and public preferences',
    () async {
      final root = Directory.current.absolute;
      final artifact = Directory('${root.path}/artifacts');
      final work = await artifact.createTemp('extension-package-portability-');
      final hostJar = File(
        '${root.path}/packages/tachi_runtime/ios/Runtime/engine/extension-host.jar',
      );
      final dependencyJar = File(
        '${root.path}/packages/tachi_runtime/ios/Runtime/engine/extension-dependencies.jar',
      );
      expect(
        sha256.convert(await hostJar.readAsBytes()).toString(),
        _hostDigest,
      );
      final frozenHost = await hostJar.copy('${work.path}/extension-host.jar');
      final frozenDependencies = await dependencyJar.copy(
        '${work.path}/extension-dependencies.jar',
      );
      final bridge = File(
        '${root.path}/tools/native_extension_engine/coverage/HostCoverageBridge.java',
      );
      final compiler =
          Platform.environment['TACHI_PROOF_JAVAC'] ??
          'D:/Codex/tools/jdk21/jdk-21.0.12.1+1/bin/javac.exe';
      final java =
          Platform.environment['TACHI_PROOF_JAVA'] ??
          'C:/Program Files/Java/jre1.8.0_503/bin/java.exe';
      final classes = await Directory('${work.path}/classes').create();
      final compile = await Process.run(compiler, [
        '--release',
        '8',
        '-encoding',
        'UTF-8',
        '-cp',
        '${frozenHost.path}${Platform.isWindows ? ';' : ':'}${frozenDependencies.path}',
        '-d',
        classes.path,
        bridge.path,
      ]);
      expect(
        compile.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
      final version = await Process.run(java, ['-Xint', '-version']);
      expect('${version.stderr}', contains('1.8.0'));
      expect('${version.stderr}', contains('interpreted mode'));
      final classpath = [
        classes.path,
        frozenHost.path,
        frozenDependencies.path,
      ].join(Platform.isWindows ? ';' : ':');
      final hosts = <_JavaHost>[];
      Future<_JavaHost> start() async {
        final host = _JavaHost(
          await Process.start(java, [
            '-Xint',
            '-Xms16m',
            '-Xmx128m',
            '-Xss512k',
            '-XX:-UseCompressedOops',
            '-XX:-UseCompressedClassPointers',
            '-cp',
            classpath,
            'HostCoverageBridge',
            '3000',
          ]),
        );
        hosts.add(host);
        return host;
      }

      NativeTachiRepository runtime(_JavaHost host, String directory) =>
          NativeTachiRepository(
            storageDirectory: Directory(directory),
            executor: host.execute,
            client: MockClient(
              (_) async => throw StateError(
                'Dart HTTP must not fetch packages during this proof',
              ),
            ),
          );
      BackupService service(
        NativeTachiRepository engine,
        LibraryRepository library,
        String journal,
      ) => BackupService(
        library,
        extensions: RepositoryExtensionBackupStore(
          runtime: engine,
          repository: library,
          engines: {SourceEngine.tachimanga},
          directory: Directory(journal),
        ),
      );
      final original = File(
        '${root.path}/artifacts/extension-coverage-apks/$_apkDigest.apk',
      );
      final originalBytes = await original.readAsBytes();
      expect(sha256.convert(originalBytes).toString(), _apkDigest);
      try {
        final sourceHost = await start();
        final source = runtime(sourceHost, '${work.path}/original-runtime');
        await source.installExtensionBytes(originalBytes);
        final sources = await source.listSources();
        expect(
          sources.map((source) => source.id),
          unorderedEquals([
            '4508733312114627536',
            '8074481155021144106',
            '5132811728275817394',
          ]),
        );
        final choicesBytes = await File(
          '${root.path}/artifacts/extension-coverage-apks/$_choicesDigest.apk',
        ).readAsBytes();
        expect(sha256.convert(choicesBytes).toString(), _choicesDigest);
        await source.installExtensionBytes(choicesBytes);
        final choiceSource = (await source.listSources()).singleWhere(
          (source) => source.id == '1998944621602463790',
        );
        final preferenceScreen = await source.sourcePreferences(choiceSource);
        final publicPosition = preferenceScreen.indexWhere(
          (item) => PublicSourcePreference.fromScreen(item)?.type == 'boolean',
        );
        expect(publicPosition, greaterThanOrEqualTo(0));
        final oldChoice = PublicSourcePreference.fromScreen(
          preferenceScreen[publicPosition],
        )!;
        await source.setSourcePreference(
          choiceSource,
          publicPosition,
          oldChoice.type == 'boolean'
              ? !(oldChoice.value as bool)
              : oldChoice.value,
        );
        final library = MemoryLibraryRepository();
        await library.save(
          LibraryBook(
            id: 'portable-fixture',
            title: 'Thư viện kiểm chứng',
            engine: 'local',
          ),
        );
        final exporter = service(source, library, '${work.path}/original-plan');
        final exported = await exporter.export();
        final bundle = ExtensionBackup.fromJson(
          (jsonDecode(utf8.decode(exported)) as Map)['extensions'],
        );
        expect(
          bundle.packages
              .singleWhere((package) => package.digest == _apkDigest)
              .bytes,
          originalBytes,
        );
        expect(
          bundle.packages
              .singleWhere((package) => package.digest == _choicesDigest)
              .bytes,
          choicesBytes,
        );
        expect(
          bundle.packages.expand(
            (package) =>
                package.preferences.values.expand((values) => values.values),
          ),
          isNotEmpty,
        );
        final fullSnapshot = File('${work.path}/full-backup.json');
        await fullSnapshot.writeAsBytes(exported, flush: true);
        final sourceDiagnostic = await sourceHost.close();
        hosts.remove(sourceHost);
        source.dispose();

        final targetHost = await start();
        final target = runtime(targetHost, '${work.path}/restored-runtime');
        final restoredLibrary = MemoryLibraryRepository();
        final importer = service(
          target,
          restoredLibrary,
          '${work.path}/restored-plan',
        );
        await importer.replace(
          await fullSnapshot.readAsBytes(),
          expectedFingerprint: importer.fingerprint(await importer.export()),
        );
        expect((await restoredLibrary.list()).single.id, 'portable-fixture');
        final installed = await target.captureExtensionBackup();
        expect(installed.fingerprint, bundle.fingerprint);
        expect(targetHost.methods, contains('inspectPackage'));
        expect(targetHost.methods, contains('install'));
        expect(targetHost.methods, contains('setPreference'));
        final targetDiagnostic = await targetHost.close();
        hosts.remove(targetHost);
        target.dispose();

        final restartHost = await start();
        final restart = runtime(restartHost, '${work.path}/restored-runtime');
        final reopened = await restart.captureExtensionBackup();
        expect(reopened.fingerprint, bundle.fingerprint);
        expect(
          reopened.packages
              .singleWhere((package) => package.digest == _apkDigest)
              .bytes,
          originalBytes,
        );
        expect(restartHost.methods, isNot(contains('install')));
        final restartDiagnostic = await restartHost.close();
        hosts.remove(restartHost);
        restart.dispose();
        await File('${artifact.path}/extension-package-portability-proof.json')
            .writeAsString(
              const JsonEncoder.withIndent('  ').convert({
                'scope': 'Dart full backup export/validate/offline reinstall/public-preferences/fresh-JVM restart with original Komga1.6.71 and MANGA Plus APKs',
                'passed': true,
                'hostSha256': _hostDigest,
                'dependenciesSha256': sha256
                    .convert(await frozenDependencies.readAsBytes())
                    .toString(),
                'originalApkSha256': _apkDigest,
                'publicPreferenceApkSha256': _choicesDigest,
                'backupBytes': exported.length,
                'extensionFingerprint': bundle.fingerprint,
                'sourceIds': reopened.packages
                    .expand((package) => package.sourceIds)
                    .toList(),
                'publicPreferences': reopened.packages.fold<int>(
                  0,
                  (count, package) =>
                      count +
                      package.preferences.values.fold<int>(
                        0,
                        (count, prefs) => count + prefs.length,
                      ),
                ),
                'runDirectory': work.path,
                'javaVersion': '${version.stderr}'.trim(),
                'backgroundObservationSecondsPerPhase': 3,
                'backgroundDiagnosticsEmpty': [
                  sourceDiagnostic,
                  targetDiagnostic,
                  restartDiagnostic,
                ].every((item) => item.trim().isEmpty),
                'dartPackageHttpRequests': false,
                'sourceStartupMayRequestNetwork': true,
                'websiteSearchReadDownloadVerified': false,
                'iosRuntimeVerified': false,
                'allExtensionsVerified': false,
              }),
              flush: true,
            );
      } finally {
        for (final host in hosts) {
          host.process.kill();
        }
        expect(
          sha256.convert(await original.readAsBytes()).toString(),
          _apkDigest,
        );
      }
    },
    skip: Platform.environment['TACHI_PACKAGE_PORTABILITY_LIVE'] != '1',
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
