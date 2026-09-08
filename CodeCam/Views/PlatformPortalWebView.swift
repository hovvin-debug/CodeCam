import Foundation
import SwiftUI
import WebKit

/// A platform origin is the only web origin CodeCam may open after a scan.
/// It intentionally excludes any path, query, and fragment from the configured base URL.
struct PlatformOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    nonisolated init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              scheme == "http" || scheme == "https" else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        self.port = components.port ?? Self.defaultPort(for: scheme)
    }

    nonisolated func matches(_ url: URL) -> Bool {
        guard let candidate = PlatformOrigin(url: url) else { return false }
        return self == candidate
    }

    nonisolated static func == (lhs: PlatformOrigin, rhs: PlatformOrigin) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host == rhs.host && lhs.port == rhs.port
    }

    nonisolated func url(forPlatformPath path: String) throws -> URL {
        guard let components = URLComponents(string: path),
              components.scheme == nil,
              components.host == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              path.hasPrefix("/"),
              !path.hasPrefix("//"),
              !components.percentEncodedPath.lowercased().contains("%2e"),
              !components.percentEncodedPath.lowercased().contains("%2f"),
              !components.percentEncodedPath.lowercased().contains("%5c"),
              !components.path.split(separator: "/").contains("..") else {
            throw PlatformPortalError.invalidPlatformPath
        }

        var target = URLComponents()
        target.scheme = scheme
        target.host = host
        target.port = port == Self.defaultPort(for: scheme) ? nil : port
        target.percentEncodedPath = components.percentEncodedPath
        guard let url = target.url else { throw PlatformPortalError.invalidPlatformPath }
        return url
    }

    private nonisolated static func defaultPort(for scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }
}

struct PlatformPortalResource: Equatable {
    let path: String

    nonisolated static func == (lhs: PlatformPortalResource, rhs: PlatformPortalResource) -> Bool {
        lhs.path == rhs.path
    }
}

enum ScannedCodeRoute: Equatable {
    case productCode(String)
    case platformPortal(PlatformPortalResource)

    nonisolated static func == (lhs: ScannedCodeRoute, rhs: ScannedCodeRoute) -> Bool {
        switch (lhs, rhs) {
        case (.productCode(let left), .productCode(let right)):
            left == right
        case (.platformPortal(let left), .platformPortal(let right)):
            left == right
        default:
            false
        }
    }
}

enum PlatformPortalQRCodeRouter {
    /// A normal product code stays in the capture flow. Only an absolute HTTP(S) URL or
    /// a slash-prefixed platform path can request the embedded portal.
    static func route(scannedValue: String, platformBaseURL: URL?) throws -> ScannedCodeRoute {
        let value = scannedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .productCode(value) }

        if value.hasPrefix("/") {
            guard let origin = platformBaseURL.flatMap(PlatformOrigin.init(url:)) else {
                throw PlatformPortalError.invalidPlatformConfiguration
            }
            return .platformPortal(PlatformPortalResource(path: try normalizedPath(value, origin: origin)))
        }

        let lowercased = value.lowercased()
        let hasExplicitScheme = URLComponents(string: value)?.scheme != nil
        let looksLikeURL = lowercased.hasPrefix("http:") || lowercased.hasPrefix("https:") || value.contains("://") || hasExplicitScheme
        guard looksLikeURL else { return .productCode(value) }

        guard let scannedURL = URL(string: value),
              let origin = platformBaseURL.flatMap(PlatformOrigin.init(url:)) else {
            throw PlatformPortalError.invalidPlatformConfiguration
        }
        guard origin.matches(scannedURL) else { throw PlatformPortalError.nonPlatformAddress }

        guard let components = URLComponents(url: scannedURL, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw PlatformPortalError.invalidPlatformPath
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return .platformPortal(PlatformPortalResource(path: try normalizedPath(path, origin: origin)))
    }

