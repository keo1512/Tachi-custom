import Foundation
import CoreFoundation
import UIKit
import BackgroundTasks

struct TaskContinuedWorkSnapshot: Equatable {
  let operation: String, state: String
  let completed: Int, total: Int, failed: Int, sequence: Int
  let sessionID: String
  static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      ["s", "i", "l", "q", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
      number.doubleValue >= 0, number.doubleValue <= 1_000_000 else { return nil }
    return number.intValue
  }
  static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }
  static func parse(_ value: Any?) -> Self? {
    guard let args = value as? [String: Any],
      Set(args.keys) == ["operation", "state", "completed", "total", "failed", "sequence", "sessionId"],
      let operation = args["operation"] as? String, ["downloads", "updates", "backup"].contains(operation),
      let state = args["state"] as? String, ["running", "paused", "completed", "failed"].contains(state),
      let completed = integer(args["completed"]), let total = integer(args["total"]),
      let failed = integer(args["failed"]), let sequence = integer(args["sequence"]),
      failed <= completed, completed <= total,
      let session = args["sessionId"] as? String, session.utf8.count <= 128,
      session.range(of: "^[A-Za-z0-9_-]{1,128}\\z", options: .regularExpression) != nil else { return nil }
    return Self(operation: operation, state: state, completed: completed, total: total,
      failed: failed, sequence: sequence, sessionID: session)
  }
  var title: String {
    switch operation {
    case "updates": return "Cập nhật thư viện"
    case "backup": return "Sao lưu thư viện"
    default: return "Tải truyện"
    }
  }
  var subtitle: String {
    let unit = operation == "downloads" ? "chương" : operation == "updates" ? "truyện" : "tác vụ"
    return "\(completed) / \(total) \(unit)"
  }
}

@MainActor
protocol TaskContinuedWorkHandle: AnyObject {
  var onExpiration: (() -> Void)? { get set }
  func report(completed: Int64, total: Int64, title: String, subtitle: String)
  func complete(success: Bool)
}

@MainActor
protocol TaskContinuedWorkAdapter: AnyObject {
  var supported: Bool { get }
  var enabled: Bool { get }
  func submit(token: String, snapshot: TaskContinuedWorkSnapshot,
    launch: @escaping (TaskContinuedWorkHandle) -> Void) -> Bool
  func cancel(token: String)
}

@available(iOS 26.0, *)
@MainActor
private final class SystemContinuedWorkHandle: TaskContinuedWorkHandle {
  private let task: BGContinuedProcessingTask
  private var completed = false
  var onExpiration: (() -> Void)?
  init(_ task: BGContinuedProcessingTask) {
    self.task = task
    task.expirationHandler = { [weak self] in
      DispatchQueue.main.async { self?.onExpiration?() }
    }
  }
  func report(completed: Int64, total: Int64, title: String, subtitle: String) {
    guard !self.completed else { return }
    task.progress.totalUnitCount = total
    task.progress.completedUnitCount = completed
    task.updateTitle(title, subtitle: subtitle)
  }
  func complete(success: Bool) {
    guard !completed else { return }
    completed = true
    task.expirationHandler = nil
    onExpiration = nil
    if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
    task.setTaskCompleted(success: success)
  }
}

@MainActor
private final class SystemContinuedWorkAdapter: TaskContinuedWorkAdapter {
  var supported: Bool { if #available(iOS 26.0, *) { return true }; return false }
  var enabled: Bool {
    supported && (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])?
      .contains(TaskContinuedDownloads.workIdentifier) == true
  }
  func submit(token: String, snapshot: TaskContinuedWorkSnapshot,
    launch: @escaping (TaskContinuedWorkHandle) -> Void) -> Bool {
    guard #available(iOS 26.0, *), enabled else { return false }
    // Continued tasks explicitly allow dynamic registration after launch. A
    // unique concrete identifier binds every late launch to this exact run.
    guard BGTaskScheduler.shared.register(forTaskWithIdentifier: token, using: .main, launchHandler: { value in
      guard let task = value as? BGContinuedProcessingTask else { value.setTaskCompleted(success: false); return }
      launch(SystemContinuedWorkHandle(task))
    }) else { return false }
    let request = BGContinuedProcessingTaskRequest(identifier: token, title: snapshot.title, subtitle: snapshot.subtitle)
    request.strategy = .fail
    do { try BGTaskScheduler.shared.submit(request); return true }
    catch { return false }
  }
  func cancel(token: String) { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: token) }
}

