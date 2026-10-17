import Flutter
import UIKit
import UserNotifications
import BackgroundTasks
import CryptoKit

/// Foreground download work may continue on iOS 26+. This wraps the same Dart
/// queue, never a second executor or a raw-HTTP replacement for extension pages.
@MainActor
final class TaskContinuedDownloads {
  static let shared = TaskContinuedDownloads()
  static let identifier = "dev.tachibooks.tachiBooks.downloads.continued"
  private var task: BGTask?
  private var registered = false, submitted = false, requested = false
  private var submissionFailed = false
  private var remaining = 0, completed: Int64 = 0, total: Int64 = 0
  private var pageFraction: Int64 = 0
  var onExpired: () -> Void = {}
  var running: Bool { task != nil }
  var diagnosticState: [String: Int] {
    ["continuedProcessingRegistered": registered ? 1 : 0,
     "continuedProcessingRequested": requested ? 1 : 0,
     "continuedProcessingRunning": running ? 1 : 0,
     "continuedProcessingSubmitFailed": submissionFailed ? 1 : 0]
  }

  func register() {
    guard #available(iOS 26.0, *), !registered else { return }
    registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] value in
      guard let self = self, let continued = value as? BGContinuedProcessingTask,
        self.submitted, self.requested else {
        value.setTaskCompleted(success: false)
        return
      }
      self.task = continued
      continued.expirationHandler = { [weak self] in
        DispatchQueue.main.async {
          guard let self = self, self.task === continued else { return }
          self.finish(success: false)
          self.onExpired()
        }
      }
      self.reportProgress()
    }
  }

  func update(pending: Int, failed: Int, requested: Bool) {
    guard #available(iOS 26.0, *) else { return }
    self.requested = requested && pending > 0
    if !self.requested {
      finish(success: pending == 0 && failed == 0)
      return
    }
    if submitted {
      if pending < remaining { completed += Int64(remaining - pending); pageFraction = 0 }
      if pending > remaining { total += Int64(pending - remaining) }
      remaining = pending
      reportProgress()
      return
    }
    // Continued tasks must start during foreground work initiated by a person.
    guard registered, UIApplication.shared.applicationState == .active else { return }
    remaining = pending
    completed = 0
    pageFraction = 0
    total = Int64(pending)
    let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier,
      title: "Tải truyện", subtitle: "Còn \(pending) chương")
    request.strategy = .fail
    submitted = true
    do { try BGTaskScheduler.shared.submit(request); submissionFailed = false }
    catch { submitted = false; submissionFailed = true } // Existing finite lease/deferred job is fallback.
  }

  private func reportProgress() {
    guard #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask else { return }
    continued.progress.totalUnitCount = max(1, total * 1000)
    continued.progress.completedUnitCount = min(completed * 1000 + pageFraction, max(0, total * 1000 - 1))
    continued.updateTitle("Tải truyện", subtitle: "Còn \(remaining) chương")
  }

  func pageProgress(completed: Int, total: Int) {
    guard completed >= 0, total > 0, completed <= total, total <= 10000 else { return }
    pageFraction = max(pageFraction, min(999, Int64(completed) * 1000 / Int64(total)))
    reportProgress()
  }

  private func finish(success: Bool) {
    if submitted { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier) }
    let old = task
    old?.expirationHandler = nil
    task = nil
    submitted = false
    if success, #available(iOS 26.0, *), let continued = old as? BGContinuedProcessingTask {
      continued.progress.completedUnitCount = continued.progress.totalUnitCount
    }
    old?.setTaskCompleted(success: success)
  }
}

/// One finite UIApplication lease; no BGTask scheduling or persistent service.
@MainActor
final class TaskBackgroundLease {
  private(set) var identifier: UIBackgroundTaskIdentifier = .invalid
  private let start: (@escaping () -> Void) -> UIBackgroundTaskIdentifier
  private let finish: (UIBackgroundTaskIdentifier) -> Void
  private var generation = 0
  var onExpired: () -> Void = {}

  init(start: @escaping (@escaping () -> Void) -> UIBackgroundTaskIdentifier,
       finish: @escaping (UIBackgroundTaskIdentifier) -> Void) {
    self.start = start
    self.finish = finish
  }
  @discardableResult
  func begin() -> Bool {
    if identifier != .invalid { return true }
    generation += 1
    let current = generation
    identifier = start { [weak self] in
      guard let self = self, self.identifier != .invalid, self.generation == current else { return }
      // Construct/enqueue any native notice before giving up the execution
      // window. Neither cleanup nor the notice depends on a Dart callback.
      self.onExpired()
      self.end()
    }
    return identifier != .invalid
  }
  func end() {
    guard identifier != .invalid else { return }
    let old = identifier
    identifier = .invalid
    generation += 1
    finish(old)
  }
}

