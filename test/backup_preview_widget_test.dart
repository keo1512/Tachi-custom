import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/settings/presentation/backup_settings_screen.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets(
      'Backup preview shows limitations and returns only the explicit decision at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final preview = BackupPreview(
          format: 'Tachimanga 5.0 (build511)',
          snapshot: LibrarySnapshot(const []),
          warnings: const [
            'Nội dung offline từ app gốc không được nhập qua adapter này.',
            'Extension, thiết lập và tài khoản không được nhập.',
            'Truyện có nhiều danh mục chỉ giữ danh mục đầu tiên theo thứ tự.',
          ],
          expectedFingerprint: 'example',
          additions: 0,
        );
        bool? decision;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      decision = await Navigator.of(context).push<bool>(
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
          ),
        );
        await tester.tap(find.text('Mở'));
        await tester.pumpAndSettle();
        expect(find.text('Xem trước khôi phục'), findsOneWidget);
        expect(find.textContaining('Nội dung offline'), findsOneWidget);
        expect(decision, isNull);
        await tester.scrollUntilVisible(find.text('Hủy'), 100);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Hủy'));
        await tester.pumpAndSettle();
        expect(decision, isFalse);
        await tester.tap(find.text('Mở'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Khôi phục 0 sách mới'), 100);
        await tester.drag(find.byType(ListView), const Offset(0, -120));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Khôi phục 0 sách mới'));
        await tester.pumpAndSettle();
        expect(decision, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