/// Tracks the OS execution grant; the existing Dart executors still do all work.
/// STOP/expiration revokes the exact session before delivering cancellation.
@MainActor
final class TaskContinuedWorkController {
  private let adapter: TaskContinuedWorkAdapter
  private let foreground: () -> Bool
  private var lastSequence = -1, generation = 0
  private var snapshot: TaskContinuedWorkSnapshot?
  private var token: String?
  private var handle: TaskContinuedWorkHandle?
  private var attempted = false, submissionFailed = false
  private var stopped = Set<String>()
  private var pageFraction: Int64 = 0
  var onExpired: (String, String) -> Void = { _, _ in }
  var onWindowChanged: (Bool) -> Void = { _ in }
  var running: Bool { handle != nil }
  var runningDownloads: Bool { running && snapshot?.operation == "downloads" }
  var diagnosticState: [String: Int] {
    ["continuedProcessingRegistered": adapter.enabled ? 1 : 0,
     "continuedProcessingRequested": token != nil ? 1 : 0,
     "continuedProcessingRunning": running ? 1 : 0,
     "continuedProcessingSubmitFailed": submissionFailed ? 1 : 0]
  }
  init(adapter: TaskContinuedWorkAdapter, foreground: @escaping () -> Bool) {
    self.adapter = adapter; self.foreground = foreground
  }
  private func status(deferred: Bool = false) -> [String: Bool] {
    // visible means the system task has launched. The OS chooses whether its
    // progress appears in Dynamic Island, Lock Screen or another presentation.
    ["supported": adapter.supported, "enabled": adapter.enabled,
      "visible": running, "deferred": deferred]
  }
  func update(_ next: TaskContinuedWorkSnapshot) -> [String: Bool] {
    guard next.sequence > lastSequence else { return status() }
    lastSequence = next.sequence
    return apply(next)
  }
  func updateLegacy(_ next: TaskContinuedWorkSnapshot) { _ = apply(next) }
  func invalidate() {
    if let current = snapshot { stopped.insert(current.sessionID) }
    finish(success: false)
    snapshot = nil
  }
  func end(sequence: Int, immediate: Bool) -> [String: Bool] {
    guard sequence > lastSequence else { return status() }
    lastSequence = sequence
    // The OS owns completion UI timing; either end mode closes the grant. A
    // successful terminal update has already completed its grant beforehand.
    invalidate()
    return status()
  }
  private func apply(_ next: TaskContinuedWorkSnapshot) -> [String: Bool] {
    guard !stopped.contains(next.sessionID) else { return status() }
    // A session belongs to one executor for its entire lifetime. An unrelated
    // operation cannot take over its STOP callback merely by reusing the ID.
    if let old = snapshot, old.sessionID == next.sessionID, old.operation != next.operation { return status() }
    if let old = snapshot, old.sessionID != next.sessionID {
      stopped.insert(old.sessionID)
      finish(success: false)
      snapshot = nil
    }
    if snapshot == nil { attempted = false; submissionFailed = false; pageFraction = 0 }
    if snapshot?.completed != next.completed { pageFraction = 0 }
    snapshot = next
    guard next.state == "running", next.total > 0 else {
      stopped.insert(next.sessionID)
      report()
      finish(success: next.state == "completed" && next.failed == 0 && next.completed == next.total)
      return status()
    }
    if token != nil { report(); return status(deferred: !running) }
    guard adapter.supported, adapter.enabled, !attempted else { return status() }
    // Automatic jobs never call this API. The caller must have a fresh direct
    // user action; foreground is additionally required by the system API.
    guard foreground() else { return status(deferred: true) }
    attempted = true
    generation += 1
    let epoch = generation
    let nextToken = String(TaskContinuedDownloads.workIdentifier.dropLast()) + UUID().uuidString
    token = nextToken
    let accepted = adapter.submit(token: nextToken, snapshot: next) { [weak self] value in
      guard let self = self, self.generation == epoch, self.token == nextToken,
        self.snapshot?.sessionID == next.sessionID, self.snapshot?.state == "running", self.handle == nil else {
        value.complete(success: false); return
      }
      self.handle = value
      value.onExpiration = { [weak self, weak value] in
        guard let self = self, let value = value, self.generation == epoch,
          self.token == nextToken, self.handle === value else { return }
        self.stopped.insert(next.sessionID)
        self.finish(success: false)
        self.snapshot = nil
        self.onExpired(next.operation, next.sessionID)
      }
      self.report()
      self.onWindowChanged(true)
    }
    if !accepted {
      submissionFailed = true
      finish(success: false)
    }
    return status(deferred: token != nil && !running)
  }
  func pageProgress(completed: Int, total: Int) {
    guard snapshot?.operation == "downloads", completed >= 0, total > 0,
      completed <= total, total <= 10000 else { return }
    pageFraction = max(pageFraction, min(999, Int64(completed) * 1000 / Int64(total)))
    report()
  }
  private func report() {
    guard let current = snapshot, let handle = handle else { return }
    let total = max(1, Int64(current.total) * 1000)
    handle.report(completed: min(Int64(current.completed) * 1000 + pageFraction, total - 1),
      total: total, title: current.title, subtitle: current.subtitle)
  }
  private func finish(success: Bool) {
    // Invalidate first: cancellation may race an already-enqueued OS launch.
    generation += 1
    let oldToken = token, oldHandle = handle
    token = nil; handle = nil
    oldHandle?.onExpiration = nil
    if let oldToken = oldToken { adapter.cancel(token: oldToken) }
    oldHandle?.complete(success: success)
    if oldHandle != nil { onWindowChanged(false) }
  }
}

