import Foundation

struct AntigravityCommandInvocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectory: URL
    /// 자식에게 넘길 환경 변수 전체. 앱의 환경을 그대로 물려주지 않는다.
    let environment: [String: String]
    let timeout: TimeInterval
}

struct AntigravityCommandResult: Equatable, Sendable {
    /// 신호로 끝났으면 셸 관례대로 128 + 신호 번호.
    let exitStatus: Int32
    let output: Data
}

enum AntigravityCommandError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case outputLimitExceeded
    /// 자식은 끝났지만 다른 프로세스가 출력 파이프를 붙잡고 있어 출력의 끝을 확인하지 못했다.
    case incompleteOutput
}

protocol AntigravityCommandRunning: Sendable {
    func run(_ invocation: AntigravityCommandInvocation) async throws -> AntigravityCommandResult
}

/// 셸 없이 명령 하나를 실행한다. 표준 입력과 표준 오류는 버리고, 표준 출력은 상한까지만 모은다.
/// 제한 시간, 출력 초과, 작업 취소 시에는 자식에게 SIGTERM을 보내고 유예 뒤에도 살아 있으면 SIGKILL을 보낸다.
struct AntigravityProcessRunner: AntigravityCommandRunning {
    let killGrace: TimeInterval
    /// 자식이 끝난 뒤 출력의 끝(EOF)을 기다리는 시간. 손자 프로세스가 파이프를 물고 있어도 멈추지 않는다.
    let drainGrace: TimeInterval
    let maxOutputBytes: Int
    /// 테스트용 관찰 지점. 읽기 핸들러가 한 번 읽을 때마다 EOF 여부만 알린다. 데이터는 넘기지 않는다.
    let readObserver: (@Sendable (_ isEndOfOutput: Bool) -> Void)?

    init(
        killGrace: TimeInterval = Constants.Antigravity.cliKillGrace,
        drainGrace: TimeInterval = Constants.Antigravity.cliDrainGrace,
        maxOutputBytes: Int = Constants.Antigravity.maxResponseBytes,
        readObserver: (@Sendable (_ isEndOfOutput: Bool) -> Void)? = nil
    ) {
        self.killGrace = killGrace
        self.drainGrace = drainGrace
        self.maxOutputBytes = maxOutputBytes
        self.readObserver = readObserver
    }

    func run(_ invocation: AntigravityCommandInvocation) async throws -> AntigravityCommandResult {
        let execution = ProcessExecution(invocation: invocation, limits: self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        } onCancel: {
            execution.fail(CancellationError())
        }
    }
}

/// 한 번의 실행 상태. 모든 변경은 잠금 안에서 하고, continuation은 정확히 한 번만 재개한다.
/// Foundation이 terminationHandler 전에 자식을 거두므로 여기서는 waitpid를 부르지 않는다.
private final class ProcessExecution: @unchecked Sendable {
    private enum Phase {
        case pending
        case launching
        case running(pid_t)
        case exited
        case notLaunched
    }

    private let invocation: AntigravityCommandInvocation
    private let limits: AntigravityProcessRunner
    private let process = Process()
    private let reader: FileHandle
    private let pipe = Pipe()
    private let queue = DispatchQueue.global(qos: .utility)
    private let lock = NSLock()
    private let readerLock = NSLock()
    private var readerClosed = false

    private var continuation: CheckedContinuation<AntigravityCommandResult, Error>?
    private var phase = Phase.pending
    private var output = Data()
    private var exitStatus: Int32?
    private var reachedEOF = false
    private var failure: Error?
    private var completed = false

    init(invocation: AntigravityCommandInvocation, limits: AntigravityProcessRunner) {
        self.invocation = invocation
        self.limits = limits
        self.reader = pipe.fileHandleForReading
    }

    func start(_ continuation: CheckedContinuation<AntigravityCommandResult, Error>) {
        let shouldLaunch = lock.withLock {
            self.continuation = continuation
            // 시작 전에 이미 취소됐다면 실행하지 않는다.
            if failure != nil || Task.isCancelled {
                failure = failure ?? CancellationError()
                phase = .notLaunched
                return false
            }
            phase = .launching
            return true
        }
        guard shouldLaunch else { return finishIfReady() }
        launch()
    }

    /// 첫 실패만 남긴다. 자식을 멈추고, 끝나기를 유예 시간만큼만 기다린다.
    func fail(_ error: Error) {
        let isFirst = lock.withLock {
            guard failure == nil, !completed else { return false }
            failure = error
            return true
        }
        guard isFirst else { return }
        stopChild()
        queue.asyncAfter(deadline: .now() + limits.killGrace + limits.drainGrace) { [self] in
            forceFinish()
        }
        finishIfReady()
    }

    // MARK: - Launch

