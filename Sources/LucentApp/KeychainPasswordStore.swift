import Foundation
import Security
import CryptoKit

enum KeychainPasswordStore {
    private static let service = "com.lucent.app.smb"

    static func set(_ password: String, for id: UUID) throws {
        try setSecret(password, service: service, account: id.uuidString)
    }

    static func get(for id: UUID) throws -> String? {
        try getSecret(service: service, account: id.uuidString)
    }

    static func remove(for id: UUID) {
        removeSecret(service: service, account: id.uuidString)
    }

    static func setMetadataToken(_ token: String) throws {
        try setSecret(token, service: "com.lucent.app.metadata", account: "tmdb")
    }

    #if os(iOS) && DEBUG
    static func importDebugMetadataCredential() {
        let manager = FileManager.default
        let supportFile = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Lucent/.tmdb-import")
        let documentsFile = manager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(".tmdb-import")
        guard let file = [supportFile, documentsFile].compactMap({ $0 }).first(where: { manager.fileExists(atPath: $0.path) }) else { return }
        guard let data = try? Data(contentsOf: file),
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("api_key:"), value.count > 8 else { return }
        do {
            try setMetadataToken(value)
            try manager.removeItem(at: file)
        } catch {
            NSLog("Lucent: TMDB credential import failed (%d)", (error as NSError).code)
        }
    }
    #endif

    static func metadataToken() throws -> String? {
        try getSecret(service: "com.lucent.app.metadata", account: "tmdb")
    }

    static func setWebDAVPassword(_ password: String, for id: UUID) throws {
        try setSecret(password, service: "com.lucent.app.webdav", account: id.uuidString)
    }

    static func webDAVPassword(for id: UUID) throws -> String? {
        try getSecret(service: "com.lucent.app.webdav", account: id.uuidString)
    }

    static func removeWebDAVPassword(for id: UUID) {
        removeSecret(service: "com.lucent.app.webdav", account: id.uuidString)
    }

    static func setJellyfinToken(_ token: String, for id: UUID) throws {
        try setSecret(token, service: "com.lucent.app.jellyfin", account: id.uuidString)
    }

    static func jellyfinToken(for id: UUID) throws -> String? {
        try getSecret(service: "com.lucent.app.jellyfin", account: id.uuidString)
    }

    static func removeJellyfinToken(for id: UUID) {
        removeSecret(service: "com.lucent.app.jellyfin", account: id.uuidString)
    }

    static func setEmbyToken(_ token: String, for id: UUID) throws {
        try setSecret(token, service: "com.lucent.app.emby", account: id.uuidString)
    }

    static func embyToken(for id: UUID) throws -> String? {
        try getSecret(service: "com.lucent.app.emby", account: id.uuidString)
    }

    static func removeEmbyToken(for id: UUID) {
        removeSecret(service: "com.lucent.app.emby", account: id.uuidString)
    }

    static func setProfilePIN(_ pin: String) throws {
        try setSecret(pin, service: "com.lucent.app.profiles", account: "parent-pin")
    }

    static func profilePIN() throws -> String? {
        try getSecret(service: "com.lucent.app.profiles", account: "parent-pin")
    }

    static func setTraktSecret(_ value: String, account: String) throws {
        try setSecret(value, service: "com.lucent.app.trakt", account: account)
    }

    static func traktSecret(_ account: String) throws -> String? {
        try getSecret(service: "com.lucent.app.trakt", account: account)
    }

    static func setCloudToken(_ value: String, for id: UUID) throws {
        try setSecret(value, service: "com.lucent.app.cloud", account: id.uuidString)
    }

    static func cloudToken(for id: UUID) throws -> String? {
        try getSecret(service: "com.lucent.app.cloud", account: id.uuidString)
    }

    static func removeCloudToken(for id: UUID) {
        removeSecret(service: "com.lucent.app.cloud", account: id.uuidString)
    }

    static func setCloudRefreshToken(_ value: String, for id: UUID) throws {
        try setSecret(value, service: "com.lucent.app.cloud-refresh", account: id.uuidString)
    }

