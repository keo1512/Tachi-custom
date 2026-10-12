import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/settings/presentation/backup_settings_screen.dart';

void main() {
  for (final includeConfiguration in [true, false]) {
    testWidgets(
      'restore preview keeps configuration opt-in; present=$includeConfiguration',
      (tester) async {
        BackupRestoreChoice? result;
        final preview = BackupPreview(
          format: 'TachiBooks',
          snapshot: LibrarySnapshot(
            [],
            configuration: includeConfiguration
                ? BackupConfiguration.fromJson({
                    'version': 1,
                    'preferences': {'appearanceV1': 'light'},
                  })
                : null,
          ),
          warnings: const [],
          expectedFingerprint: 'test',
          additions: 0,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await Navigator.push<BackupRestoreChoice>(
                      context,
                      CupertinoPageRoute(
                        builder: (_) => BackupPreviewScreen(preview: preview),
                      ),
                    );
                  },
                  child: const Text('Mở'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Mở'));
        await tester.pumpAndSettle();
        final toggle = find.byKey(
          const ValueKey('restore-backup-configuration'),
        );
        if (includeConfiguration) {
          expect(tester.widget<CupertinoSwitch>(toggle).value, false);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Khôi phục 0 sách mới và cấu hình'));
        } else {
          expect(toggle, findsNothing);
          await tester.tap(find.text('Khôi phục 0 sách mới'));
        }
        await tester.pumpAndSettle();
        expect(result?.restoreConfiguration, includeConfiguration);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
