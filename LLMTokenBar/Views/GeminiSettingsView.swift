import SwiftUI

struct GeminiSettingsView: View {
    private let parser = GeminiSessionParser()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Gemini CLI")
                    .font(.title2.bold())

                Text("Gemini CLI 로컬 세션 데이터를 읽어 토큰 사용량을 표시합니다")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                cliStatusBanner
                sessionInfoView
                dataSourceInfo
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cliStatusBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(parser.isGeminiCLIInstalled ? .green : .red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(parser.isGeminiCLIInstalled ? "Gemini CLI 감지됨" : "Gemini CLI 미설치")
                    .font(.system(size: 13, weight: .medium))

                Text(parser.isGeminiCLIInstalled
                     ? "~/.gemini/ 디렉토리가 존재합니다"
                     : "Gemini CLI를 설치하고 로그인하세요")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(parser.isGeminiCLIInstalled ? .green.opacity(0.1) : .red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var sessionInfoView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("세션 데이터")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            DetailRow(
                icon: "doc.text",
                label: "세션 파일",
                value: "\(parser.sessionFileCount)개"
            )

            if let lastDate = parser.lastSessionDate {
                DetailRow(
                    icon: "clock",
                    label: "마지막 세션",
                    value: TimeFormatter.syncTimeString(from: lastDate)
                )
            }

            DetailRow(
                icon: "folder",
                label: "데이터 경로",
                value: "~/.gemini/tmp/"
            )
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var dataSourceInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text("데이터 소스 안내")
                    .font(.system(size: 12, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 4) {
                BulletText("Gemini CLI가 로컬에 저장하는 세션 로그를 파싱합니다")
                BulletText("토큰 통계 탭에서 Gemini 필터로 확인 가능합니다")
                BulletText("실시간 rate limit 조회는 지원되지 않습니다")
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
