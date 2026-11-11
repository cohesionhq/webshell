import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One loaded web UI: the page showing it, served from `assets` by a scheme
/// handler, and talking to the daemon at `route` through a `SocketBridge`.
/// Its notifications are the system's, through a `NotificationBridge`.
/// `onUpdate` runs when a session the page opens finds the server serving
/// a newer build than `assets`.
/// The page reads the token it presents from the URL it is first opened
/// at, so it is opened with a fresh one each session.
final class WebUISession {
    let route: DaemonRoute
    let page: WebPage
    /// `cohesion://app/#token=<token>`.
    let url: URL

    init(route: DaemonRoute, assets: WebAssets, onUpdate: @escaping () -> Void) {
        let token = Self.freshToken()
        let bridge = SocketBridge(route: route, token: token, hash: assets.hash, onUpdate: onUpdate)
        let notifications = NotificationBridge()
        var configuration = WebPage.Configuration()
        configuration.urlSchemeHandlers[URLScheme(WebUISchemeHandler.scheme)!] = WebUISchemeHandler(
            assets: assets,
            token: token,
            target: route.target
        )
        // Each account's pages keep their storage apart from every other's.
        if case .remote(let pairing) = route {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: pairing.dataStoreID)
        }
        configuration.userContentController.addUserScript(
            WKUserScript(source: SocketBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        configuration.userContentController.add(bridge, contentWorld: .page, name: SocketBridge.handlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(source: NotificationBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        configuration.userContentController.add(notifications, contentWorld: .page, name: NotificationBridge.handlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.openInPlace, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        #if os(macOS)
        page = WebPage(configuration: configuration, navigationDecider: OwnOriginOnly(), dialogPresenter: FilePicker())
        #else
        page = WebPage(configuration: configuration, navigationDecider: OwnOriginOnly())
        #endif
        bridge.page = page
        notifications.page = page
        #if DEBUG
        page.isInspectable = true
        #endif
        self.route = route
        url = URL(string: "#token=\(token)", relativeTo: WebUISchemeHandler.origin)!.absoluteURL
    }

    /// 32 random letters and digits, like `cohesion open`'s launch token.
    private static func freshToken() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// `WebPage` can't open new windows, so `window.open`, as a sign-in page
    /// uses, navigates instead and `OwnOriginOnly` sends it to the browser.
    private static let openInPlace = """
        const open = window.open;
        window.open = (url, ...rest) => {
            if (new URL(url, location.href).protocol === 'blob:') return open.call(window, url, ...rest);
            location.assign(url);
            return null;
        };
        """
}

/// Keeps the page on the UI's own origin and opens anything else, like an
/// account's sign-in page, in the default browser.
private struct OwnOriginOnly: WebPage.NavigationDeciding {
    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        let url = action.request.url
        if url?.scheme == WebUISchemeHandler.scheme || url?.scheme == "about" || url?.scheme == "blob" {
            return .allow
        }
        if let url {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            await UIApplication.shared.open(url)
            #endif
        }
        return .cancel
    }
}

#if os(macOS)
/// Answers `<input type="file">` with an open panel.
private struct FilePicker: WebPage.DialogPresenting {
    func handleFileInputPrompt(
        parameters: WKOpenPanelParameters,
        initiatedBy frame: WebPage.FrameInfo
    ) async -> WebPage.FileInputPromptResult {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard await panel.begin() == .OK else { return .cancel }
        return .selected(panel.urls)
    }
}
#endif
