import AuthenticationServices
import SwiftUI

/// Near-empty sign-in: mark, wordmark, one line, Apple button pinned bottom.
/// DEBUG adds a small "Continue without Apple" text button.
struct SignInView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                mark
                Text("jogga")
                    .font(.system(size: 60, weight: .heavy, design: .rounded))
                    .tracking(-1)
                Text("Run the distance.\nBeat the time.")
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 12)
            Spacer()
            Spacer()
            VStack(spacing: 14) {
                SignInWithAppleButton(.signIn) { request in
                    Analytics.capture(.signInStarted, ["method": .string("apple")])
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    switch result {
                    case .success(let authorization):
                        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
                            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                                .compactMap { $0 }
                                .joined(separator: " ")
                            Task {
                                await auth.signInWithApple(
                                    credential: credential,
                                    name: name.isEmpty ? nil : name
                                )
                            }
                        }
                    case .failure(let error):
                        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
                        Analytics.capture(.signInFailed, [
                            "method": .string("apple"),
                            "reason": .string(cancelled ? "cancelled" : "apple_error"),
                        ])
                    }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityLabel("Sign in with Apple")
                #if DEBUG
                Button("Continue without Apple") {
                    Analytics.capture(.signInStarted, ["method": .string("dev")])
                    Task { await auth.devSignIn() }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                #endif
                Text("No ads. No feed. Just your times.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .disabled(auth.signingIn)
        .overlay {
            if auth.signingIn { ProgressView().controlSize(.large) }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.8)) { appeared = true }
        }
        .trackScreen(.signIn)
    }

    private var mark: some View {
        Image("Logo")
            .resizable()
            .interpolation(.high)
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            .accessibilityHidden(true)
    }
}
