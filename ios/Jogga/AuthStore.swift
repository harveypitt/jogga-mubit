import AuthenticationServices
import Foundation

/// Sign in state. Sign in with Apple -> /auth/apple; DEBUG offers /auth/dev.
@Observable
final class AuthStore {
    private(set) var signedIn = false
    private(set) var displayName: String?
    private(set) var signingIn = false
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
        signedIn = api.token != nil
        if signedIn {
            Task { try? await refreshMe() }
        }
    }

    private struct AuthResponse: Decodable {
        var token: String
        var user: MeResponse.UserBody
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential, name: String?) async {
        guard let data = credential.identityToken,
              let token = String(data: data, encoding: .utf8) else {
            Analytics.capture(.signInFailed, [
                "method": .string("apple"),
                "reason": .string("no_token"),
            ])
            return
        }
        await signIn(path: "auth/apple", method: "apple", body: [
            "identity_token": token,
            "name": name as Any,
        ])
    }

    #if DEBUG
    func devSignIn(name: String = "Dev Runner") async {
        await signIn(path: "auth/dev", method: "dev", body: ["name": name])
    }
    #endif

    private func signIn(path: String, method: String, body: [String: Any]) async {
        signingIn = true
        defer { signingIn = false }
        do {
            let response: AuthResponse = try await api.post(path, body: body)
            api.setToken(response.token)
            displayName = response.user.display_name
            signedIn = true
            Analytics.identify(userID: response.user.id)
            Analytics.capture(.signInCompleted, ["method": .string(method)])
        } catch {
            signedIn = false
            Analytics.capture(.signInFailed, [
                "method": .string(method),
                "reason": .string("server_error"),
            ])
        }
    }

    func refreshMe() async throws -> MeResponse {
        let me: MeResponse = try await api.get("me")
        displayName = me.user.display_name
        Analytics.identify(userID: me.user.id)
        return me
    }

    func signOut() {
        api.setToken(nil)
        signedIn = false
        displayName = nil
        Analytics.reset()
    }
}
