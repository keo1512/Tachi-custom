import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/native_tabs.dart';
import '../../../core/widgets/feedback.dart';
import '../../library/data/coordinated_preferences.dart';
import '../navigation_preferences.dart';
import '../settings_controller.dart';
import 'settings_widgets.dart';

class NavigationSettingsScreen extends ConsumerStatefulWidget {
  const NavigationSettingsScreen({super.key});
  @override
  ConsumerState<NavigationSettingsScreen> createState() =>
      _NavigationSettingsState();
}

class _NavigationSettingsState extends ConsumerState<NavigationSettingsScreen> {
  late final List<int> order;
  late int start;
  late bool labels, remember;
  int? generation;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    final value = ref.read(navigationPreferencesProvider);
    order = [...value.order];
    start = value.start;
    labels = value.showLabels;
    remember = value.rememberSelected;
    final preferences = ref.read(preferencesProvider);
    generation = preferences is CoordinatedPreferences
        ? preferences.mutationGeneration
        : null;
  }

  Future<void> save() async {
    if (busy) return;
    setState(() => busy = true);
    final result = await perform(context, () async {
      await ref
          .read(navigationPreferencesProvider.notifier)
          .save(
            NavigationPreferences(
              order: order,
              start: start,
              showLabels: labels,
              rememberSelected: remember,
            ),
            expectedGeneration: generation,
          );
      return true;
    });
    if (!mounted) return;
    setState(() => busy = false);
    if (result == true) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Thanh tab',
    children: [
      const SettingsNote(
        'Kéo tay nắm để đổi thứ tự. Các tab vẫn mở đúng chức năng và dùng thanh UIKit của iOS.',
      ),
      ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        itemCount: order.length,
        onReorderItem: busy
            ? (_, _) {}
            : (from, to) => setState(() {
                order.insert(to, order.removeAt(from));
              }),
        itemBuilder: (_, index) => ListTile(
          key: ValueKey('tab-order-${order[index]}'),
          title: Text(mainTabLabels[order[index]]),
          trailing: ReorderableDragStartListener(
            index: index,
            enabled: !busy,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Icon(CupertinoIcons.line_horizontal_3),
            ),
          ),
        ),
      ),
      SettingsRow(
        title: 'Hiển thị tên tab',
        trailing: CupertinoSwitch(
          value: labels,
          onChanged: busy ? null : (v) => setState(() => labels = v),
        ),
      ),
      SettingsRow(
        title: 'Mở lại tab dùng gần nhất',
        trailing: CupertinoSwitch(
          value: remember,
          onChanged: busy ? null : (v) => setState(() => remember = v),
        ),
      ),
      const SettingsHeading('Tab mở mặc định'),
      for (var index = 0; index < 6; index++)
        SettingsRow(
          title: mainTabLabels[index],
          trailing: start == index
              ? const Icon(CupertinoIcons.checkmark)
              : null,
          onTap: busy ? null : () => setState(() => start = index),
        ),
      SettingsRow(
        title: 'Khôi phục thứ tự mặc định',
        icon: CupertinoIcons.arrow_counterclockwise,
        onTap: busy
            ? null
            : () => setState(() {
                order
                  ..clear()
                  ..addAll([0, 1, 2, 3, 4, 5]);
                start = 0;
                labels = true;
                remember = false;
              }),
      ),
      SettingsRow(
        title: 'Lưu',
        icon: CupertinoIcons.checkmark,
        trailing: busy ? const CupertinoActivityIndicator() : null,
        onTap: busy ? null : save,
      ),
    ],
  );
}
