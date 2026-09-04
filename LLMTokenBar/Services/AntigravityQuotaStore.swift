import Foundation

enum AntigravityConnectionStatus: Equatable, Sendable {
    /// 첫 조회가 끝나기 전. 아직 실행 여부를 모른다.
    case checking
    case notRunning
    case connected
    case error(AntigravityQuotaError)
}

/// Gemini(Antigravity) 한도 상태. 갱신은 합류시키고, 서버가 사라져도 마지막 값을 유지한다.
@MainActor
final class AntigravityQuotaStore: ObservableObject {
    @Published private(set) var summary: AntigravityQuotaSummary?
    @Published private(set) var lastFetchedAt: Date?
    @Published private(set) var planName: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var status: AntigravityConnectionStatus = .checking

    private let client: any AntigravityQuotaFetching
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?

    init(client: any AntigravityQuotaFetching = AntigravityQuotaClient()) {
        self.client = client
    }

    var isConnected: Bool { status == .connected }

    /// 서버와 끊겼지만 마지막 값을 아직 보여주고 있는 상태.
    var isStale: Bool { summary != nil && !isConnected }

    var geminiGroup: AntigravityQuotaGroup? { summary?.geminiGroup }

    var otherGroups: [AntigravityQuotaGroup] { summary?.otherGroups ?? [] }

    func sessionBucket(in group: AntigravityQuotaGroup) -> AntigravityQuotaBucket? {
        group.bucket(for: .fiveHour)
    }

    func weeklyBucket(in group: AntigravityQuotaGroup) -> AntigravityQuotaBucket? {
        group.bucket(for: .weekly)
    }

    /// 진행 중인 갱신이 있으면 새 요청은 합류시키고 취소하지 않는다.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        // 프로세스 탐색이 명령 제한 시간만큼 막힐 수 있어 메인 액터 밖에서 돌린다.
        let client = self.client
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            let outcome: Result<AntigravityQuotaFetchResult, Error>
            do {
                outcome = .success(try await client.fetchQuota())
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { self?.apply(outcome) }
        }
    }

    func startPolling(interval: TimeInterval = Constants.Antigravity.pollInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Private

    private func apply(_ outcome: Result<AntigravityQuotaFetchResult, Error>) {
        isRefreshing = false
        switch outcome {
        case .success(let result):
            summary = result.summary
            lastFetchedAt = result.summary.fetchedAt
            planName = result.planName
            status = .connected
        case .failure(let error):
            status = Self.status(for: error)
        }
    }

    private static func status(for error: Error) -> AntigravityConnectionStatus {
        switch error as? AntigravityQuotaError {
        case .serverNotRunning:
            return .notRunning
        case .some(let quotaError):
            return .error(quotaError)
        case nil:
            return .error(.unreachable)
        }
    }
}
