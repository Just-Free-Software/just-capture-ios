import Foundation

enum AppConfig {
    static let googleClientID = "1003597781614-l45439l3m6is4lcn2bmhhhj67292inmg.apps.googleusercontent.com"
    static let redirectURI = "com.googleusercontent.apps.1003597781614-l45439l3m6is4lcn2bmhhhj67292inmg:/oauthredirect"
    static let callbackURLScheme = "com.googleusercontent.apps.1003597781614-l45439l3m6is4lcn2bmhhhj67292inmg"
    static let oauthScopes: [String] = [
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile"
    ]
    /// Google Cloud API key used to read folders other people shared as
    /// "anyone with the link". Restrict it to the Drive API and this app's
    /// bundle ID in Cloud Console; it ships in the app, so treat it as public.
    static let driveAPIKey = "AIzaSyBRjrEWpSUE80PWNgTGPUPFS-uw1WzYJag"
    static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let userInfoEndpoint = "https://www.googleapis.com/oauth2/v2/userinfo"
    static let defaultChunkDuration: TimeInterval = 30
    static let maxConcurrentUploads: Int = 2
    static let videoWidth: Int = 1920
    static let videoHeight: Int = 1080
    // ~6 Mbps HEVC 1080p; used until real chunk data is available
    static let estimatedVideoBytesPerSecond: Double = 750_000

    static let homepageURL = URL(string: "https://justfreesoftware.fyi/just-capture/info")!
    static let privacyPolicyURL = URL(string: "https://justfreesoftware.fyi/just-capture/privacy-policy")!
}
