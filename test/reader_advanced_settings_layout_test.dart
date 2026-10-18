import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/reader/presentation/reader_advanced_settings.dart';
import 'package:tachi_books/features/reader/presentation/reader_options_controller.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  for (final width in [320.0, 430.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'advanced settings wrap long options and persist choices at $width with text scale $scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 700);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final container = ProviderContainer(
            overrides: [preferencesProvider.overrideWithValue(preferences)],
          );
          addTearDown(container.dispose);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showAdvancedReaderSettings(context),
                      child: const Text('Open'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();

          Future<void> choose(String label, String option) async {
            tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position
                .jumpTo(0);
            await tester.pumpAndSettle();
            final field = find.byWidgetPredicate(
              (widget) =>
                  widget is DropdownButtonFormField<String> &&
                  widget.decoration.labelText == label,
            );
            await tester.scrollUntilVisible(
              field,
              180,
              scrollable: find.byType(Scrollable).first,
              maxScrolls: 60,
            );
            await tester.ensureVisible(field);
            await tester.pumpAndSettle();
            await tester.tap(field);
            await tester.pumpAndSettle();
            final choice = find.text(option).last;
            await tester.ensureVisible(choice);
            await tester.pumpAndSettle();
            await tester.tap(choice);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }

          await choose('Tỷ lệ trang ảnh', '100% kích thước ảnh');
          await choose('Nền trang đọc', 'Màu tùy chọn');
          final colorField = find.widgetWithText(TextFormField, 'Mã màu RGB');
          await tester.ensureVisible(colorField);
          await tester.pumpAndSettle();
          await tester.enterText(colorField, 'F5EBDC');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(
            container.read(readerOptionsProvider).backgroundColor,
            0xfff5ebdc,
          );
          final margins = find.widgetWithText(
            SwitchListTile,
            'Lề riêng cho màn hình dọc / ngang',
          );
          await tester.scrollUntilVisible(
            margins,
            -150,
            scrollable: find.byType(Scrollable).first,
          );
          await Scrollable.ensureVisible(
            tester.element(margins),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          await tester.tap(margins);
          await tester.pumpAndSettle();
          expect(
            container.read(readerOptionsProvider).orientationMargins,
            true,
          );
          await choose('Vùng chạm để cuộn', 'Trên / giữa / dưới');
          await choose('Vùng chạm để cuộn', 'Cạnh màn hình');
          await choose('Vùng chạm để cuộn', 'Kiểu Kindle');
          await choose('Vùng chạm để cuộn', 'Hình chữ L');
          await choose('Cách tự cuộn', 'Cuộn tới trang kế theo thời gian');
          await choose('Pha trộn màu', 'Giữ màu sáng hơn');
          await choose('Hướng màn hình', 'Dọc ngược');
          final reset = find.text('Đặt lại thiết lập đang chọn');
          await tester.scrollUntilVisible(
            reset,
            180,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(reset, findsOneWidget);
          expect(tester.takeException(), isNull);

          final options = container.read(readerOptionsProvider);
          expect(options.imageScale, 'original');
          expect(options.tapZones, 'lShape');
          expect(options.autoScrollMode, 'page');
          expect(options.blend, 'lighten');
          expect(options.orientation, 'reversePortrait');
          final restarted = ProviderContainer(
            overrides: [preferencesProvider.overrideWithValue(preferences)],
          );
          expect(
            restarted.read(readerOptionsProvider).toJson(),
            options.toJson(),
          );
          restarted.dispose();
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
