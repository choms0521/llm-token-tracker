import Foundation

protocol AntigravityEndpointLocating: Sendable {
    func locateEndpoints() -> [URL]
}

/// 실행 중인 agy 프로세스가 여는 수신 포트를 찾는다 (pgrep → lsof).
/// 데스크톱 Antigravity IDE의 언어 서버는 --csrf_token 인자로 받은 토큰 헤더가 필요하므로 여기서는 다루지 않는다.
struct AntigravityServerLocator: AntigravityEndpointLocating {
    typealias CommandRunner = @Sendable (_ path: String, _ arguments: [String]) -> String

    private let commandRunner: CommandRunner

    init(commandRunner: @escaping CommandRunner = AntigravityServerLocator.runProcess) {
        self.commandRunner = commandRunner
    }

    func locateEndpoints() -> [URL] {
        let pgrepOutput = commandRunner(
            Constants.Antigravity.pgrepPath,
            ["-x", Constants.Antigravity.processName]
        )
        let pids = Self.parsePIDs(pgrepOutput)
        guard !pids.isEmpty else { return [] }

        let pidList = pids.map(String.init).joined(separator: ",")
        // -b: 커널에서 막힐 수 있는 호출을 피한다. -w: 경고 출력을 끈다.
        let lsofOutput = commandRunner(
            Constants.Antigravity.lsofPath,
            ["-nP", "-b", "-w", "-a", "-p", pidList, "-iTCP", "-sTCP:LISTEN", "-Fn"]
        )
        return Self.endpoints(for: Self.parseListeningPorts(lsofOutput))
    }

    static func parsePIDs(_ output: String) -> [Int] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// lsof -Fn 출력에서 루프백으로 닿을 수 있는 수신 포트만 순서대로 뽑는다.
    /// 루프백 주소와 와일드카드(*, 0.0.0.0, [::])는 받고, 특정 원격 주소는 거른다.
    static func parseListeningPorts(_ output: String) -> [Int] {
        var seen = Set<Int>()
        var ports: [Int] = []
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("n") {
            let address = line.dropFirst()
            guard Self.isReachableOnLoopback(address),
                  let port = Self.port(in: address),
                  seen.insert(port).inserted else { continue }
            ports.append(port)
        }
        return ports
    }

    /// 낮은 포트부터 maxProbedPorts개까지, 포트마다 https를 먼저 둔다. 평문 포트에 보낸 TLS 요청은
    /// 즉시 실패하지만, TLS 포트에 보낸 평문 요청은 요청 제한 시간까지 기다리기 때문이다.
    static func endpoints(for ports: [Int]) -> [URL] {
        ports.sorted().prefix(Constants.Antigravity.maxProbedPorts).flatMap { port in
            ["https", "http"].compactMap { URL(string: "\($0)://127.0.0.1:\(port)") }
        }
    }

    /// 외부 명령을 실행하고 표준 출력을 돌려준다.
    /// commandTimeout 안에 끝나지 않으면 자식을 종료시키고 그때까지 읽은 출력만 돌려준다.
    static func runProcess(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let output = ProcessOutputBuffer()
        // 출력의 끝(빈 청크)을 완료 신호로 삼는다. 읽기는 이 핸들러 한 곳에서만 하므로 순서가 섞이지 않는다.
        let finished = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                finished.signal()
            } else {
                output.append(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            return ""
        }

        if finished.wait(timeout: .now() + Constants.Antigravity.commandTimeout) == .timedOut {
            // 제한 시간을 넘긴 자식은 강제로 멈추고, 읽기 쪽 파이프를 닫아 아무것도 대기 상태로 남지 않게 한다.
            Self.forceStop(process)
            reader.readabilityHandler = nil
            try? reader.close()
            return output.string
        }

        // 자식이 파이프를 닫았으니 곧 종료된다. 좀비로 남지 않게 거둔다.
        process.waitUntilExit()
        return output.string
    }

    private static func forceStop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(Constants.Antigravity.commandKillGrace)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: Constants.Antigravity.commandPollInterval)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func isReachableOnLoopback(_ address: Substring) -> Bool {
        let reachablePrefixes = ["127.0.0.1:", "[::1]:", "localhost:", "*:", "0.0.0.0:", "[::]:"]
        return reachablePrefixes.contains { address.hasPrefix($0) }
    }

    private static func port(in address: Substring) -> Int? {
        guard let separator = address.lastIndex(of: ":") else { return nil }
        return Int(address[address.index(after: separator)...])
    }
}

/// 백그라운드 큐에서 읽은 표준 출력을 모으는 잠금 상자.
private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var string: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
