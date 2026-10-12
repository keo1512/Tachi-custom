import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../settings/presentation/settings_widgets.dart';
import '../application/app_lock_controller.dart';
import '../domain/privacy_preferences.dart';

class PrivacySettings extends ConsumerStatefulWidget {
  const PrivacySettings({super.key});

  @override
  ConsumerState<PrivacySettings> createState() => _PrivacySettingsState();
}

class _PrivacySettingsState extends ConsumerState<PrivacySettings> {
  @override
  void initState() {
    super.initState();
    ref.read(appLockProvider.notifier).initialize();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appLockProvider);
    final controller = ref.read(appLockProvider.notifier);
    return Column(
      children: [
        const SettingsHeading('Khóa ứng dụng'),
        SettingsRow(
          title: 'Khóa TachiBooks',
          subtitle: state.capabilities.label,
          icon: CupertinoIcons.lock_shield,
          trailing: CupertinoSwitch(
            key: const ValueKey('privacy-enabled'),
            value: state.preferences.enabled,
            onChanged: state.authenticating
                ? null
                : (value) =>
                      perform(context, () => controller.update(enabled: value)),
          ),
        ),
        const SettingsNote(
          'Dùng Face ID, Touch ID hoặc mã khóa iPhone/iPad. iOS quản lý mã khóa và giới hạn thử sai; TachiBooks không lưu mã thiết bị.',
        ),
        if (state.error != null) SettingsNote(state.error!),
        SettingsRow(
          title: 'Tự khóa sau khi rời ứng dụng',
          trailing: DropdownButton<int>(
            key: const ValueKey('privacy-delay'),
            value: state.preferences.delaySeconds,
            items: const [
              DropdownMenuItem(value: 0, child: Text('Ngay lập tức')),
              DropdownMenuItem(value: 30, child: Text('30 giây')),
              DropdownMenuItem(value: 60, child: Text('1 phút')),
              DropdownMenuItem(value: 300, child: Text('5 phút')),
            ],
            onChanged: (value) {
              if (value != null) {
                perform(context, () => controller.update(delaySeconds: value));
              }
            },
          ),
        ),
        if (state.preferences.enabled)
          SettingsRow(
            title: 'Tự khóa khi không có thao tác',
            subtitle: 'Khi ứng dụng vẫn đang mở',
            trailing: DropdownButton<int>(
              value: state.preferences.idleSeconds,
              items: const [
                DropdownMenuItem(value: 0, child: Text('Tắt')),
                DropdownMenuItem(value: 60, child: Text('1 phút')),
                DropdownMenuItem(value: 300, child: Text('5 phút')),
                DropdownMenuItem(value: 900, child: Text('15 phút')),
              ],
              onChanged: (value) {
                if (value != null) {
                  perform(context, () => controller.update(idleSeconds: value));
                }
              },
            ),
          ),
        if (state.preferences.enabled)
          SettingsRow(
            title: 'Khóa ngay',
            icon: CupertinoIcons.lock,
            onTap: controller.lockNow,
          ),
        const SettingsHeading('Bảo vệ màn hình'),
        SettingsRow(
          title: 'Ẩn nội dung khi chuyển ứng dụng',
          subtitle: 'App Switcher',
          icon: CupertinoIcons.eye_slash,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButton<SecureScreenMode>(
            key: const ValueKey('privacy-screen-mode'),
            isExpanded: true,
            value: state.preferences.secureScreen,
            items: const [
              DropdownMenuItem(value: SecureScreenMode.off, child: Text('Tắt')),
              DropdownMenuItem(
                value: SecureScreenMode.always,
                child: Text('Luôn bảo vệ'),
              ),
              DropdownMenuItem(
                value: SecureScreenMode.incognito,
                child: Text('Chỉ khi ẩn danh'),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                perform(context, () => controller.update(secureScreen: value));
              }
            },
          ),
        ),
        const SettingsNote(
          'Khi khóa ứng dụng được bật, nội dung luôn được che khi rời app. Chế độ bảo vệ màn hình cũng có thể dùng riêng hoặc chỉ khi ẩn danh.',
        ),
      ],
    );
  }
}