/// A bounded numeric snapshot only: no queue identity, title, source or token.
@MainActor
final class TaskPauseSnapshot {
  private(set) var pending = 0, failed = 0
  private(set) var notifyOnPause = false, resumeRequested = false
  private(set) var updatesRequested = false, notifyUpdatePause = false
  private(set) var updateEarliestMillis = 0, updateRemaining = 0, updateFailed = 0
  private var consumed = true
  private var updateConsumed = true
  private var armed = false
  var eligible: Bool { resumeRequested || updatesRequested }

  @discardableResult
  func update(pending: Int, failed: Int, notifyOnPause: Bool, resumeRequested: Bool,
              updatesRequested: Bool = false, updateEarliestMillis: Int = 0,
              updateRemaining: Int = 0, updateFailed: Int = 0, notifyUpdatePause: Bool = false) -> Bool {
    guard [pending, failed, updateRemaining, updateFailed].allSatisfy({ $0 >= 0 && $0 <= 1_000_000 }),
      updateEarliestMillis >= 0, updateEarliestMillis <= 253402300799999 else { return false }
    let oldUpdateNotice = self.notifyUpdatePause
    self.pending = pending
    self.failed = failed
    self.resumeRequested = resumeRequested && pending > 0
    self.notifyOnPause = notifyOnPause && self.resumeRequested
    if !self.notifyOnPause { consumed = true }
    self.updatesRequested = updatesRequested
    self.updateEarliestMillis = updateEarliestMillis
    self.updateRemaining = updateRemaining
    self.updateFailed = updateFailed
    self.notifyUpdatePause = notifyUpdatePause && updateRemaining + updateFailed > 0
    if !self.notifyUpdatePause { updateConsumed = true }
    else if armed && !oldUpdateNotice { updateConsumed = false }
    return true
  }
  func arm() { armed = true; consumed = !notifyOnPause; updateConsumed = !notifyUpdatePause }
  func invalidate() {
    notifyOnPause = false
    resumeRequested = false
    updatesRequested = false
    notifyUpdatePause = false
    updateConsumed = true
    armed = false
    consumed = true
  }
  func disableNotice() { notifyOnPause = false; consumed = true; notifyUpdatePause = false; updateConsumed = true }
  func takeNotice() -> UNMutableNotificationContent? {
    guard notifyOnPause, !consumed else { return nil }
    consumed = true
    return TaskNotificationSummary.pausedDownloads(pending: pending, failed: failed)
  }
  func takeUpdateNotice() -> UNMutableNotificationContent? {
    guard notifyUpdatePause, !updateConsumed else { return nil }
    updateConsumed = true
    return TaskNotificationSummary.pausedUpdates(remaining: updateRemaining, failed: updateFailed)
  }
}

/// Pure completion guard shared by native timeout/expiry/Dart completion paths.
/// iOS completion must be invoked once even when old Dart callbacks arrive.
@MainActor
final class TaskScheduledWindow {
  let token: Int
  private(set) var completed = false
  private let finish: (Bool) -> Void
  init(token: Int, finish: @escaping (Bool) -> Void) {
    self.token = token
    self.finish = finish
  }
  @discardableResult
  func complete(token: Int, success: Bool) -> Bool {
    guard self.token == token, !completed else { return false }
    completed = true
    finish(success)
    return true
  }
}

/// One deferred processing request for an explicitly started durable queue.
/// Register during application launch, before Flutter scene initialization.
/// This intentionally does not create a second/headless Flutter engine: if the
/// app's existing engine cannot acknowledge readiness, complete unsuccessfully.
@MainActor
final class TaskBackgroundScheduler {
  static let shared = TaskBackgroundScheduler()
  static let identifier = "dev.tachibooks.downloads.processing"
  private static let snapshotKey = "dev.tachibooks.downloads.backgroundSnapshotV1"
  let snapshot = TaskPauseSnapshot()
  var diagnosticState: [String: Int] {
    var result = ["backgroundRequested": snapshot.eligible ? 1 : 0,
     "backgroundRunning": active != nil || TaskContinuedDownloads.shared.running ? 1 : 0,
     "backgroundPendingChapters": snapshot.pending,
     "backgroundRemainingBooks": snapshot.updateRemaining]
    result.merge(TaskContinuedDownloads.shared.diagnosticState) { _, new in new }
    return result
  }
  private var registered = false, registrationAttempted = false, submitted = false
  private var ready = false, delivered = false
  private var nextToken = 0
  private var active: TaskScheduledWindow?
  private var watchdog: DispatchWorkItem?
  var onStart: (Int) -> Void = { _ in }
  var onExpired: () -> Void = {}

