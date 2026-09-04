import Foundation

enum Constants {
    enum Claude {
        static let credentialsPath = "\(NSHomeDirectory())/.claude/.credentials.json"
        static let usageURL = "https://api.anthropic.com/api/oauth/usage"
        static let betaHeader = "oauth-2025-04-20"
    }

    enum Polling {
        static let successInterval: TimeInterval = 600      // 10분
        static let failureInterval: TimeInterval = 300      // 5분
        static let rateLimitBaseInterval: TimeInterval = 600 // 10분 base
        static let rateLimitMaxInterval: TimeInterval = 1800 // 30분 max
    }

    enum Gemini {
        static let sessionBasePath = "\(NSHomeDirectory())/.gemini/tmp"
        static let configPath = "\(NSHomeDirectory())/.gemini"
    }

    enum Codex {
        static let sessionBasePath = "\(NSHomeDirectory())/.codex/sessions"
        static let configPath = "\(NSHomeDirectory())/.codex"
    }

    enum MiniMax {
        static let usageURL = "https://www.minimax.io/v1/api/openplatform/coding_plan/remains"
        static let apiKeyEnvVar = "MINIMAX_API_KEY"
        // coding_plan/remains 응답의 텍스트(코딩) 플랜 모델 식별자.
        // 2026-06 기준 "general"/"video"로 내려옴.
        static let targetModelName = "general"
        // 구버전 응답 호환: 과거에는 모델명이 "MiniMax-M..." 접두사로 내려왔음.
        static let legacyModelPrefix = "MiniMax-M"
        static let modelPrefixes = ["minimax", "hailuo"]
    }

    enum Kimi {
        static let usageURL = "https://api.kimi.com/coding/v1/usages"
        static let apiKeyEnvVar = "KIMI_API_KEY"
        // Kimi Code CLI는 세션별 wire 로그에 토큰 사용량을 기록한다.
        // ~/.kimi (구버전)는 마이그레이션 이후 사용량을 남기지 않으므로 제외한다.
        static let sessionBasePath = "\(NSHomeDirectory())/.kimi-code/sessions"
        static let configPath = "\(NSHomeDirectory())/.kimi-code"
    }

    enum Keychain {
        static let serviceName = "com.llmtokenbar.credentials"
        static let claudeAccount = "claude-oauth"
        static let geminiAccount = "gemini-apikey"
        static let minimaxAccount = "minimax-apikey"
        static let kimiAccount = "kimi-apikey"
    }

    enum UI {
        static let popoverWidth: CGFloat = 320
        static let popoverHeight: CGFloat = 420
        static let settingsWidth: CGFloat = 700
        static let settingsHeight: CGFloat = 750
        /// 서버 연결이 끊긴 뒤 마지막 값을 보여줄 때의 흐림 정도.
        static let staleContentOpacity: Double = 0.55
    }
}

extension Constants {
    enum Antigravity {
        /// Antigravity CLI 프로세스 이름. 언어 서버는 이 프로세스 안에서 루프백 포트로 열린다.
        static let processName = "agy"
        static let rpcPath = "/exa.language_server_pb.LanguageServerService/"
        static let quotaSummaryRPC = "RetrieveUserQuotaSummary"
        static let userStatusRPC = "GetUserStatus"
        static let pollInterval: TimeInterval = 60
        /// agy가 없을 때의 폴링 간격. pgrep과 lsof를 매분 돌릴 이유가 없고, 팝오버를 열면 즉시 갱신한다.
        static let idlePollInterval: TimeInterval = 300
        static let requestTimeout: TimeInterval = 3
        /// pgrep, lsof 같은 외부 명령의 최대 실행 시간.
        static let commandTimeout: TimeInterval = 3
        static let commandKillGrace: TimeInterval = 0.5
        static let commandPollInterval: TimeInterval = 0.05
        static let maxResponseBytes = 1_048_576
        /// 이 시간이 지나면 새 엔드포인트 시도를 시작하지 않는다. 진행 중인 요청은 requestTimeout까지 더 걸릴 수 있다.
        static let refreshDeadline: TimeInterval = 10
        /// 낮은 포트부터 이 개수까지만 시도한다.
        static let maxProbedPorts = 4
        static let errorDetailMaxLength = 120
        /// 서버가 보낸 이름·창 문자열의 최대 길이. 화면이 깨지지 않도록 파싱 단계에서 자른다.
        static let serverStringMaxLength = 80
        static let pgrepPath = "/usr/bin/pgrep"
        static let lsofPath = "/usr/sbin/lsof"
        static let geminiBucketPrefix = "gemini-"
    }
}
