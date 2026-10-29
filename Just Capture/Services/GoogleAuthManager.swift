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
    
    init() {
        let config = GIDConfiguration(clientID: AppConfig.googleClientID)
        GIDSignIn.sharedInstance.configuration = config
    }
    
    @MainActor
    func restoreSignIn() async {
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            self.updateState(with: user)
        } catch {
            self.isSignedIn = false
        }
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
    }
    
    @MainActor
    private func updateState(with user: GIDGoogleUser?) {
        if let user = user {
            self.isSignedIn = true
            self.userEmail = user.profile?.email
            self.userName = user.profile?.name
            if user.profile?.hasImage == true {
                self.userPhotoURL = user.profile?.imageURL(withDimension: 200)
            }
        } else {
            self.isSignedIn = false
        }
    }
}