  private init() {
    if let saved = UserDefaults.standard.dictionary(forKey: Self.snapshotKey),
      let pending = saved["pending"] as? Int, let failed = saved["failed"] as? Int,
      let notify = saved["notifyOnPause"] as? Bool, let resume = saved["resumeRequested"] as? Bool {
      snapshot.update(pending: pending, failed: failed, notifyOnPause: notify, resumeRequested: resume,
        updatesRequested: saved["updatesRequested"] as? Bool ?? false,
        updateEarliestMillis: saved["updateEarliestMillis"] as? Int ?? 0,
        updateRemaining: saved["updateRemaining"] as? Int ?? 0,
        updateFailed: saved["updateFailed"] as? Int ?? 0,
        notifyUpdatePause: saved["notifyUpdatePause"] as? Bool ?? false)
    }
  }
  func register() {
    guard !registrationAttempted else { return }
    registrationAttempted = true
    registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
      guard let self = self, let processing = task as? BGProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self.launch(processing)
    }
  }
  func attach(onStart: @escaping (Int) -> Void, onExpired: @escaping () -> Void) {
    ready = false
    self.onStart = onStart
    self.onExpired = onExpired
  }
  func acknowledgeReady() {
    ready = true
    deliverIfReady()
  }
  func update(pending: Int, failed: Int, notifyOnPause: Bool, resumeRequested: Bool,
              updatesRequested: Bool = false, updateEarliestMillis: Int = 0,
              updateRemaining: Int = 0, updateFailed: Int = 0, notifyUpdatePause: Bool = false) -> Bool {
    let oldEligible = snapshot.eligible, oldEarliest = snapshot.updateEarliestMillis,
      oldDownload = snapshot.resumeRequested
    guard snapshot.update(pending: pending, failed: failed, notifyOnPause: notifyOnPause, resumeRequested: resumeRequested,
      updatesRequested: updatesRequested, updateEarliestMillis: updateEarliestMillis,
      updateRemaining: updateRemaining, updateFailed: updateFailed, notifyUpdatePause: notifyUpdatePause) else { return false }
    persist()
    if submitted, active == nil,
      oldEligible != snapshot.eligible || oldEarliest != snapshot.updateEarliestMillis || oldDownload != snapshot.resumeRequested {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
      submitted = false
    }
    if !snapshot.eligible {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
      submitted = false
      if pending + updateRemaining > 0, let active = active {
        onExpired()
        complete(token: active.token, success: false)
      }
    } else if active == nil { submitIfNeeded() }
    return true
  }
  func disableNotices() {
    snapshot.disableNotice()
    persist()
  }
  private func persist() {
    UserDefaults.standard.set(["pending": snapshot.pending, "failed": snapshot.failed,
      "notifyOnPause": snapshot.notifyOnPause, "resumeRequested": snapshot.resumeRequested,
      "updatesRequested": snapshot.updatesRequested, "updateEarliestMillis": snapshot.updateEarliestMillis,
      "updateRemaining": snapshot.updateRemaining, "updateFailed": snapshot.updateFailed,
      "notifyUpdatePause": snapshot.notifyUpdatePause], forKey: Self.snapshotKey)
  }
  private func submitIfNeeded() {
    guard registered, !submitted, snapshot.eligible else { return }
    let request = BGProcessingTaskRequest(identifier: Self.identifier)
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = false
    let earliest = Date(timeIntervalSinceNow: 15 * 60)
    request.earliestBeginDate = snapshot.resumeRequested ? earliest :
      max(earliest, Date(timeIntervalSince1970: Double(snapshot.updateEarliestMillis) / 1000))
    do {
      try BGTaskScheduler.shared.submit(request)
      submitted = true
    } catch {
      // Lack of Background App Refresh, quota or scheduler availability never
      // invalidates durable queue entries or creates an immediate retry loop.
      submitted = false
    }
  }
  private func launch(_ task: BGProcessingTask) {
    submitted = false
    guard snapshot.eligible, active == nil,
      UIApplication.shared.applicationState != .active else {
      task.setTaskCompleted(success: false)
      return
    }
    nextToken = nextToken == Int(Int32.max) ? 1 : nextToken + 1
    let token = nextToken
    active = TaskScheduledWindow(token: token, finish: { task.setTaskCompleted(success: $0) })
    delivered = false
    snapshot.arm()
    task.expirationHandler = { [weak self] in
      DispatchQueue.main.async { self?.expire(token: token) }
    }
    // Fail a cold launch without the application engine promptly. Once ready,
    // additionally bound work to five minutes, below any platform grant.
    installWatchdog(token: token, seconds: 20)
    deliverIfReady()
  }
  private func deliverIfReady() {
    guard ready, !delivered, let active = active, !active.completed else { return }
    delivered = true
    installWatchdog(token: active.token, seconds: 5 * 60)
    onStart(active.token)
  }
  private func installWatchdog(token: Int, seconds: TimeInterval) {
    watchdog?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.expire(token: token) }
    watchdog = item
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
  }
  private func expire(token: Int) {
    guard active?.token == token else { return }
    onExpired()
    complete(token: token, success: false)
  }
  func complete(token: Int, success: Bool) {
    guard let window = active, window.complete(token: token, success: success) else { return }
    watchdog?.cancel()
    watchdog = nil
    active = nil
    delivered = false
    // Resubmit only after the finite window is closed and only while the
    // explicitly started queue remains eligible. iOS chooses the next date.
    submitIfNeeded()
  }
}

