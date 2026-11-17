import Foundation
import UIKit
import GoogleSignIn
import Observation

@Observable
class GoogleAuthManager {
    private(set) var isSignedIn: Bool = false
    private(set) var userEmail: String?
    private(set) var userName: String?
    private(set) var userPhotoURL: URL?
    private(set) var isAuthenticating: Bool = false
    /// One restore at a time: the SDK tracks a single sign-in in progress.
    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    private static let cachedEmailKey = "signedInUserEmail"
    private static let cachedNameKey = "signedInUserName"

    init() {
        let config = GIDConfiguration(clientID: AppConfig.googleClientID)
        GIDSignIn.sharedInstance.configuration = config
    }

    /// Restores the saved sign-in. Refreshing an expiring token needs network,
    /// so a restore can fail just because the phone is offline. That leaves the
    /// user signed in, with no live Google session yet: the app stays usable
    /// for recording, and `validAccessToken` tries again when uploads need it.
    @MainActor
    func restoreSignIn() async {
        if let restoreTask { return await restoreTask.value }
        let task = Task { @MainActor in
            defer { restoreTask = nil }
            do {
                let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
                updateState(with: user)
            } catch {
                if Self.needsNewSignIn(after: error) || !GIDSignIn.sharedInstance.hasPreviousSignIn() {
                    isSignedIn = false
                } else {
                    print("Couldn't restore sign-in yet: \(error.localizedDescription)")
                    let defaults = UserDefaults.standard
                    userEmail = defaults.string(forKey: Self.cachedEmailKey)
                    userName = defaults.string(forKey: Self.cachedNameKey)
                    isSignedIn = true
                }
            }
        }
        restoreTask = task
        await task.value
    }

    /// True when only signing in again can help, such as access being revoked.
    /// Anything else (no network, a Google outage) can pass by itself.
    private static func needsNewSignIn(after error: Error) -> Bool {
        let error = error as NSError
        if error.domain == kGIDSignInErrorDomain {
            return error.code == GIDSignInError.hasNoAuthInKeychain.rawValue
                || error.code == GIDSignInError.refreshTokenExpired.rawValue
        }
        // AppAuth's domain for errors returned by Google's token endpoint.
        return error.domain == "org.openid.appauth.oauth_token"
    }

    /// Whether a saved sign-in exists that hasn't been restored, for example
    /// because the keychain was unavailable when the app launched.
    @MainActor
    var canRestoreSignIn: Bool {
        !isSignedIn && GIDSignIn.sharedInstance.hasPreviousSignIn()
    }

    @MainActor
    func signIn() async throws {
        isAuthenticating = true
        defer { isAuthenticating = false }
        
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            throw URLError(.cannotFindHost)
        }
        
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: rootViewController,
            hint: nil,
            additionalScopes: AppConfig.oauthScopes
        )
        self.updateState(with: result.user)
    }
    
    @MainActor
    func validAccessToken() async throws -> String {
        if GIDSignIn.sharedInstance.currentUser == nil, GIDSignIn.sharedInstance.hasPreviousSignIn() {
            await restoreSignIn()
        }
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw URLError(.userAuthenticationRequired)
        }
        
        let refreshedUser = try await user.refreshTokensIfNeeded()
        self.updateState(with: refreshedUser)
        return refreshedUser.accessToken.tokenString
    }
    
    @MainActor
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        self.isSignedIn = false
        self.userEmail = nil
        self.userName = nil
        self.userPhotoURL = nil
        UserDefaults.standard.removeObject(forKey: Self.cachedEmailKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedNameKey)
    }
    
    @MainActor
    private func updateState(with user: GIDGoogleUser?) {
        if let user = user {
            self.isSignedIn = true
            self.userEmail = user.profile?.email
            self.userName = user.profile?.name
            // Shown in Settings if a later launch can't reach Google.
            UserDefaults.standard.set(self.userEmail, forKey: Self.cachedEmailKey)
            UserDefaults.standard.set(self.userName, forKey: Self.cachedNameKey)
            if user.profile?.hasImage == true {
                self.userPhotoURL = user.profile?.imageURL(withDimension: 200)
            }
        } else {
            self.isSignedIn = false
        }
    }
}
