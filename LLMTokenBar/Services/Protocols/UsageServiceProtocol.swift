import Foundation

protocol UsageServiceProtocol {
    var provider: Provider { get }
    func fetchUsage() async throws -> UsageData
}
