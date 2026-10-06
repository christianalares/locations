import Foundation
import Observation
import Security

public enum LocationsSyncError: Error, LocalizedError {
    case invalidServer
    case invalidResponse
    case unauthorized
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidServer: "Enter a valid HTTPS server address."
        case .invalidResponse: "The Locations service returned an invalid response."
        case .unauthorized: "Check the server address and device token."
        case .server(409): "Another phone has taken over this backup. Restore on the phone you want to use."
        case .server(let status): "Cloud sync failed (HTTP \(status)). Changes remain saved on this phone."
        }
    }
}

@MainActor
@Observable
public final class BlipCloudSession {
    public private(set) var baseURL: URL?
    public private(set) var isConnected = false

    private let session: URLSession
    private let usesBackgroundUploads: Bool
    private var token: String?
    var recoveredUpload: ((Data) -> Void)?
    var recoveredUploadFailure: ((Error) -> Void)?

    public init(session: URLSession? = nil) {
        self.session = session ?? .shared
        self.usesBackgroundUploads = session == nil
        restoreConfiguration()
    }

    // An injected connection lets transport tests avoid changing the real
    // device's Keychain or saved server configuration.
    init(session: URLSession, baseURL: URL, token: String) {
        self.session = session
        self.usesBackgroundUploads = false
        self.baseURL = baseURL
        self.token = token
        self.isConnected = true
    }

    public func configure(baseURL: URL, token: String) throws {
        guard (baseURL.scheme == "https" || baseURL.host == "localhost"),
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.path.isEmpty || baseURL.path == "/" else {
            throw LocationsSyncError.invalidServer
        }

        guard !token.isEmpty else {
            throw LocationsSyncError.unauthorized
        }

        try LocationsCredentialStore.save(token: token)
        UserDefaults.standard.set(baseURL.absoluteString, forKey: "locations.sync.baseURL")
        self.baseURL = baseURL
        self.token = token
        isConnected = true
    }

    public func disconnect() {
#if os(iOS)
        LocationsBackgroundUpload.shared.cancelUploads()
#endif
        LocationsCredentialStore.delete()
        UserDefaults.standard.removeObject(forKey: "locations.sync.baseURL")
        baseURL = nil
        token = nil
        isConnected = false
    }

    private func restoreConfiguration() {
        guard let value = UserDefaults.standard.string(forKey: "locations.sync.baseURL"),
              let url = URL(string: value),
              let storedToken = LocationsCredentialStore.load() else {
            return
        }

        baseURL = url
        token = storedToken
        isConnected = true
    }

    func authorizedData(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let request = try authorizedRequest(path: path, method: method, body: body)
        let (data, response) = try await session.data(for: request)
        try validate(response)

        return data
    }

    func uploadBackup(body: Data) async throws -> Data {
#if os(iOS)
        if usesBackgroundUploads {
            LocationsBackgroundUpload.shared.recoveredUpload = { [weak self] body in
                self?.recoveredUpload?(body)
            }
            var request = try authorizedRequest(path: "native/v1/timeline/sync", method: "POST")
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            return try await LocationsBackgroundUpload.shared.upload(request: request, body: body)
        }
#endif

        var request = try authorizedRequest(
            path: "native/v1/timeline/sync", method: "POST", body: body.locationsGzipped()
        )
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        let (data, response) = try await session.data(for: request)
        try validate(response)

        return data
    }

#if os(iOS)
    public static func handleBackgroundSyncEvents(identifier: String, completion: @escaping () -> Void) {
        LocationsBackgroundUpload.shared.handleEvents(identifier: identifier, completion: completion)
    }

    func reconnectBackgroundUploads() {
        LocationsBackgroundUpload.shared.recoveredUpload = { [weak self] body in
            self?.recoveredUpload?(body)
        }
        LocationsBackgroundUpload.shared.recoveredFailure = { [weak self] error in
            self?.recoveredUploadFailure?(error)
        }
        LocationsBackgroundUpload.shared.reconnect()
    }
#endif

    private func authorizedRequest(path: String, method: String, body: Data? = nil) throws -> URLRequest {
        guard let baseURL, let token else {
            throw LocationsSyncError.unauthorized
        }

        guard let url = URL(string: "/\(path)", relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host else {
            throw LocationsSyncError.invalidServer
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil || method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw LocationsSyncError.invalidResponse
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            throw LocationsSyncError.unauthorized
        }

        guard (200..<300).contains(response.statusCode) else {
            throw LocationsSyncError.server(response.statusCode)
        }
    }
}

private enum LocationsCredentialStore {
    private static let service = "se.hiddenvillage.locations.sync"
    private static let account = "device-token"

    static func save(token: String) throws {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LocationsSyncError.unauthorized
        }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
