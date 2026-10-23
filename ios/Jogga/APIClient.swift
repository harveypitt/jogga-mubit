import Foundation

/// Minimal async/await URLSession client. Bearer token lives in the Keychain.
@Observable
final class APIClient {
    /// Keychain item keys.
    private let service = "co.aliveindustries.jogga"
    private let account = "session-token"

    private(set) var token: String?

    init() {
        token = Self.readToken(service: service, account: account)
    }

    var baseURL: URL {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "jogga.apiURL"),
           let url = URL(string: override), !override.isEmpty {
            return url
        }
        #endif
        let configured = Bundle.main.object(forInfoDictionaryKey: "JOGGA_API_URL") as? String
        return URL(string: configured ?? "http://localhost:8000")!
    }

    func setToken(_ token: String?) {
        self.token = token
        Self.writeToken(token, service: service, account: account)
    }

    // MARK: Requests

    func request(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let (data, http) = try await request("POST", path, body: body)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }

    func put(_ path: String, body: [String: Any]) async throws {
        let (_, http) = try await request("PUT", path, body: body)
        guard (200..<300).contains(http.statusCode) else { throw APIError(status: http.statusCode) }
    }

    func delete(_ path: String, query: [URLQueryItem] = []) async throws {
        let (_, http) = try await request("DELETE", path, query: query)
        guard (200..<300).contains(http.statusCode) else { throw APIError(status: http.statusCode) }
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, http) = try await request("GET", path)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    struct APIError: Error {
        var status: Int
    }

    // MARK: Keychain

    private static func readToken(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeToken(_ token: String?, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let token {
            let attrs: [String: Any] = [kSecValueData as String: Data(token.utf8)]
            if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) != errSecSuccess {
                var add = query
                add[kSecValueData as String] = Data(token.utf8)
                SecItemAdd(add as CFDictionary, nil)
            }
        } else {
            SecItemDelete(query as CFDictionary)
        }
    }
}
