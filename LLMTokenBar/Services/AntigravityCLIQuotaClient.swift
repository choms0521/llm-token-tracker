import Foundation

/// 설치된 agy 실행 파일을 절대 경로 후보에서만 찾는다. 상대 경로 PATH 항목은 현재 디렉터리에 따라 달라지므로 쓰지 않는다.
struct AntigravityExecutableLocator: Sendable {
    private let candidates: [URL]
    private let isExecutable: @Sendable (String) -> Bool

    init(
        candidates: [URL] = AntigravityExecutableLocator.candidates(
            home: FileManager.default.homeDirectoryForCurrentUser,
            searchPath: ProcessInfo.processInfo.environment["PATH"]
        ),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.candidates = candidates
        self.isExecutable = isExecutable
    }

    func locate() -> URL? {
        candidates.first { isExecutable($0.path) }
    }

    /// ~/.local/bin, PATH의 절대 경로 항목, Homebrew 기본 경로 순서. 중복은 앞의 것만 남긴다.
    static func candidates(home: URL, searchPath: String?) -> [URL] {
        let localBin = home.appendingPathComponent(".local/bin", isDirectory: true).path
        let pathEntries = (searchPath ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        let directories = [localBin] + pathEntries + Constants.Antigravity.fallbackExecutableDirectories
        let unique = directories.reduce(into: [String]()) { result, directory in
            if !result.contains(directory) { result.append(directory) }
        }
        return unique.map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(Constants.Antigravity.processName)
        }
    }
}

/// `agy --print /usage`의 TSV 출력으로 한도를 조회한다.
/// 자격 증명 파일이나 언어 서버에는 손대지 않고, 인증은 CLI가 스스로 처리한다.
struct AntigravityCLIQuotaClient: AntigravityQuotaFetching {
    private let runner: any AntigravityCommandRunning
    private let locateExecutable: @Sendable () -> URL?
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    init(
        runner: any AntigravityCommandRunning = AntigravityProcessRunner(),
        locateExecutable: @escaping @Sendable () -> URL? = { AntigravityExecutableLocator().locate() },
        environment: [String: String] = AntigravityCLIQuotaClient.childEnvironment(
            from: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        ),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runner = runner
        self.locateExecutable = locateExecutable
        self.environment = environment
        self.now = now
    }

    func fetchQuota() async throws -> AntigravityQuotaFetchResult {
        guard let executable = locateExecutable() else { throw AntigravityQuotaError.serverNotRunning }

        let invocation = AntigravityCommandInvocation(
            executableURL: executable,
            arguments: Constants.Antigravity.usageArguments,
            // 저장소나 사용자 폴더가 아닌 곳에서 실행해 CLI가 작업 공간 파일을 읽지 않게 한다.
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: environment,
            timeout: Constants.Antigravity.cliTimeout
        )
        let result = try await run(invocation)
        // 표준 오류는 버리므로 오류 문구에는 종료 코드만 담긴다.
        guard result.exitStatus == 0 else {
            throw AntigravityQuotaError.badResponse("agy exited with status \(result.exitStatus)")
        }
        return try AntigravityUsageTSVParser.parse(String(decoding: result.output, as: UTF8.self), fetchedAt: now())
    }

    private func run(_ invocation: AntigravityCommandInvocation) async throws -> AntigravityCommandResult {
        do {
            return try await runner.run(invocation)
        } catch let error as AntigravityCommandError {
            switch error {
            case .launchFailed, .timedOut:
                throw AntigravityQuotaError.unreachable
            case .outputLimitExceeded:
                throw AntigravityQuotaError.badResponse("agy output exceeded the size limit")
            case .incompleteOutput:
                throw AntigravityQuotaError.badResponse("agy output did not finish")
            }
        }
    }

    /// CLI가 로그인 상태와 설정을 찾는 데 필요한 변수만 넘긴다. HOME은 계정 정보에서 가져온다.
    static func childEnvironment(from environment: [String: String], home: URL) -> [String: String] {
        let kept = environment.filter { Constants.Antigravity.inheritedEnvironmentKeys.contains($0.key) }
        return kept.merging([
            "HOME": home.path,
            "PATH": environment["PATH"] ?? Constants.Antigravity.fallbackSearchPath,
        ]) { _, override in override }
    }
}