    static func cloudRefreshToken(for id: UUID) throws -> String? {
        try getSecret(service: "com.lucent.app.cloud-refresh", account: id.uuidString)
    }

    static func removeCloudRefreshToken(for id: UUID) {
        removeSecret(service: "com.lucent.app.cloud-refresh", account: id.uuidString)
    }

    static func setCloudClientSecret(_ value: String, for id: UUID) throws {
        try setSecret(value, service: "com.lucent.app.cloud-client-secret", account: id.uuidString)
    }

    static func cloudClientSecret(for id: UUID) throws -> String? {
        try getSecret(service: "com.lucent.app.cloud-client-secret", account: id.uuidString)
    }

    static func removeCloudClientSecret(for id: UUID) {
        removeSecret(service: "com.lucent.app.cloud-client-secret", account: id.uuidString)
    }

    static func playbackServiceSecret(_ key: String) throws -> String? {
        try getSecret(service: "com.lucent.app.playback-services", account: key)
    }

    static func setPlaybackServiceSecret(_ value: String, key: String) throws {
        try setSecret(value, service: "com.lucent.app.playback-services", account: key)
    }

    static func setOpenSubtitlesAPIKey(_ value: String) throws {
        try setSecret(value, service: "com.lucent.app.subtitles", account: "opensubtitles-api-key")
    }

    static func openSubtitlesAPIKey() throws -> String? {
        try getSecret(service: "com.lucent.app.subtitles", account: "opensubtitles-api-key")
    }

    static func setPlexToken(_ token: String, for id: UUID) throws {
        try setSecret(token, service: "com.lucent.app.plex", account: id.uuidString)
    }

    static func plexToken(for id: UUID) throws -> String? {
        try getSecret(service: "com.lucent.app.plex", account: id.uuidString)
    }

    static func removePlexToken(for id: UUID) {
        removeSecret(service: "com.lucent.app.plex", account: id.uuidString)
    }

    private static func setSecret(_ value: String, service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            #if os(iOS) && targetEnvironment(simulator) && DEBUG
            SimulatorCredentialStore.remove(service: service, account: account)
            if status == errSecMissingEntitlement { return }
            #endif
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.status(status)
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        #if os(iOS) && targetEnvironment(simulator) && DEBUG
        if update == errSecMissingEntitlement {
            try SimulatorCredentialStore.set(value, service: service, account: account)
            return
        }
        #endif
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        #if os(iOS) && targetEnvironment(simulator) && DEBUG
        if status == errSecMissingEntitlement {
            try SimulatorCredentialStore.set(value, service: service, account: account)
            return
        }
        #endif
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private static func getSecret(service: String, account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #if os(iOS) && targetEnvironment(simulator) && DEBUG
        if status == errSecMissingEntitlement || status == errSecItemNotFound {
            return try SimulatorCredentialStore.get(service: service, account: account)
        }
        #endif
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    private static func removeSecret(service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        #if os(iOS) && targetEnvironment(simulator) && DEBUG
        SimulatorCredentialStore.remove(service: service, account: account)
        #endif
    }
}

#if os(iOS) && targetEnvironment(simulator) && DEBUG
/// Debug simulator fallback for machines without a development signing identity.
/// Files stay inside this simulator's app container and are never synced or logged.
private enum SimulatorCredentialStore {
    private static func file(service: String, account: String) throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lucent/SimulatorCredentials", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let digest = SHA256.hash(data: Data("\(service)|\(account)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest)
    }

    static func get(service: String, account: String) throws -> String? {
        let url = try file(service: service, account: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return String(data: try Data(contentsOf: url), encoding: .utf8)
    }

    static func set(_ value: String, service: String, account: String) throws {
        let url = try file(service: service, account: account)
        try Data(value.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(service: String, account: String) {
        guard let url = try? file(service: service, account: account) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
#endif

private enum KeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        switch self {
        case .status(let code):
            let detail = SecCopyErrorMessageString(code, nil) as String? ?? "未知错误"
            return "无法访问系统钥匙串（\(code)：\(detail)）。"
        }
    }
}
