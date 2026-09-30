import Foundation
import Security

/// Whether a Keychain operation may show macOS authorization UI.
enum KeychainInteractionMode: Sendable, Equatable {
    /// Automatic work (polling, status checks, retries). Never shows UI.
    case background
    /// Directly triggered by a user action (Sync Credentials, saving an API key).
    case userInitiated

    var allowsUserInteraction: Bool { self == .userInitiated }
}

enum KeychainInteractionError: LocalizedError, Equatable {
    case readStateFailed(OSStatus)
    case setStateFailed(OSStatus)
    case restoreStateFailed(OSStatus)

    var status: OSStatus {
        switch self {
        case .readStateFailed(let status), .setStateFailed(let status), .restoreStateFailed(let status):
            return status
        }
    }

    var errorDescription: String? {
        switch self {
        case .readStateFailed(let status):
            return "Keychain interaction state could not be read (OSStatus \(status))"
        case .setStateFailed(let status):
            return "Keychain interaction state could not be changed (OSStatus \(status))"
        case .restoreStateFailed(let status):
            return "Keychain interaction state could not be restored (OSStatus \(status))"
        }
    }
}

/// Access to the process-wide legacy Keychain "user interaction allowed" flag.
protocol KeychainInteractionFlag: Sendable {
    func interactionAllowed() -> (status: OSStatus, allowed: Bool)
    func setInteractionAllowed(_ allowed: Bool) -> OSStatus
}

/// Serializes every app Keychain operation and scopes the interaction flag around it.
///
/// The legacy Keychain interaction flag is process-global and unsynchronized inside Security,
/// so every SecItem call in the app must run through `shared` to avoid one scope flipping the
/// flag while another query is in flight. The body must be synchronous; never hold the scope
/// across a suspension point.
final class KeychainInteractionGuard: @unchecked Sendable {
    static let shared = KeychainInteractionGuard(flag: SecurityKeychainInteractionFlag())

    private let flag: any KeychainInteractionFlag
    private let lock = NSRecursiveLock()

    init(flag: any KeychainInteractionFlag) {
        self.flag = flag
    }

    /// Runs `body` with the interaction flag set for `mode`, then restores the exact previous value.
    /// Fails closed: if the flag cannot be read or set, `body` is not executed.
    /// A restore failure is thrown even when `body` succeeded or threw.
    func perform<T>(_ mode: KeychainInteractionMode, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        let current = flag.interactionAllowed()
        guard current.status == errSecSuccess else {
            throw KeychainInteractionError.readStateFailed(current.status)
        }

        let setStatus = flag.setInteractionAllowed(mode.allowsUserInteraction)
        guard setStatus == errSecSuccess else {
            _ = flag.setInteractionAllowed(current.allowed)
            throw KeychainInteractionError.setStateFailed(setStatus)
        }

        let result = Result { try body() }

        let restoreStatus = flag.setInteractionAllowed(current.allowed)
        guard restoreStatus == errSecSuccess else {
            throw KeychainInteractionError.restoreStateFailed(restoreStatus)
        }
        return try result.get()
    }
}

/// Uses the public legacy Security API. It is deprecated, but it is the only public control
/// that stops file-based (legacy) Keychain queries from showing the Allow/password dialog;
/// `kSecUseAuthenticationUIFail` and `LAContext` do not cover that route.
struct SecurityKeychainInteractionFlag: KeychainInteractionFlag {
    func interactionAllowed() -> (status: OSStatus, allowed: Bool) {
        var allowed = DarwinBoolean(false)
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        return (status, allowed.boolValue)
    }

    func setInteractionAllowed(_ allowed: Bool) -> OSStatus {
        SecKeychainSetUserInteractionAllowed(allowed)
    }
}