    private static func normalizedPath(_ path: String, origin: PlatformOrigin) throws -> String {
        let url = try origin.url(forPlatformPath: path)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PlatformPortalError.invalidPlatformPath
        }
        return components.percentEncodedPath
    }
}

struct PlatformPortalSession: Identifiable {
    let exchangeURL: URL
    let ticket: String
    let origin: PlatformOrigin
    let id = UUID()
}

enum PlatformPortalSessionService {
    /// The platform authenticates this API call from the App's existing protected session.
    /// The returned ticket is sent only in the POST body to the same-origin exchange endpoint.
    static func create(for resource: PlatformPortalResource, platformBaseURL: URL?) async throws -> PlatformPortalSession {
        guard let platformBaseURL, let origin = PlatformOrigin(url: platformBaseURL) else {
            throw PlatformPortalError.invalidPlatformConfiguration
        }

        let response = try await EdgeFlowClient.post(
            "/api/terminal/v1/web-sessions",
            body: ["resourcePath": resource.path]
        )
        guard let ticket = response["ticket"] as? String,
              !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlatformPortalError.invalidSessionResponse
        }

        let exchangePath = response["exchangePath"] as? String ?? "/api/terminal/v1/web-sessions/exchange"
        let exchangeURL = try origin.url(forPlatformPath: exchangePath)
        return PlatformPortalSession(exchangeURL: exchangeURL, ticket: ticket, origin: origin)
    }

    static func exchangeRequest(for session: PlatformPortalSession) throws -> URLRequest {
        var request = URLRequest(url: session.exchangeURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ticket": session.ticket])
        return request
    }
}

enum PlatformPortalError: LocalizedError, Equatable, Identifiable {
    case invalidPlatformConfiguration
    case nonPlatformAddress
    case invalidPlatformPath
    case invalidSessionResponse
    case blockedNavigation

    var id: String { String(describing: self) }

    var errorDescription: String? {
        switch self {
        case .invalidPlatformConfiguration: "本机的平台服务器地址无效。"
        case .nonPlatformAddress: "该二维码不属于本机已登记的平台服务器。"
        case .invalidPlatformPath: "二维码中的平台资源地址无效。"
        case .invalidSessionResponse: "平台未返回有效的网页会话。"
        case .blockedNavigation: "已阻止跳转到非平台页面。"
        }
    }
}

struct PlatformPortalBrowserView: View {
    let session: PlatformPortalSession
    @Environment(\.dismiss) private var dismiss
    @State private var navigationError: PlatformPortalError?

    var body: some View {
        NavigationStack {
            PlatformPortalWebView(session: session) { error in
                navigationError = error
            }
            .navigationTitle("平台服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert(item: $navigationError) { error in
                Alert(title: Text("无法打开页面"), message: Text(error.localizedDescription), dismissButton: .default(Text("知道了")))
            }
        }
    }
}

private struct PlatformPortalWebView: UIViewRepresentable {
    let session: PlatformPortalSession
    let onBlockedNavigation: (PlatformPortalError) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(origin: session.origin, onBlockedNavigation: onBlockedNavigation)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A non-persistent store drops portal cookies and cache when this sheet closes.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if let request = try? PlatformPortalSessionService.exchangeRequest(for: session) {
            webView.load(request)
        } else {
            onBlockedNavigation(.invalidSessionResponse)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let origin: PlatformOrigin
        private let onBlockedNavigation: (PlatformPortalError) -> Void

        init(origin: PlatformOrigin, onBlockedNavigation: @escaping (PlatformPortalError) -> Void) {
            self.origin = origin
            self.onBlockedNavigation = onBlockedNavigation
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, origin.matches(url) else {
                onBlockedNavigation(.blockedNavigation)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            guard let url = navigationResponse.response.url, origin.matches(url) else {
                onBlockedNavigation(.blockedNavigation)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url, origin.matches(url) else {
                onBlockedNavigation(.blockedNavigation)
                return nil
            }
            webView.load(navigationAction.request)
            return nil
        }
    }
}