    private func launch() {
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        process.environment = invocation.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        reader.readabilityHandler = { [self] handle in
            guard let chunk = readChunk(from: handle) else { return }
            receive(chunk)
        }
        process.terminationHandler = { [self] finished in markExited(finished) }

        do {
            try process.run()
        } catch {
            // run()이 실패하면 terminationHandler가 불리지 않으므로 여기서 끝낸다.
            process.terminationHandler = nil
            lock.withLock {
                phase = .notLaunched
                failure = failure ?? AntigravityCommandError.launchFailed
            }
            return finishIfReady()
        }

        let cancelledDuringLaunch = lock.withLock {
            if case .launching = phase {
                phase = .running(process.processIdentifier)
            }
            return failure != nil
        }
        if cancelledDuringLaunch {
            stopChild()
        }
        queue.asyncAfter(deadline: .now() + invocation.timeout) { [self] in
            fail(AntigravityCommandError.timedOut)
        }
    }

    // MARK: - Events

    /// 닫힌 핸들에서 읽으면 예외가 나므로 닫기와 같은 잠금 안에서 읽는다. 읽기 가능 신호 뒤라 막히지 않는다.
    /// EOF 뒤에도 핸들러가 남아 있으면 빈 청크로 계속 불리므로 첫 EOF에서 떼어 낸다. 닫기는 완료 시점에 한다.
    private func readChunk(from handle: FileHandle) -> Data? {
        readerLock.withLock {
            guard !readerClosed else { return nil }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            }
            limits.readObserver?(chunk.isEmpty)
            return chunk
        }
    }

    private func receive(_ chunk: Data) {
        guard !chunk.isEmpty else {
            lock.withLock { reachedEOF = true }
            return finishIfReady()
        }
        let exceeded = lock.withLock {
            guard !completed, failure == nil else { return false }
            output.append(chunk)
            return output.count > limits.maxOutputBytes
        }
        if exceeded {
            fail(AntigravityCommandError.outputLimitExceeded)
        }
    }

    private func markExited(_ finished: Process) {
        let status = finished.terminationReason == .uncaughtSignal
            ? 128 + finished.terminationStatus
            : finished.terminationStatus
        lock.withLock {
            exitStatus = status
            phase = .exited
        }
        queue.asyncAfter(deadline: .now() + limits.drainGrace) { [self] in
            forceFinish()
        }
        finishIfReady()
    }

    // MARK: - Stopping

    /// 이 실행이 띄운 자식 하나에만 신호를 보낸다. 프로세스 그룹이나 음수 pid에는 보내지 않는다.
    private func stopChild() {
        guard case .running(let pid) = lock.withLock({ phase }), pid > 0 else { return }
        kill(pid, SIGTERM)
        queue.asyncAfter(deadline: .now() + limits.killGrace) { [self] in
            // 이미 거둬진 pid는 재사용될 수 있으므로 종료가 확인되지 않은 경우에만 보낸다.
            guard case .running(let current) = lock.withLock({ phase }), current == pid else { return }
            kill(pid, SIGKILL)
        }
    }

    // MARK: - Completion

    /// 실패는 자식이 끝났거나 실행되지 않았을 때, 성공은 종료와 EOF가 모두 왔을 때 재개한다.
    private func finishIfReady() {
        complete { phase, exited, eof, failure in
            if let failure {
                switch phase {
                case .exited, .notLaunched: return .failure(failure)
                default: return nil
                }
            }
            return exited && eof ? .success(()) : nil
        }
    }

    /// 유예 시간이 지나면 기다리던 조건과 관계없이 끝낸다.
    /// 먼저 생긴 실패를 우선하고, 종료 뒤에도 EOF가 없으면 잘렸을 수 있는 출력을 성공으로 넘기지 않는다.
    private func forceFinish() {
        complete { _, exited, eof, failure in
            if let failure { return .failure(failure) }
            guard exited else { return nil }
            return eof ? .success(()) : .failure(AntigravityCommandError.incompleteOutput)
        }
    }

    private func complete(
        _ decide: (_ phase: Phase, _ exited: Bool, _ eof: Bool, _ failure: Error?) -> Result<Void, Error>?
    ) {
        let resumption: (CheckedContinuation<AntigravityCommandResult, Error>, Result<AntigravityCommandResult, Error>)? =
            lock.withLock {
                guard !completed, let continuation,
                      let decision = decide(phase, exitStatus != nil, reachedEOF, failure) else { return nil }
                completed = true
                self.continuation = nil
                let result = decision.map { AntigravityCommandResult(exitStatus: exitStatus ?? -1, output: output) }
                return (continuation, result)
            }
        guard let (continuation, result) = resumption else { return }
        closeReader()
        continuation.resume(with: result)
    }

    private func closeReader() {
        readerLock.withLock {
            guard !readerClosed else { return }
            readerClosed = true
            reader.readabilityHandler = nil
            try? reader.close()
        }
    }
}
