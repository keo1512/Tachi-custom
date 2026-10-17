import UIKit
import XCTest
@testable import Runner

final class TaskPlatformBridgeTests: XCTestCase {
  func testContinuedDownloadIdentifierIsPermittedAndUsesApplicationBundlePrefix() async {
    await MainActor.run {
      let identifier = TaskContinuedDownloads.identifier
      XCTAssertTrue(identifier.hasPrefix((Bundle.main.bundleIdentifier ?? "missing") + "."))
      let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
      XCTAssertTrue(permitted?.contains(identifier) == true)
      XCTAssertNotEqual(identifier, TaskBackgroundScheduler.identifier)
    }
  }
  func testUniqueNotificationDeliveriesRetainLegacyTapCompatibilityAndIsolateLateCleanup() {
    for base in TaskNotificationSummary.identifiers {
      let old = TaskNotificationSummary.requestIdentifier(base), next = TaskNotificationSummary.requestIdentifier(base)
      XCTAssertNotEqual(old, next)
      XCTAssertEqual(TaskNotificationSummary.baseIdentifier(old), base)
      XCTAssertEqual(TaskNotificationSummary.baseIdentifier(next), base)
      XCTAssertTrue(TaskNotificationSummary.recognizes(old))
      XCTAssertEqual(TaskNotificationSummary.destination(identifier: old, userInfo: ["task": base == "tachibooks.downloads" ? "downloads" : "updates"])?.host, "tasks")
      XCTAssertTrue(TaskNotificationSummary.recognizes(base))
      XCTAssertFalse(TaskNotificationSummary.recognizes(old + "\n"))
      XCTAssertFalse(TaskNotificationSummary.recognizes(old + ".extra"))
    }
    let bookId = "Truyện / tên % ký tự"
    let base = TaskNotificationSummary.bookIdentifier(bookId)!
    let first = TaskNotificationSummary.requestIdentifier(base), second = TaskNotificationSummary.requestIdentifier(base)
    XCTAssertNotEqual(first, second)
    let info: [String: String] = ["task": "book-update", "bookId": bookId]
    XCTAssertEqual(TaskNotificationSummary.destination(identifier: first, userInfo: info)?.host, "notification-book")
    XCTAssertEqual(TaskNotificationSummary.destination(identifier: base, userInfo: info)?.host, "notification-book")
    XCTAssertNil(TaskNotificationSummary.destination(identifier: first, userInfo: ["task": "book-update", "bookId": "another"]))
    XCTAssertNil(TaskNotificationSummary.destination(identifier: first + "\n", userInfo: info))
    XCTAssertNil(TaskNotificationSummary.destination(identifier: first, userInfo: ["task": "book-update", "bookId": bookId, "url": "https://unexpected.test"]))
  }
  func testBookNotificationUsesHashedIdentifierAndStrictOpaqueDestination() {
    for id in ["Việt/ID%..", ".", "..", "https://source.test/path"] {
      let identifier = TaskNotificationSummary.bookIdentifier(id)!
      XCTAssertTrue(TaskNotificationSummary.recognizes(identifier))
      XCTAssertEqual(identifier.count, "tachibooks.update-book.".count + 64)
      let content = TaskNotificationSummary.bookUpdate(bookId: id, added: 2)!
      XCTAssertEqual(content.userInfo.count, 2)
      XCTAssertEqual(content.body, "Có 2 chương mới. Chạm để mở truyện trong thư viện.")
      let url = TaskNotificationSummary.destination(identifier: identifier, userInfo: content.userInfo)!
      XCTAssertEqual(url.host, "notification-book")
      XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding, "/" + id)
      XCTAssertNil(TaskNotificationSummary.destination(identifier: identifier, userInfo: ["task": "book-update", "bookId": "different"]))
      XCTAssertNil(TaskNotificationSummary.destination(identifier: identifier, userInfo: ["task": "book-update", "bookId": id, "route": "/read/private"]))
    }
    XCTAssertNil(TaskNotificationSummary.bookIdentifier("bad\nID"))
    XCTAssertNil(TaskNotificationSummary.bookUpdate(bookId: "b", added: 0))
    XCTAssertNil(TaskNotificationSummary.bookUpdate(bookId: "b", added: 1_000_001))
    XCTAssertNotNil(TaskNotificationSummary.updateCompletion(checked: 3, added: 0, failed: 0))
    XCTAssertNil(TaskNotificationSummary.updateCompletion(checked: 0, added: 0, failed: 0))
  }
  func testFiniteLeaseEndsExactlyOnceOnExpiration() {
    MainActor.assumeIsolated {
      var expiration: (() -> Void)?
      var starts = 0
      var ended: [UIBackgroundTaskIdentifier] = []
      let lease = TaskBackgroundLease(start: { callback in
        starts += 1
        expiration = callback
        return UIBackgroundTaskIdentifier(rawValue: 42)
      }, finish: { ended.append($0) })
      var callbacks = 0
      lease.onExpired = { callbacks += 1 }
      XCTAssertTrue(lease.begin())
      XCTAssertTrue(lease.begin())
      XCTAssertEqual(starts, 1)
      expiration?()
      expiration?()
      lease.end()
      XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 42)])
      XCTAssertEqual(callbacks, 1)
      XCTAssertEqual(lease.identifier, .invalid)
    }
  }
  func testDeniedLeaseDoesNotEndAnInvalidIdentifier() {
    MainActor.assumeIsolated {
      var ended = false
      let lease = TaskBackgroundLease(start: { _ in .invalid }, finish: { _ in ended = true })
      XCTAssertFalse(lease.begin())
      lease.end()
      XCTAssertFalse(ended)
    }
  }
  func testOldExpirationCannotEndAReplacementLease() {
    MainActor.assumeIsolated {
      var handlers: [() -> Void] = []
      var ended: [UIBackgroundTaskIdentifier] = []
      let lease = TaskBackgroundLease(start: { callback in
        handlers.append(callback)
        return UIBackgroundTaskIdentifier(rawValue: handlers.count)
      }, finish: { ended.append($0) })
      XCTAssertTrue(lease.begin())
      lease.end()
      XCTAssertTrue(lease.begin())
      handlers[0]()
      XCTAssertEqual(lease.identifier, UIBackgroundTaskIdentifier(rawValue: 2))
      handlers[1]()
      XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 1), UIBackgroundTaskIdentifier(rawValue: 2)])
    }
  }
  func testNotificationsAcceptOnlyBoundedNumericSummaries() {
    XCTAssertNil(TaskNotificationSummary.content(kind: "title", completed: 1, failed: 0))
    XCTAssertNil(TaskNotificationSummary.content(kind: "downloads", completed: -1, failed: 0))
    XCTAssertNil(TaskNotificationSummary.content(kind: "downloads", completed: 0, failed: 0))
    let content = TaskNotificationSummary.content(kind: "downloads", completed: 3, failed: 1)
    XCTAssertEqual(content?.body, "Đã tải 3 chương; 1 chương cần thử lại.")
    XCTAssertEqual(content?.userInfo["task"] as? String, "downloads")
    XCTAssertNil(content?.sound)
  }
  func testPausedSummaryAndTapCarryOnlyAnAllowlistedTab() {
    let content = TaskNotificationSummary.pausedDownloads(pending: 7, failed: 2)
    XCTAssertEqual(content?.body, "Còn 7 chương chờ tải; 2 chương cần thử lại. Mở app để tiếp tục.")
    XCTAssertEqual(content?.userInfo.count, 1)
    XCTAssertNil(TaskNotificationSummary.pausedDownloads(pending: 0, failed: 0))
    XCTAssertNil(TaskNotificationSummary.pausedDownloads(pending: 1_000_001, failed: 0))
    XCTAssertEqual(TaskNotificationSummary.destination(identifier: "tachibooks.downloads", userInfo: ["task": "downloads"])?.absoluteString,
      "tachibooks://tasks/downloads")
    XCTAssertNil(TaskNotificationSummary.destination(identifier: "tachibooks.updates", userInfo: ["task": "downloads"]))
    XCTAssertNil(TaskNotificationSummary.destination(identifier: "tachibooks.downloads", userInfo: ["task": "/read/private"]))
    XCTAssertNil(TaskNotificationSummary.destination(identifier: "tachibooks.downloads", userInfo: ["task": "downloads", "url": "https://private.test"]))
  }
  func testNativePauseSnapshotRefreshesCountsAndConsumesOneNoticeWithoutDart() {
    MainActor.assumeIsolated {
      let snapshot = TaskPauseSnapshot()
      XCTAssertTrue(snapshot.update(pending: 7, failed: 2, notifyOnPause: true, resumeRequested: true))
      snapshot.arm()
      XCTAssertTrue(snapshot.update(pending: 4, failed: 1, notifyOnPause: true, resumeRequested: true))
      XCTAssertEqual(snapshot.takeNotice()?.body,
        "Còn 4 chương chờ tải; 1 chương cần thử lại. Mở app để tiếp tục.")
      XCTAssertNil(snapshot.takeNotice())
      XCTAssertFalse(snapshot.update(pending: -1, failed: 0, notifyOnPause: true, resumeRequested: true))
      XCTAssertEqual(snapshot.pending, 4)
      snapshot.arm()
      snapshot.disableNotice()
      XCTAssertNil(snapshot.takeNotice())
      XCTAssertTrue(snapshot.resumeRequested) // Turning notices off does not cancel authorized work.
      snapshot.invalidate()
      XCTAssertFalse(snapshot.resumeRequested)
    }
  }
  func testNativePauseSnapshotCannotRearmAnOldPrivateSessionOrEmptyQueue() {
    MainActor.assumeIsolated {
      let snapshot = TaskPauseSnapshot()
      snapshot.update(pending: 2, failed: 0, notifyOnPause: true, resumeRequested: true)
      snapshot.arm()
      snapshot.update(pending: 2, failed: 0, notifyOnPause: false, resumeRequested: false)
      XCTAssertNil(snapshot.takeNotice())
      snapshot.arm()
      XCTAssertNil(snapshot.takeNotice())
      snapshot.update(pending: 0, failed: 2, notifyOnPause: true, resumeRequested: true)
      snapshot.arm()
      XCTAssertFalse(snapshot.resumeRequested)
      XCTAssertNil(snapshot.takeNotice())
    }
  }
  func testScheduledWindowRejectsStaleTokenAndCompletesExactlyOnce() {
    MainActor.assumeIsolated {
      var completions: [Bool] = []
      let window = TaskScheduledWindow(token: 9, finish: { completions.append($0) })
      XCTAssertFalse(window.complete(token: 8, success: true))
      XCTAssertTrue(window.complete(token: 9, success: false))
      XCTAssertFalse(window.complete(token: 9, success: true))
      XCTAssertEqual(completions, [false])
      XCTAssertTrue(window.completed)
    }
  }
  func testUpdateOnlySnapshotKeepsEligibilityAndNumericExpiryNoticeWithoutDart() {
    MainActor.assumeIsolated {
      let snapshot = TaskPauseSnapshot()
      XCTAssertTrue(snapshot.update(pending: 0, failed: 0, notifyOnPause: false, resumeRequested: false,
        updatesRequested: true, updateEarliestMillis: 1_780_000_000_000))
      XCTAssertTrue(snapshot.eligible)
      XCTAssertFalse(snapshot.resumeRequested)
      snapshot.arm()
      XCTAssertTrue(snapshot.update(pending: 0, failed: 0, notifyOnPause: false, resumeRequested: false,
        updatesRequested: true, updateEarliestMillis: 1_780_000_000_000,
        updateRemaining: 12, updateFailed: 2, notifyUpdatePause: true))
      let content = snapshot.takeUpdateNotice()
      XCTAssertEqual(content?.body, "Còn 12 truyện chưa kiểm tra; 2 truyện cần thử lại. Mở app để tiếp tục.")
      XCTAssertEqual(content?.userInfo as? [String: String], ["task": "updates"])
      XCTAssertNil(snapshot.takeUpdateNotice())
      XCTAssertFalse(snapshot.update(pending: 0, failed: 0, notifyOnPause: false, resumeRequested: false,
        updatesRequested: true, updateEarliestMillis: -1))
      snapshot.disableNotice()
      XCTAssertTrue(snapshot.eligible)
      XCTAssertNil(snapshot.takeUpdateNotice())
      snapshot.invalidate()
      XCTAssertFalse(snapshot.eligible)
    }
  }
}