/// Preserves the original download/scheduler bridge while sharing one OS owner
/// with explicit download, update and backup sessions from the coordinator.
@MainActor
final class TaskContinuedDownloads {
  static let shared = TaskContinuedDownloads()
  static let identifier = "dev.tachibooks.tachiBooks.downloads.continued"
  static let workIdentifier = "dev.tachibooks.tachiBooks.work.continued.*"
  private let controller: TaskContinuedWorkController
  private var registered = false
  private var explicitOwner = false, legacyActive = false
  private var legacySession = UUID().uuidString
  private var remaining = 0, completed = 0, total = 0
  var onExpired: () -> Void = {}
  var onWorkExpired: (String, String) -> Void = { _, _ in }
  var onWindowChanged: (Bool) -> Void = { _ in }
  var running: Bool { controller.running }
  var runningDownloads: Bool { controller.runningDownloads }
  var diagnosticState: [String: Int] { controller.diagnosticState }
  init() {
    controller = TaskContinuedWorkController(adapter: SystemContinuedWorkAdapter(),
      foreground: { UIApplication.shared.applicationState == .active })
    controller.onExpired = { [weak self] operation, session in
      guard let self = self else { return }
      if self.explicitOwner { self.onWorkExpired(operation, session) } else { self.onExpired() }
    }
    controller.onWindowChanged = { [weak self] in self?.onWindowChanged($0) }
  }
  func register() {
    guard #available(iOS 26.0, *), !registered else { return }
    // Retain the old declared registration for compatibility. No work may be
    // resurrected by an old OS request without its current Dart session owner.
    registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { value in
      value.setTaskCompleted(success: false)
    }
  }
  func updateWork(_ next: TaskContinuedWorkSnapshot) -> [String: Bool] {
    claimExplicitOwner()
    return controller.update(next)
  }
  func endWork(sequence: Int, immediate: Bool) -> [String: Bool] {
    claimExplicitOwner()
    return controller.end(sequence: sequence, immediate: immediate)
  }
  private func claimExplicitOwner() {
    guard !explicitOwner else { return }
    explicitOwner = true
    controller.invalidate()
  }
  func update(pending: Int, failed: Int, requested: Bool) {
    guard !explicitOwner, pending >= 0, pending <= 1_000_000, failed >= 0, failed <= 1_000_000 else { return }
    let active = requested && pending > 0
    if active && !legacyActive {
      legacySession = UUID().uuidString; completed = 0; total = pending
    } else if active {
      if pending < remaining { completed += remaining - pending }
      if pending > remaining { total += pending - remaining }
    }
    remaining = pending; legacyActive = active
    let state = active ? "running" : pending == 0 && failed == 0 ? "completed" : "paused"
    let boundedTotal = min(total, 1_000_000)
    let processed = active ? min(completed, boundedTotal) : pending == 0 && failed == 0 ? boundedTotal : min(completed, boundedTotal)
    controller.updateLegacy(TaskContinuedWorkSnapshot(operation: "downloads", state: state,
      completed: processed, total: boundedTotal, failed: min(failed, processed), sequence: 0, sessionID: legacySession))
  }
  func pageProgress(completed: Int, total: Int) { controller.pageProgress(completed: completed, total: total) }
}
