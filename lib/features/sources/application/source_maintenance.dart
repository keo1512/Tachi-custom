import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/device_tools.dart';
import '../domain/native_source_engine.dart';
import '../domain/catalogue.dart';
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
  Future<void> clearImageCaches() async {
    for (final engine in runtimes) {
      if (engine is NativeCoverCacheEngine) {
        await (engine as NativeCoverCacheEngine).clearCoverCache();
      }
    }
    await device.clearHttpCache();
  }

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

  Future<void> resetUserAgents() async {
    var engineFailed = false, browserFailed = false;
    for (final engine in runtimes) {
      if (engine is NativeUserAgentResetEngine) {
        try {
          await (engine as NativeUserAgentResetEngine).resetUserAgents();
        } catch (_) {
          engineFailed = true;
        }
      }
    }
    // Try both stores even if one fails, and report partial completion so a
    // remaining override cannot silently look like a successful reset.
    try {
      await device.resetUserAgents();
    } catch (_) {
      browserFailed = true;
    }
    if (engineFailed || browserFailed) {
      throw ApiException(
        engineFailed && browserFailed
            ? 'Chưa đặt lại được User-Agent của engine và trình duyệt. Hãy thử lại.'
            : engineFailed
            ? 'Đã đặt lại trình duyệt nhưng chưa đặt lại User-Agent của engine. Hãy thử lại.'
            : 'Đã đặt lại engine nhưng chưa đặt lại User-Agent của trình duyệt. Hãy thử lại.',
        code: 'USER_AGENT_RESET_INCOMPLETE',
      );
    }
  }
}
