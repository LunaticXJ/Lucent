import Foundation
import Security

enum KeychainPasswordStore {
    private static let service = "com.lucent.app.smb"

    static func set(_ password: String, for id: UUID) throws {
        try setSecret(password, service: service, account: id.uuidString)
    }

    static func get(for id: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    static func remove(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func setMetadataToken(_ token: String) throws {
        try setSecret(token, service: "com.lucent.app.metadata", account: "tmdb")
    }

    static func metadataToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lucent.app.metadata",
            kSecAttrAccount as String: "tmdb",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return String(data: data, encoding: .utf8)
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

    static func setVLCNetworkPassword(_ value: String, for id: UUID) throws {
        try setSecret(value, service: "com.lucent.app.vlc-network", account: id.uuidString)
    }

    static func vlcNetworkPassword(for id: UUID) throws -> String? {
        try getSecret(service: "com.lucent.app.vlc-network", account: id.uuidString)
    }

    static func removeVLCNetworkPassword(for id: UUID) {
        removeSecret(service: "com.lucent.app.vlc-network", account: id.uuidString)
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
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.status(status)
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
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
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    private static func removeSecret(service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

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
