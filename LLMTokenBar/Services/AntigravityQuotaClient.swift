import Foundation

protocol AntigravityQuotaFetching: Sendable {
    func fetchQuota() async throws -> AntigravityQuotaFetchResult
}

/// agy 언어 서버의 로컬 RPC로 한도를 조회한다. 인증 헤더는 필요 없다.
/// 최악의 경우 프로세스 탐색(명령 2회 × commandTimeout)과 엔드포인트 수 × requestTimeout만큼 걸린다.
final class AntigravityQuotaClient: AntigravityQuotaFetching {
    private let locator: any AntigravityEndpointLocating
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let refreshDeadline: TimeInterval

    init(
        locator: any AntigravityEndpointLocating = AntigravityServerLocator(),
        now: @escaping @Sendable () -> Date = Date.init,
        protocolClasses: [AnyClass]? = nil,
        refreshDeadline: TimeInterval = Constants.Antigravity.refreshDeadline
    ) {
        self.locator = locator
        self.now = now
        self.refreshDeadline = refreshDeadline
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Constants.Antigravity.requestTimeout
        configuration.timeoutIntervalForResource = Constants.Antigravity.requestTimeout
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        self.session = URLSession(configuration: configuration, delegate: LoopbackSessionDelegate(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func fetchQuota() async throws -> AntigravityQuotaFetchResult {
        let endpoints = locator.locateEndpoints()
        guard !endpoints.isEmpty else { throw AntigravityQuotaError.serverNotRunning }

        let deadline = Date().addingTimeInterval(refreshDeadline)
        var failure = AntigravityQuotaError.unreachable
        for endpoint in endpoints {
            // 전체 제한 시간을 넘기면 남은 엔드포인트는 시도하지 않고 지금까지의 오류를 돌려준다.
            guard Date() < deadline else { break }
            do {
                return try await fetch(from: endpoint)
            } catch let error as AntigravityQuotaError {
                failure = Self.moreInformative(error, than: failure)
            } catch {
                // URLError 같은 연결 실패는 unreachable로 본다.
            }
        }
        throw failure
    }

    private func fetch(from endpoint: URL) async throws -> AntigravityQuotaFetchResult {
        let data = try await post(Constants.Antigravity.quotaSummaryRPC, to: endpoint)
        let summary = try AntigravityQuotaParser.parseSummary(data, fetchedAt: now())
        let planName = await fetchPlanName(from: endpoint)
        return AntigravityQuotaFetchResult(summary: summary, planName: planName)
    }

    /// 플랜 이름은 부가 정보라 실패해도 한도 조회를 막지 않는다.
    private func fetchPlanName(from endpoint: URL) async -> String? {
        guard let data = try? await post(Constants.Antigravity.userStatusRPC, to: endpoint) else { return nil }
        return AntigravityQuotaParser.parsePlanName(data)
    }

    private func post(_ rpc: String, to endpoint: URL) async throws -> Data {
        let request = try Self.makeRequest(rpc, endpoint: endpoint)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AntigravityQuotaError.unreachable }

        let body = try await Self.collect(bytes, expectedLength: http.expectedContentLength)
        guard http.statusCode == 200 else {
            let message = AntigravityQuotaParser.errorMessage(in: body) ?? "HTTP \(http.statusCode)"
            throw AntigravityQuotaError.badResponse(message)
        }
        return body
    }

    private static func makeRequest(_ rpc: String, endpoint: URL) throws -> URLRequest {
        guard let url = URL(string: Constants.Antigravity.rpcPath + rpc, relativeTo: endpoint)?.absoluteURL else {
            throw AntigravityQuotaError.unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        // forceRefresh는 보내지 않는다. 60초 폴링이 상류 갱신을 강제하면 안 된다.
        request.httpBody = Data("{}".utf8)
        return request
    }

    /// 본문을 받으면서 크기 제한을 검사한다. 제한을 넘기는 순간 수신을 멈추고 실패로 처리한다.
    private static func collect(_ bytes: URLSession.AsyncBytes, expectedLength: Int64) async throws -> Data {
        let limit = Constants.Antigravity.maxResponseBytes
        let oversize = AntigravityQuotaError.badResponse("response exceeds \(limit) bytes")
        guard expectedLength <= Int64(limit) else { throw oversize }

        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            guard body.count <= limit else { throw oversize }
        }
        return body
    }

    /// 서버가 돌려준 오류가 연결 실패보다 원인을 더 잘 설명하므로 우선한다.
    private static func moreInformative(
        _ new: AntigravityQuotaError,
        than current: AntigravityQuotaError
    ) -> AntigravityQuotaError {
        if case .badResponse = current {
            return current
        }
        return new
    }
}

/// 자체 서명 인증서를 받아들일지 정하는 순수 규칙. 루프백 호스트의 서버 신뢰 검증에만 허용한다.
enum LoopbackTrustPolicy {
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost"]

    static func shouldAccept(host: String, authenticationMethod: String) -> Bool {
        authenticationMethod == NSURLAuthenticationMethodServerTrust && loopbackHosts.contains(host)
    }
}

/// 루프백 자체 서명 인증서만 허용하고, 리다이렉트는 따라가지 않는다.
private final class LoopbackSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard LoopbackTrustPolicy.shouldAccept(host: space.host, authenticationMethod: space.authenticationMethod),
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
