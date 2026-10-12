import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/device_tools.dart';
import '../domain/native_source_engine.dart';
import 'native_runtime_provider.dart';

final sourceMaintenanceProvider = Provider<SourceMaintenance>(
  (ref) => SourceMaintenance(
    ref.read(nativeSourceRuntimesProvider).values.toList(),
    ref.read(deviceToolsProvider),
  ),
);

class SourceMaintenance {
  SourceMaintenance(this.runtimes, this.device);
  final List<NativeSourceEngine> runtimes;
  final DeviceTools device;
  Future<void> clearCaches() async {
    for (final engine in runtimes) {
      if (engine is NativeSourceMaintenanceEngine) {
        await (engine as NativeSourceMaintenanceEngine).clearSourceCache();
      }
    }
    await device.clearHttpCache();
  }

  Future<void> clearCookies() async {
    for (final engine in runtimes) {
      if (engine is NativeSourceMaintenanceEngine) {
        await (engine as NativeSourceMaintenanceEngine).clearCookies();
      }
    }
    await device.clearCookies();
  }

  Future<void> clearWebData() async {
    await clearCookies();
    await device.clearWebData();
  }
}
