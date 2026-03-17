import Foundation

protocol AuthServiceProtocol {
    var provider: Provider { get }
    func loadCredentials() async throws -> String // Returns access token
    func reloadCredentials() async throws -> String
    func getSyncStatus() async -> SyncStatus
}
