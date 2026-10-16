import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/sync/application/sync_controller.dart';
import 'package:tachi_books/features/sync/data/google_session.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';
import 'package:tachi_books/features/sync/presentation/sync_status_panel.dart';

void main() {
  const user = SyncUser(uid: 'u', email: 'reader@example.com');
  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets(
      'sync status and transfer distinguish running, failure and completion at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Future<void> show(SyncState state) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: const TextScaler.linear(1.5),
                  ),
                  child: SyncStatusPanel(state: state),
                ),
              ),
            ),
          );
          await tester.pump();
        }

        await show(
          const SyncState(
            user: user,
            enabled: true,
            busy: true,
            progress: SyncTransferProgress(
              SyncTransferDirection.upload,
              1048576,
              2097152,
            ),
          ),
        );
        expect(find.text('Đang tải lên…'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          .5,
        );
        expect(find.textContaining('50%'), findsOneWidget);
        await show(
          const SyncState(
            user: user,
            enabled: true,
            error: true,
            message: 'Chưa có quyền truy cập dữ liệu.',
            progress: SyncTransferProgress(
              SyncTransferDirection.upload,
              1048576,
              2097152,
            ),
          ),
        );
        expect(find.text('Đồng bộ chưa hoàn tất'), findsOneWidget);
        expect(find.text('Chưa có quyền truy cập dữ liệu.'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.text('Đã đồng bộ'), findsNothing);
        await show(
          SyncState(
            user: user,
            enabled: true,
            lastSyncedAt: DateTime(2026, 10, 15),
          ),
        );
        expect(find.text('Đồng bộ tự động đang bật'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await show(const SyncState(user: user, conflict: true));
        expect(find.text('Cần chọn cách hợp nhất'), findsOneWidget);
        await show(
          const SyncState(
            user: user,
            conflict: true,
            busy: true,
            progress: SyncTransferProgress(SyncTransferDirection.upload, 1, 2),
          ),
        );
        expect(find.text('Đang tải lên…'), findsOneWidget);
        expect(find.text('Cần chọn cách hợp nhất'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
