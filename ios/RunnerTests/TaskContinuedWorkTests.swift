import Foundation
import UIKit
import XCTest
@testable import Runner

@MainActor
private final class FakeContinuedWorkHandle: TaskContinuedWorkHandle {
  var onExpiration: (() -> Void)?
  var reports: [(Int64, Int64, String, String)] = []
  var completions: [Bool] = []
  func report(completed: Int64, total: Int64, title: String, subtitle: String) {
    reports.append((completed, total, title, subtitle))
  }
  func complete(success: Bool) { completions.append(success) }
}

@MainActor
private final class FakeContinuedWorkAdapter: TaskContinuedWorkAdapter {
  var supported = true, enabled = true, accepted = true
  var submissions: [(String, TaskContinuedWorkSnapshot)] = []
  var launches: [(TaskContinuedWorkHandle) -> Void] = []
  var cancellations: [String] = []
  func submit(token: String, snapshot: TaskContinuedWorkSnapshot,
    launch: @escaping (TaskContinuedWorkHandle) -> Void) -> Bool {
    submissions.append((token, snapshot)); launches.append(launch)
    return accepted
  }
  func cancel(token: String) { cancellations.append(token) }
}

final class TaskContinuedWorkTests: XCTestCase {
  private func arguments() -> [String: Any] {
    ["operation": "updates", "state": "running", "completed": 8, "total": 190,
      "failed": 1, "sequence": 0, "sessionId": "session_1"]
  }
  private func snapshot(_ sequence: Int, session: String = "session_1", operation: String = "updates",
    state: String = "running", completed: Int = 8, total: Int = 190, failed: Int = 1) -> TaskContinuedWorkSnapshot {
    TaskContinuedWorkSnapshot(operation: operation, state: state, completed: completed,
      total: total, failed: failed, sequence: sequence, sessionID: session)
  }
  func testExactPayloadRejectsPrivateFieldsInvalidEnumsSessionsAndNumbers() {
    XCTAssertNotNil(TaskContinuedWorkSnapshot.parse(arguments()))
    for extra in ["title", "url", "account", "error", "bookId"] {
      var args = arguments(); args[extra] = "private"
      XCTAssertNil(TaskContinuedWorkSnapshot.parse(args))
    }
    let invalid: [Any] = [true, -1, 1_000_001, 0.5, "1", NSNull()]
    for key in ["completed", "total", "failed", "sequence"] {
      for value in invalid {
        var args = arguments(); args[key] = value
        XCTAssertNil(TaskContinuedWorkSnapshot.parse(args))
      }
    }
    for session in ["", "id\n", "mã_truyện", "https://source.test", String(repeating: "a", count: 129)] {
      var args = arguments(); args["sessionId"] = session
      XCTAssertNil(TaskContinuedWorkSnapshot.parse(args))
    }
    for (key, value) in [("operation", "source"), ("state", "idle")] {
      var args = arguments(); args[key] = value
      XCTAssertNil(TaskContinuedWorkSnapshot.parse(args))
    }
    var args = arguments(); args["failed"] = 9
    XCTAssertNil(TaskContinuedWorkSnapshot.parse(args))
    args = arguments(); args["completed"] = 191
    XCTAssertNil(TaskContinuedWorkSnapshot.parse(args))
    XCTAssertNil(TaskContinuedWorkSnapshot.boolean(1))
    XCTAssertEqual(TaskContinuedWorkSnapshot.boolean(true), true)
  }
  @MainActor
  func testAllOperationsUseNativeProgressTitlesAndOnlyOneRequestPerRun() {
    for operation in ["downloads", "updates", "backup"] {
      let adapter = FakeContinuedWorkAdapter()
      let controller = TaskContinuedWorkController(adapter: adapter, foreground: { true })
      let pending = controller.update(snapshot(0, operation: operation))
      XCTAssertEqual(pending["deferred"], true)
      XCTAssertEqual(adapter.submissions.count, 1)
      let task = FakeContinuedWorkHandle(); adapter.launches[0](task)
      for sequence in 1...5 { _ = controller.update(snapshot(sequence, operation: operation, completed: sequence + 8)) }
      XCTAssertEqual(adapter.submissions.count, 1)
      XCTAssertEqual(task.reports.last?.0, 13_000)
      XCTAssertEqual(task.reports.last?.1, 190_000)
      XCTAssertFalse(task.reports.last?.2.isEmpty ?? true)
      XCTAssertTrue(task.reports.last?.3.hasPrefix("13 / 190") == true)
      XCTAssertTrue(controller.running)
    }
  }
  @MainActor
  func testBackgroundCannotSubmitButExistingForegroundGrantCanReport() {
    let adapter = FakeContinuedWorkAdapter(); var foreground = false
    let controller = TaskContinuedWorkController(adapter: adapter, foreground: { foreground })
    XCTAssertEqual(controller.update(snapshot(0))["deferred"], true)
    XCTAssertTrue(adapter.submissions.isEmpty)
    foreground = true
    _ = controller.update(snapshot(1))
    let task = FakeContinuedWorkHandle(); adapter.launches[0](task)
    foreground = false
    _ = controller.update(snapshot(2, completed: 9))
    XCTAssertEqual(task.reports.last?.0, 9_000)
    XCTAssertEqual(adapter.submissions.count, 1)
  }
  @MainActor
  func testRejectedSubmissionDoesNotLoopAndNewSessionCanTry() {
    let adapter = FakeContinuedWorkAdapter(); adapter.accepted = false
    let controller = TaskContinuedWorkController(adapter: adapter, foreground: { true })
    _ = controller.update(snapshot(0))
    for sequence in 1...20 { _ = controller.update(snapshot(sequence)) }
    XCTAssertEqual(adapter.submissions.count, 1)
    XCTAssertEqual(controller.diagnosticState["continuedProcessingSubmitFailed"], 1)
    adapter.accepted = true
    _ = controller.update(snapshot(21, session: "new_run"))
    XCTAssertEqual(adapter.submissions.count, 2)
    XCTAssertNotEqual(adapter.submissions[0].0, adapter.submissions[1].0)
    XCTAssertTrue(adapter.submissions.allSatisfy { $0.0.hasPrefix(String(TaskContinuedDownloads.workIdentifier.dropLast())) })
  }
  @MainActor
  func testUnsupportedOrDisabledUsesFallbackWithoutRequest() {
    for supported in [false, true] {
      let adapter = FakeContinuedWorkAdapter(); adapter.supported = supported; adapter.enabled = false
      let controller = TaskContinuedWorkController(adapter: adapter, foreground: { true })
      let result = controller.update(snapshot(0))
      XCTAssertEqual(result["supported"], supported)
      XCTAssertEqual(result["enabled"], false)
      XCTAssertEqual(result["visible"], false)
      XCTAssertTrue(adapter.submissions.isEmpty)
    }
  }
  @MainActor
  func testStopInvalidatesExactSessionBeforeDartCallbackAndCannotRestartIt() {
    let adapter = FakeContinuedWorkAdapter()
    let controller = TaskContinuedWorkController(adapter: adapter, foreground: { true })
    _ = controller.update(snapshot(0))
    let task = FakeContinuedWorkHandle(); adapter.launches[0](task)
    let expiration = task.onExpiration
    var expired: [String] = []
    controller.onExpired = { operation, session in
      XCTAssertFalse(controller.running)
      XCTAssertEqual(task.completions, [false])
      expired.append(operation + "/" + session)
    }
    expiration?(); expiration?()
    XCTAssertEqual(expired, ["updates/session_1"])
    _ = controller.update(snapshot(1))
    XCTAssertEqual(adapter.submissions.count, 1)
    _ = controller.update(snapshot(2, session: "new_session"))
    XCTAssertEqual(adapter.submissions.count, 2)
    expiration?()
    XCTAssertEqual(adapter.cancellations.count, 1)
  }
  @MainActor
  func testPrivacyEndRejectsLateLaunchAndStaleProgressButNewSessionWorks() {
    let adapter = FakeContinuedWorkAdapter()
    let controller = TaskContinuedWorkController(adapter: adapter, foreground: { true })
    _ = controller.update(snapshot(0))
    _ = controller.end(sequence: 1, immediate: true)
    let old = FakeContinuedWorkHandle(); adapter.launches[0](old)
    XCTAssertEqual(old.completions, [false])
    XCTAssertFalse(controller.running)
    _ = controller.update(snapshot(0, session: "stale"))
    _ = controller.update(snapshot(2))
    XCTAssertEqual(adapter.submissions.count, 1)
    _ = controller.update(snapshot(3, session: "fresh"))
    let fresh = FakeContinuedWorkHandle(); adapter.launches[1](fresh)
    XCTAssertTrue(controller.running)
    XCTAssertTrue(fresh.completions.isEmpty)
  }
  @MainActor
  func testReplacementRejectsOldLaunchAndExpirationWithoutTouchingCurrentWork() {
    let adapter = FakeContinuedWorkAdapter()
    let controller = TaskContinuedWorkController(adapter: adapter, foreground: { true })
    _ = controller.update(snapshot(0))
    _ = controller.update(snapshot(1, session: "second", operation: "backup"))
    let old = FakeContinuedWorkHandle(); adapter.launches[0](old)
    let fresh = FakeContinuedWorkHandle(); adapter.launches[1](fresh)
    XCTAssertEqual(old.completions, [false])
    XCTAssertTrue(fresh.completions.isEmpty)
    XCTAssertTrue(controller.running)
    XCTAssertFalse(controller.runningDownloads)
  }
  @MainActor
  func testSessionCannotChangeTheExecutorTargetOfStop() {
    let adapter = FakeContinuedWorkAdapter()
    let controller = TaskContinuedWorkController(adapter: adapter, foreground: { true })
    _ = controller.update(snapshot(0))
    let task = FakeContinuedWorkHandle(); adapter.launches[0](task)
    _ = controller.update(snapshot(1, operation: "backup"))
    XCTAssertEqual(adapter.submissions.count, 1)
    var expired: [String] = []
    controller.onExpired = { operation, _ in expired.append(operation) }
    task.onExpiration?()
    XCTAssertEqual(expired, ["updates"])
  }
  @MainActor
  func testDuplicateLaunchCannotReplaceLiveGrantAndCompletionBeforeLaunchFailsLateTask() {
    let adapter = FakeContinuedWorkAdapter()
    let controller = TaskContinuedWorkController(adapter: adapter, foreground: { true })
    _ = controller.update(snapshot(0))
    let first = FakeContinuedWorkHandle(); adapter.launches[0](first)
    let duplicate = FakeContinuedWorkHandle(); adapter.launches[0](duplicate)
    XCTAssertTrue(controller.running)
    XCTAssertTrue(first.completions.isEmpty)
    XCTAssertEqual(duplicate.completions, [false])
    _ = controller.update(snapshot(1, state: "completed", completed: 190, failed: 0))
    XCTAssertEqual(first.completions, [true])
    let late = FakeContinuedWorkHandle(); adapter.launches[0](late)
    XCTAssertEqual(late.completions, [false])
    XCTAssertFalse(controller.running)
  }
  @MainActor
  func testTerminalCompletionIsExactlyOnceAndSuccessRequiresNoFailedUnits() {
    for (state, completed, failed, success) in [("completed", 190, 0, true), ("completed", 190, 1, false),
      ("completed", 8, 0, false), ("paused", 8, 0, false), ("failed", 190, 1, false)] {
      let adapter = FakeContinuedWorkAdapter()
      let controller = TaskContinuedWorkController(adapter: adapter, foreground: { true })
      _ = controller.update(snapshot(0))
      let task = FakeContinuedWorkHandle(); adapter.launches[0](task)
      _ = controller.update(snapshot(1, state: state, completed: completed, failed: failed))
      _ = controller.update(snapshot(2, state: state, completed: completed, failed: failed))
      _ = controller.end(sequence: 3, immediate: true)
      XCTAssertEqual(task.completions, [success])
      XCTAssertFalse(controller.running)
    }
  }
  @MainActor
  func testDownloadsPageProgressIsBoundedAndNeverAffectsUpdates() {
    let adapter = FakeContinuedWorkAdapter()
    let controller = TaskContinuedWorkController(adapter: adapter, foreground: { true })
    _ = controller.update(snapshot(0, operation: "downloads", completed: 2, total: 10))
    let task = FakeContinuedWorkHandle(); adapter.launches[0](task)
    controller.pageProgress(completed: 3, total: 4)
    XCTAssertEqual(task.reports.last?.0, 2_750)
    controller.pageProgress(completed: 1, total: 4)
    XCTAssertEqual(task.reports.last?.0, 2_750)
    controller.pageProgress(completed: -1, total: 4)
    controller.pageProgress(completed: 4, total: 0)
    XCTAssertEqual(task.reports.last?.0, 2_750)
    _ = controller.update(snapshot(1, operation: "downloads", completed: 3, total: 10))
    XCTAssertEqual(task.reports.last?.0, 3_000)
    _ = controller.update(snapshot(2, session: "update", operation: "updates"))
    let updateTask = FakeContinuedWorkHandle(); adapter.launches[1](updateTask)
    controller.pageProgress(completed: 3, total: 4)
    XCTAssertEqual(updateTask.reports.last?.0, 8_000)
  }
  @MainActor
  func testUpdatesAndBackupGrantRetireFiniteLeaseAndIgnoreItsLateExpiration() {
    for operation in ["updates", "backup"] {
      let adapter = FakeContinuedWorkAdapter()
      let controller = TaskContinuedWorkController(adapter: adapter, foreground: { true })
      var finiteExpiration: (() -> Void)?
      var finiteEnds = 0, executionExpirations = 0
      let lease = TaskBackgroundLease(start: { callback in
        finiteExpiration = callback
        return UIBackgroundTaskIdentifier(rawValue: 1)
      }, finish: { _ in finiteEnds += 1 })
      lease.onExpired = { if !controller.running { executionExpirations += 1 } }
      controller.onWindowChanged = { running in if running { lease.end() } }
      XCTAssertTrue(lease.begin())
      _ = controller.update(snapshot(0, operation: operation))
      let task = FakeContinuedWorkHandle(); adapter.launches[0](task)
      XCTAssertTrue(controller.running)
      XCTAssertEqual(lease.identifier, .invalid)
      XCTAssertEqual(finiteEnds, 1)
      finiteExpiration?()
      XCTAssertEqual(executionExpirations, 0)
      XCTAssertTrue(task.completions.isEmpty)
    }
  }
  @MainActor
  func testGrantCloseSignalsOnceAndRemainingWorkCanAcquireNewFiniteWindow() {
    let adapter = FakeContinuedWorkAdapter()
    let controller = TaskContinuedWorkController(adapter: adapter, foreground: { true })
    var finiteExpirations: [() -> Void] = []
    var starts = 0, expired = 0
    let lease = TaskBackgroundLease(start: { callback in
      starts += 1; finiteExpirations.append(callback)
      return UIBackgroundTaskIdentifier(rawValue: starts)
    }, finish: { _ in })
    lease.onExpired = { if !controller.running { expired += 1 } }
    var windows: [Bool] = []
    controller.onWindowChanged = { running in
      windows.append(running)
      if running { lease.end() }
    }
    XCTAssertTrue(lease.begin())
    _ = controller.update(snapshot(0, operation: "backup"))
    let task = FakeContinuedWorkHandle(); adapter.launches[0](task)
    XCTAssertEqual(windows, [true])
    _ = controller.update(snapshot(1, operation: "backup", state: "completed", completed: 190, failed: 0))
    XCTAssertEqual(windows, [true, false])
    XCTAssertFalse(controller.running)
    // Dart receives the false event, resets its leased flag, and requests this
    // separate bounded window for remaining authorized downloads/updates.
    XCTAssertTrue(lease.begin())
    XCTAssertEqual(starts, 2)
    finiteExpirations[0]()
    XCTAssertEqual(expired, 0)
    finiteExpirations[1]()
    XCTAssertEqual(expired, 1)
    XCTAssertEqual(lease.identifier, .invalid)
    _ = controller.end(sequence: 2, immediate: true)
    XCTAssertEqual(windows, [true, false])
  }
}
