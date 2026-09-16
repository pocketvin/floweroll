import Foundation
import Security


enum HostCredentialStoreError: Error, Equatable {
    case invalidEndpoint
    case emptyToken
    case unexpectedStatus(OSStatus)
    case invalidStoredToken
}

struct HostCredentialStore: Sendable {
    private let service: String

    init(service: String = "com.maxenceyu.floweroll.host-auth") {
        self.service = service
    }

    func saveBearerToken(_ token: String, for baseURL: URL) throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw HostCredentialStoreError.emptyToken
        }
        let account = try accountKey(for: baseURL)
        let data = Data(normalized.utf8)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            // Background work can read the credential after the user has
            // unlocked the phone once since reboot. ThisDeviceOnly prevents
            // the pairing secret from silently migrating to another device.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw HostCredentialStoreError.unexpectedStatus(updateStatus)
        }

        var add = query
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw HostCredentialStoreError.unexpectedStatus(addStatus)
        }
    }

    func bearerToken(for baseURL: URL) throws -> String? {
        let account = try accountKey(for: baseURL)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw HostCredentialStoreError.unexpectedStatus(status)
        }
        guard
            let data = result as? Data,
            let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else {
            throw HostCredentialStoreError.invalidStoredToken
        }
        return token
    }

    func removeBearerToken(for baseURL: URL) throws {
        let account = try accountKey(for: baseURL)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HostCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func accountKey(for baseURL: URL) throws -> String {
        guard
            let scheme = baseURL.scheme?.lowercased(),
            let host = baseURL.host?.lowercased(),
            !scheme.isEmpty,
            !host.isEmpty
        else {
            throw HostCredentialStoreError.invalidEndpoint
        }
        let port: Int
        if let explicitPort = baseURL.port {
            port = explicitPort
        } else if scheme == "https" {
            port = 443
        } else if scheme == "http" {
            port = 80
        } else {
            throw HostCredentialStoreError.invalidEndpoint
        }
        return "\(scheme)://\(host):\(port)"
    }
}
