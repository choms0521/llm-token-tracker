import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: "com.llmtokenbar", category: "ClaudeKeychain")

struct SecurityCommandOutput: Equatable, Sendable {
    let exitStatus: Int32
    let stdout: Data
}

/// Reads the Claude Code CLI Keychain item through `/usr/bin/security`.
///
/// Claude Code writes and deletes its item with `/usr/bin/security`, so that tool always stays in
/// the item's ACL and partition list. An in-process `SecItemCopyMatching` depends on the app's own
/// ACL entry, which macOS drops whenever the CLI recreates the item, and the next read then asks for
/// approval again. Reading through the same tool the CLI uses avoids that repeated approval.
struct ClaudeKeychainCLIReader {
    typealias SecurityRunner = (_ arguments: [String], _ timeout: TimeInterval) -> SecurityCommandOutput?

    static let serviceName = "Claude Code-credentials"
    /// `security` exits with the low byte of the OSStatus; 44 is `errSecItemNotFound`.
    static let itemNotFoundExitStatus: Int32 = 44
    static let backgroundTimeout: TimeInterval = 5
    /// A user action may wait for the tool if macOS still shows a dialog for it.
    static let userInitiatedTimeout: TimeInterval = 10

    private let runSecurity: SecurityRunner
    private let isKeychainUnlocked: () -> Bool
    private let inProcessRead: (KeychainInteractionMode) -> ClaudeKeychainReadResult

    init(
        runSecurity: @escaping SecurityRunner = { SecurityCommandRunner().run($0, timeout: $1) },
        isKeychainUnlocked: @escaping () -> Bool = ClaudeKeychainCLIReader.defaultKeychainUnlocked,
        inProcessRead: @escaping (KeychainInteractionMode) -> ClaudeKeychainReadResult
    ) {
        self.runSecurity = runSecurity
        self.isKeychainUnlocked = isKeychainUnlocked
        self.inProcessRead = inProcessRead
    }

    /// `.background` never shows UI: a locked Keychain or a failed tool run reports that user
    /// consent is needed. `.userInitiated` falls back to the in-process read, which may prompt.
    func read(_ mode: KeychainInteractionMode) -> ClaudeKeychainReadResult {
        guard isKeychainUnlocked() else {
            // The tool would raise an unlock dialog that the app's interaction flag cannot suppress.
            return mode.allowsUserInteraction ? inProcessRead(mode) : .needsUserConsent(errSecInteractionNotAllowed)
        }

        let timeout = mode.allowsUserInteraction ? Self.userInitiatedTimeout : Self.backgroundTimeout
        let arguments = ["find-generic-password", "-s", Self.serviceName, "-w"]
        guard let output = runSecurity(arguments, timeout) else {
            logger.warning("security tool did not finish reading the Claude Code item")
            return mode.allowsUserInteraction ? inProcessRead(mode) : .needsUserConsent(errSecAuthFailed)
        }

        switch output.exitStatus {
        case 0:
            guard let data = Self.decodePassword(output.stdout) else {
                return .unavailable(errSecDecode)
            }
            return .found(data)
        case Self.itemNotFoundExitStatus:
            return .notFound
        default:
            logger.warning("security tool could not read the Claude Code item (exit \(output.exitStatus))")
            return mode.allowsUserInteraction ? inProcessRead(mode) : .needsUserConsent(errSecAuthFailed)
        }
    }

    /// `security -w` prints the password followed by a newline, or as hex when it is not printable.
    nonisolated static func decodePassword(_ output: Data) -> Data? {
        var bytes = output
        while let last = bytes.last, last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") {
            bytes.removeLast()
        }
        guard !bytes.isEmpty else { return nil }
        return decodeHex(bytes) ?? bytes
    }

    private static func decodeHex(_ bytes: Data) -> Data? {
        guard bytes.count.isMultiple(of: 2), let text = String(data: bytes, encoding: .ascii) else {
            return nil
        }
        var decoded = Data(capacity: bytes.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            decoded.append(byte)
            index = next
        }
        return decoded
    }

    static func defaultKeychainUnlocked() -> Bool {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return false }
        var status = SecKeychainStatus()
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
        return status & SecKeychainStatus(kSecUnlockStateStatus) != 0
    }
}

/// Runs `/usr/bin/security` without a shell. Standard input and error are discarded; the child is
/// terminated when it outlives the timeout. Returns nil when it cannot launch or times out.
struct SecurityCommandRunner: Sendable {
    let executableURL: URL
    let killGrace: TimeInterval

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/security"), killGrace: TimeInterval = 1) {
        self.executableURL = executableURL
        self.killGrace = killGrace
    }

    func run(_ arguments: [String], timeout: TimeInterval) -> SecurityCommandOutput? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout concurrently so a full pipe can never block the child.
        let collected = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            collected.set(pipe.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        guard drained.wait(timeout: .now() + killGrace) == .success else {
            return nil
        }
        return SecurityCommandOutput(exitStatus: process.terminationStatus, stdout: collected.value)
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.withLock { data }
    }

    func set(_ newValue: Data) {
        lock.withLock { data = newValue }
    }
}
