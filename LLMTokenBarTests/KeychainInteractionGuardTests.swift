import Security
import XCTest
@testable import LLM_Token_Bar

final class KeychainInteractionGuardTests: XCTestCase {
    private struct BodyError: Error, Equatable {}

    func testBackgroundScopeDisablesInteractionAndRestoresPreviousValue() throws {
        let flag = MockInteractionFlag(initial: true)
        let guardian = KeychainInteractionGuard(flag: flag)

        let observed = try guardian.perform(.background) { flag.current }

        XCTAssertFalse(observed)
        XCTAssertTrue(flag.current)
    }

    func testUserInitiatedScopeEnablesInteractionAndRestoresPreviousValue() throws {
        let flag = MockInteractionFlag(initial: false)
        let guardian = KeychainInteractionGuard(flag: flag)

        let observed = try guardian.perform(.userInitiated) { flag.current }

        XCTAssertTrue(observed)
        XCTAssertFalse(flag.current)
    }

    func testScopeRestoresPreviousValueWhenBodyThrows() {
        let flag = MockInteractionFlag(initial: true)
        let guardian = KeychainInteractionGuard(flag: flag)

        XCTAssertThrowsError(try guardian.perform(.background) { () throws -> Void in
            XCTAssertFalse(flag.current)
            throw BodyError()
        }) { error in
            XCTAssertEqual(error as? BodyError, BodyError())
        }
        XCTAssertTrue(flag.current)
    }

    func testNestedScopesRestoreEachPreviousValue() throws {
        let flag = MockInteractionFlag(initial: true)
        let guardian = KeychainInteractionGuard(flag: flag)

        try guardian.perform(.background) {
            XCTAssertFalse(flag.current)
            let inner = try guardian.perform(.userInitiated) { flag.current }
            XCTAssertTrue(inner)
            XCTAssertFalse(flag.current)
        }
        XCTAssertTrue(flag.current)
    }

    func testReadFailureDoesNotRunBodyOrChangeFlag() {
        let flag = MockInteractionFlag(initial: true, readStatus: errSecNotAvailable)
        let guardian = KeychainInteractionGuard(flag: flag)
        var bodyRan = false

        XCTAssertThrowsError(try guardian.perform(.background) { bodyRan = true }) { error in
            XCTAssertEqual(error as? KeychainInteractionError, .readStateFailed(errSecNotAvailable))
        }
        XCTAssertFalse(bodyRan)
        XCTAssertEqual(flag.setCount, 0)
        XCTAssertTrue(flag.current)
    }

    func testSetFailureDoesNotRunBodyAndKeepsPreviousValue() {
        let flag = MockInteractionFlag(initial: true, failingSetCalls: [1])
        let guardian = KeychainInteractionGuard(flag: flag)
        var bodyRan = false

        XCTAssertThrowsError(try guardian.perform(.background) { bodyRan = true }) { error in
            XCTAssertEqual(error as? KeychainInteractionError, .setStateFailed(errSecParam))
        }
        XCTAssertFalse(bodyRan)
        XCTAssertTrue(flag.current)
    }

    func testRestoreFailureSurfacesEvenWhenBodySucceeds() {
        let flag = MockInteractionFlag(initial: true, failingSetCalls: [2])
        let guardian = KeychainInteractionGuard(flag: flag)

        XCTAssertThrowsError(try guardian.perform(.background) { 42 }) { error in
            XCTAssertEqual(error as? KeychainInteractionError, .restoreStateFailed(errSecParam))
        }
    }

    func testRestoreFailureWinsOverBodyError() {
        let flag = MockInteractionFlag(initial: true, failingSetCalls: [2])
        let guardian = KeychainInteractionGuard(flag: flag)

        XCTAssertThrowsError(try guardian.perform(.background) { () throws -> Void in throw BodyError() }) { error in
            XCTAssertEqual(error as? KeychainInteractionError, .restoreStateFailed(errSecParam))
        }
    }

    func testConcurrentScopesNeverOverlap() {
        let flag = MockInteractionFlag(initial: true)
        let guardian = KeychainInteractionGuard(flag: flag)
        let tracker = OverlapTracker()

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let mode: KeychainInteractionMode = index.isMultiple(of: 2) ? .background : .userInitiated
            _ = try? guardian.perform(mode) {
                tracker.enter(flagMatchesMode: flag.current == mode.allowsUserInteraction)
                usleep(500)
                tracker.leave()
            }
        }

        XCTAssertEqual(tracker.maxActive, 1)
        XCTAssertEqual(tracker.mismatches, 0)
        XCTAssertTrue(flag.current)
    }

    /// Exercises the real per-process Security flag through the shared guard.
    /// The body performs no Keychain item query.
    func testSharedGuardTogglesRealProcessFlagAndRestoresIt() throws {
        let realFlag = SecurityKeychainInteractionFlag()
        let before = realFlag.interactionAllowed()
        XCTAssertEqual(before.status, errSecSuccess)

        let inside = try KeychainInteractionGuard.shared.perform(.background) {
            realFlag.interactionAllowed()
        }

        XCTAssertEqual(inside.status, errSecSuccess)
        XCTAssertFalse(inside.allowed)
        XCTAssertEqual(realFlag.interactionAllowed().allowed, before.allowed)
    }
}

private final class MockInteractionFlag: KeychainInteractionFlag, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    private var setCalls = 0
    private let readStatus: OSStatus
    private let failingSetCalls: Set<Int>

    init(initial: Bool, readStatus: OSStatus = errSecSuccess, failingSetCalls: Set<Int> = []) {
        self.value = initial
        self.readStatus = readStatus
        self.failingSetCalls = failingSetCalls
    }

    var current: Bool { lock.withLock { value } }
    var setCount: Int { lock.withLock { setCalls } }

    func interactionAllowed() -> (status: OSStatus, allowed: Bool) {
        lock.withLock { (readStatus, value) }
    }

    func setInteractionAllowed(_ allowed: Bool) -> OSStatus {
        lock.withLock {
            setCalls += 1
            if failingSetCalls.contains(setCalls) { return errSecParam }
            value = allowed
            return errSecSuccess
        }
    }
}

private final class OverlapTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maxActive = 0
    private(set) var mismatches = 0

    func enter(flagMatchesMode: Bool) {
        lock.withLock {
            active += 1
            maxActive = max(maxActive, active)
            if !flagMatchesMode { mismatches += 1 }
        }
    }

    func leave() {
        lock.withLock { active -= 1 }
    }
}