enum TaskNotificationSummary {
  static let identifiers = ["tachibooks.downloads", "tachibooks.updates"]
  private static let bookPrefix = "tachibooks.update-book."
  /// Each delivery has its own identifier. A cancelled old add() callback can
  /// remove only that request, never a newer notice for the same book or task.
  static func baseIdentifier(_ identifier: String) -> String? {
    if identifiers.contains(identifier) { return identifier }
    for base in identifiers {
      if identifier.range(of: "^" + NSRegularExpression.escapedPattern(for: base) + "\\.[0-9a-f]{32}\\z", options: .regularExpression) != nil { return base }
    }
    guard identifier.range(of: "^tachibooks\\.update-book\\.[0-9a-f]{64}(?:\\.[0-9a-f]{32})?\\z", options: .regularExpression) != nil else { return nil }
    return String(identifier.prefix(bookPrefix.count + 64))
  }
  static func requestIdentifier(_ base: String) -> String {
    base + "." + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
  static func recognizes(_ identifier: String) -> Bool {
    baseIdentifier(identifier) != nil
  }
  static func bookIdentifier(_ bookId: String) -> String? {
    guard !bookId.isEmpty, bookId.utf8.count <= 2048,
      !bookId.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
    return bookPrefix + SHA256.hash(data: Data(bookId.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func bookUpdate(bookId: String, added: Int) -> UNMutableNotificationContent? {
    guard bookIdentifier(bookId) != nil, added > 0, added <= 1_000_000 else { return nil }
    let content = UNMutableNotificationContent()
    content.title = "Truyện có chương mới"
    content.body = "Có \(added) chương mới. Chạm để mở truyện trong thư viện."
    // No title, chapter URL, source address, account or caller-supplied route.
    content.userInfo = ["task": "book-update", "bookId": bookId]
    content.sound = nil
    content.interruptionLevel = .passive
    return content
  }
  static func updateCompletion(checked: Int, added: Int, failed: Int) -> UNMutableNotificationContent? {
    guard [checked, added, failed].allSatisfy({ $0 >= 0 && $0 <= 1_000_000 }),
      checked + failed > 0 else { return nil }
    let content = UNMutableNotificationContent()
    content.title = "Đã kiểm tra cập nhật thư viện"
    content.body = "Đã kiểm tra \(checked) truyện; \(added) chương mới; \(failed) truyện cần thử lại."
    content.userInfo = ["task": "updates"]
    content.sound = nil
    content.interruptionLevel = .passive
    return content
  }
  static func content(kind: String, completed: Int, failed: Int) -> UNMutableNotificationContent? {
    guard ["downloads", "updates"].contains(kind), completed >= 0, failed >= 0,
      completed <= 1_000_000, failed <= 1_000_000, completed + failed > 0 else { return nil }
    let content = UNMutableNotificationContent()
    content.title = kind == "downloads" ? "Kết quả tải xuống" : "Cập nhật thư viện"
    content.body = kind == "downloads"
      ? "Đã tải \(completed) chương; \(failed) chương cần thử lại."
      : "Có \(completed) chương mới; \(failed) truyện chưa cập nhật được."
    content.userInfo = ["task": kind]
    content.sound = nil
    content.interruptionLevel = .passive
    return content
  }
  static func pausedDownloads(pending: Int, failed: Int) -> UNMutableNotificationContent? {
    guard pending >= 0, failed >= 0, pending <= 1_000_000, failed <= 1_000_000,
      pending + failed > 0 else { return nil }
    let content = UNMutableNotificationContent()
    content.title = "Tải xuống đã tạm dừng"
    content.body = "Còn \(pending) chương chờ tải; \(failed) chương cần thử lại. Mở app để tiếp tục."
    content.userInfo = ["task": "downloads"]
    content.sound = nil
    content.interruptionLevel = .passive
    return content
  }
  static func pausedUpdates(remaining: Int, failed: Int) -> UNMutableNotificationContent? {
    guard remaining >= 0, failed >= 0, remaining <= 1_000_000, failed <= 1_000_000,
      remaining + failed > 0 else { return nil }
    let content = UNMutableNotificationContent()
    content.title = "Cập nhật thư viện đã tạm dừng"
    content.body = "Còn \(remaining) truyện chưa kiểm tra; \(failed) truyện cần thử lại. Mở app để tiếp tục."
    content.userInfo = ["task": "updates"]
    content.sound = nil
    content.interruptionLevel = .passive
    return content
  }
  /// A notification carries one fixed tab token, never a caller-supplied route.
  static func destination(identifier: String, userInfo: [AnyHashable: Any]) -> URL? {
    if userInfo.count == 2, userInfo["task"] as? String == "book-update",
      let bookId = userInfo["bookId"] as? String, bookIdentifier(bookId) == baseIdentifier(identifier) {
      // Encode one opaque segment, including slash/percent/dot identities. A
      // source URL stored in an ID never becomes an executable or HTTP route.
      let dot = bookId == "." || bookId == ".."
      let encoded = bookId.utf8.map { byte -> String in
        let plain = (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 95, 126].contains(byte) || (byte == 46 && !dot)
        return plain ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
      }.joined()
      let value = "tachibooks://notification-book/\(encoded)"
      guard value.utf8.count <= 8192 else { return nil }
      return URL(string: value)
    }
    guard userInfo.count == 1, let task = userInfo["task"] as? String,
      ["downloads", "updates"].contains(task), baseIdentifier(identifier) == "tachibooks.\(task)" else { return nil }
    return URL(string: "tachibooks://tasks/\(task)")
  }
}

@MainActor
final class TaskPlatformBridge {
  private let channel: FlutterMethodChannel
  private let notifications: UNUserNotificationCenter
  private let lease: TaskBackgroundLease
  private let scheduler = TaskBackgroundScheduler.shared
  private let continued = TaskContinuedDownloads.shared
  private var notificationGeneration = 0

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.tachibooks/tasks", binaryMessenger: messenger)
    notifications = UNUserNotificationCenter.current()
    lease = TaskBackgroundLease(start: { expiration in
      UIApplication.shared.beginBackgroundTask(withName: "TachiBooks downloads", expirationHandler: expiration)
    }, finish: { UIApplication.shared.endBackgroundTask($0) })
    lease.onExpired = { [weak self] in
      guard let self = self, !self.continued.running else { return }
      self.expired()
    }
    continued.onExpired = { [weak self] in
      self?.lease.end()
      self?.channel.invokeMethod("continuedProcessingExpired", arguments: nil)
    }
    scheduler.attach(onStart: { [weak self] token in
      self?.channel.invokeMethod("scheduledBackground", arguments: token)
    }, onExpired: { [weak self] in self?.expired() })
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        guard let self = self else {
          result(FlutterError(code: "task_unavailable", message: "Tác vụ đã đóng.", details: nil))
          return
        }
        self.handle(call, result: result)
      }
    }
  }
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "downloadPageProgress":
      guard let args = call.arguments as? [String: Int], Set(args.keys) == ["completed", "total"],
        let completed = args["completed"], let total = args["total"],
        completed >= 0, total > 0, completed <= total, total <= 10000 else {
        result(FlutterError(code: "invalid_progress", message: "Tiến độ tải không hợp lệ.", details: nil)); return
      }
      continued.pageProgress(completed: completed, total: total)
      result(nil)
    case "beginBackground":
      if continued.running { result(true); return }
      if lease.identifier == .invalid { scheduler.snapshot.arm() }
      let granted = lease.begin()
      if !granted { expired() }
      result(granted)
    case "endBackground": lease.end(); result(nil)
    case "backgroundReady": scheduler.acknowledgeReady(); result(nil)
    case "updateBackgroundSnapshot":
      guard let args = call.arguments as? [String: Any],
        (Set(args.keys) == ["pending", "failed", "notifyOnPause", "resumeRequested"] ||
          Set(args.keys) == ["pending", "failed", "notifyOnPause", "resumeRequested", "updatesRequested",
            "updateEarliestMillis", "updateRemaining", "updateFailed", "notifyUpdatePause"]),
        let pending = args["pending"] as? Int, let failed = args["failed"] as? Int,
        let notify = args["notifyOnPause"] as? Bool, let resume = args["resumeRequested"] as? Bool else {
        result(FlutterError(code: "invalid_summary", message: "Tóm tắt tác vụ không hợp lệ.", details: nil))
        return
      }
      let extended = args.count != 4
      guard (!extended || (args["updatesRequested"] is Bool && args["updateEarliestMillis"] is Int &&
        args["updateRemaining"] is Int && args["updateFailed"] is Int && args["notifyUpdatePause"] is Bool)),
        scheduler.update(pending: pending, failed: failed, notifyOnPause: notify, resumeRequested: resume,
          updatesRequested: args["updatesRequested"] as? Bool ?? false,
          updateEarliestMillis: args["updateEarliestMillis"] as? Int ?? 0,
          updateRemaining: args["updateRemaining"] as? Int ?? 0,
          updateFailed: args["updateFailed"] as? Int ?? 0,
          notifyUpdatePause: args["notifyUpdatePause"] as? Bool ?? false) else {
        result(FlutterError(code: "invalid_summary", message: "Tóm tắt cập nhật nền không hợp lệ.", details: nil)); return
      }
      continued.update(pending: pending, failed: failed, requested: resume)
      result(nil)
    case "completeScheduledBackground":
      guard let args = call.arguments as? [String: Any], Set(args.keys) == ["token", "success"],
        let token = args["token"] as? Int, token > 0, token <= Int(Int32.max),
        let success = args["success"] as? Bool else {
        result(FlutterError(code: "invalid_task", message: "Mã lượt chạy nền không hợp lệ.", details: nil))
        return
      }
      scheduler.complete(token: token, success: success)
      result(nil)
    case "requestNotificationPermission":
      // Only an explicit user toggle calls this method.
      notifications.requestAuthorization(options: [.alert]) { allowed, error in
        DispatchQueue.main.async {
          if error != nil {
            result(FlutterError(code: "notifications_failed", message: "Không xác định được quyền thông báo.", details: nil))
          } else { result(allowed) }
        }
      }
    case "clearNotifications":
      notificationGeneration += 1
      scheduler.disableNotices()
      clearManagedNotifications(result: result)
    case "notify":
      guard let args = call.arguments as? [String: Any], Set(args.keys) == ["kind", "completed", "failed"],
        let kind = args["kind"] as? String,
        let completed = args["completed"] as? Int, let failed = args["failed"] as? Int,
        let content = TaskNotificationSummary.content(kind: kind, completed: completed, failed: failed) else {
        result(FlutterError(code: "invalid_summary", message: "Tóm tắt tác vụ không hợp lệ.", details: nil))
        return
      }
      enqueue(content, identifier: "tachibooks.\(kind)", result: result)
    case "notifyBookUpdate":
      guard let args = call.arguments as? [String: Any], Set(args.keys) == ["bookId", "added"],
        let bookId = args["bookId"] as? String, let added = args["added"] as? Int,
        let identifier = TaskNotificationSummary.bookIdentifier(bookId),
        let content = TaskNotificationSummary.bookUpdate(bookId: bookId, added: added) else {
        result(FlutterError(code: "invalid_summary", message: "Thông báo chương mới không hợp lệ.", details: nil)); return
      }
      enqueue(content, identifier: identifier, result: result)
    case "cancelBookUpdate":
      guard let args = call.arguments as? [String: Any], Set(args.keys) == ["bookId"],
        let bookId = args["bookId"] as? String, let identifier = TaskNotificationSummary.bookIdentifier(bookId) else {
        result(FlutterError(code: "invalid_summary", message: "Mã truyện trong thông báo không hợp lệ.", details: nil)); return
      }
      clearManagedNotifications(matching: { TaskNotificationSummary.baseIdentifier($0) == identifier }, result: result)
    case "notifyUpdateCompletion":
      guard let args = call.arguments as? [String: Any], Set(args.keys) == ["checked", "added", "failed"],
        let checked = args["checked"] as? Int, let added = args["added"] as? Int, let failed = args["failed"] as? Int,
        let content = TaskNotificationSummary.updateCompletion(checked: checked, added: added, failed: failed) else {
        result(FlutterError(code: "invalid_summary", message: "Kết quả cập nhật không hợp lệ.", details: nil)); return
      }
      enqueue(content, identifier: "tachibooks.updates", result: result)
    case "notifyPausedDownloads":
      guard let args = call.arguments as? [String: Any], Set(args.keys) == ["pending", "failed"],
        let pending = args["pending"] as? Int, let failed = args["failed"] as? Int,
        let content = TaskNotificationSummary.pausedDownloads(pending: pending, failed: failed) else {
        result(FlutterError(code: "invalid_summary", message: "Tóm tắt tác vụ không hợp lệ.", details: nil))
        return
      }
      enqueue(content, identifier: "tachibooks.downloads", result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }
  private func expired() {
    let summaries: [(String, UNMutableNotificationContent?)] = [
      ("downloads", scheduler.snapshot.takeNotice()), ("updates", scheduler.snapshot.takeUpdateNotice())]
    for (kind, possible) in summaries {
      guard let content = possible else { continue }
      // add() never prompts permission. Enqueue directly while the native
      // expiration handler still has execution time, before notifying Dart.
      let generation = notificationGeneration
      let request = UNNotificationRequest(identifier: TaskNotificationSummary.requestIdentifier("tachibooks.\(kind)"), content: content, trigger: nil)
      notifications.add(request) { [weak self] _ in
        DispatchQueue.main.async {
          guard let self = self, self.notificationGeneration != generation else { return }
          self.notifications.removePendingNotificationRequests(withIdentifiers: [request.identifier])
          self.notifications.removeDeliveredNotifications(withIdentifiers: [request.identifier])
        }
      }
    }
    channel.invokeMethod("backgroundExpired", arguments: nil)
  }
  private func clearManagedNotifications(matching: @escaping (String) -> Bool = TaskNotificationSummary.recognizes, result: @escaping FlutterResult) {
    let group = DispatchGroup()
    var identifiers = Set(TaskNotificationSummary.identifiers.filter(matching))
    group.enter()
    notifications.getPendingNotificationRequests { requests in
      DispatchQueue.main.async {
        identifiers.formUnion(requests.map { $0.identifier }.filter(matching))
        group.leave()
      }
    }
    group.enter()
    notifications.getDeliveredNotifications { delivered in
      DispatchQueue.main.async {
        identifiers.formUnion(delivered.map { $0.request.identifier }.filter(matching))
        group.leave()
      }
    }
    group.notify(queue: .main) { [weak self] in
      self?.notifications.removePendingNotificationRequests(withIdentifiers: Array(identifiers))
      self?.notifications.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
      result(nil)
    }
  }
  private func enqueue(_ content: UNMutableNotificationContent, identifier: String, result: @escaping FlutterResult) {
    // No implicit permission prompt when a task finishes, including restore.
    let generation = notificationGeneration
    let deliveryIdentifier = TaskNotificationSummary.requestIdentifier(identifier)
    notifications.getNotificationSettings { [weak self] settings in
      DispatchQueue.main.async {
        guard let self = self, self.notificationGeneration == generation else { result(false); return }
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
          result(false)
          return
        }
        let request = UNNotificationRequest(identifier: deliveryIdentifier, content: content, trigger: nil)
        self.notifications.add(request) { error in
          DispatchQueue.main.async {
            if self.notificationGeneration != generation {
              self.notifications.removePendingNotificationRequests(withIdentifiers: [request.identifier])
              self.notifications.removeDeliveredNotifications(withIdentifiers: [request.identifier])
              result(false)
            } else { result(error == nil) }
          }
        }
      }
    }
  }
}
