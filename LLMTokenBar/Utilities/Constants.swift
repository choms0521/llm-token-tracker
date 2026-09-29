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
        // Codex CLI OAuth 자격 증명. 앱은 읽기만 하고 갱신하지 않는다(CLI 세션 보호).
        static let authPath = "\(NSHomeDirectory())/.codex/auth.json"
        // 진행 중인 세션 없이도 최신 사용량을 주는 전용 엔드포인트. 모델 요청이 아니라 quota를 소모하지 않는다.
        static let liveUsageURL = "https://chatgpt.com/backend-api/wham/usage"
        // 주간 창(7일)보다 오래된 세션 로그는 한도 표시에 쓸모가 없으므로 하루 여유를 두고 잘라낸다.
        static let rateLimitLookbackDays = 8
        static let rateLimitLookback: TimeInterval = TimeInterval(rateLimitLookbackDays) * 24 * 3600
        // 변경된 파일만 다시 읽으므로 짧은 주기로 폴링해도 부담이 없다.
        static let rateLimitPollInterval: TimeInterval = 60
        // 실시간 API는 네트워크 호출이므로 다른 네트워크 공급자와 같은 완만한 주기로 폴링한다.
        static let liveUsagePollInterval: TimeInterval = 600
        static let fullUtilizationPercent: Double = 100
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
        /// 조회마다 agy CLI를 새로 띄우며 한 번에 약 6~7초 걸린다. 매분 띄우지 않도록 5분으로 두고, 팝오버의 수동 갱신은 즉시 실행한다.
        static let pollInterval: TimeInterval = 300
        /// agy CLI를 찾지 못했을 때의 재시도 간격. 팝오버를 열면 즉시 다시 조회한다.
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
        /// 한도 보고서를 텍스트로 출력하고 끝나는 고정 인자. 사용자 입력은 섞지 않는다.
        static let usageArguments = ["--print", "/usage"]
        /// 실측 약 6초. 네트워크가 느린 경우를 위해 두 배 넘게 잡는다.
        static let cliTimeout: TimeInterval = 15
        /// SIGTERM 뒤 SIGKILL까지 기다리는 시간.
        static let cliKillGrace: TimeInterval = 1
        /// 자식이 끝난 뒤 남은 출력을 기다리는 시간.
        static let cliDrainGrace: TimeInterval = 0.5
        static let fallbackExecutableDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
        /// 앱 환경에 PATH가 없을 때 자식에게 넘길 기본값.
        static let fallbackSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"
        /// agy에 물려줄 환경 변수. HOME과 PATH는 따로 채운다. 프록시와 인증서 설정은 사내망에서 CLI가 서버에 닿는 데 필요하다.
        static let inheritedEnvironmentKeys: Set<String> = [
            "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
            "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy", "SSL_CERT_FILE",
        ]
    }
}
