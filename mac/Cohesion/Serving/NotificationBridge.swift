import Foundation
import UserNotifications
import WebKit

/// Shows the page's notifications as the system's local notifications, in
/// place of its toasts: `script` sets `window.cohesionNotify` to post them
/// to this handler. Clicking one calls the page's `window.cohesionOpen` with
/// its `href`, on the page that posted it, or another if that one has gone.
/// Without permission to notify, a notification is dropped.
final class NotificationBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "cohesionNotify"
    private static let hrefKey = "href"
    private static let bridgeKey = "bridge"

    /// The page whose notifications these are; set once it exists.
    weak var page: WebPage?
    private let id = UUID().uuidString

    /// Every session's bridge, for a click to find the page to open it on.
    private static let bridges = NSHashTable<NotificationBridge>.weakObjects()
    private static let delegate = Delegate()

    override init() {
        super.init()
        Self.bridges.add(self)
        // Unless the app has a delegate of its own, which then handles them.
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil {
            center.delegate = Self.delegate
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let text = body["message"] as? String else { return }
        let content = UNMutableNotificationContent()
        content.title = body["title"] as? String ?? ""
        content.body = text
        content.sound = .default
        content.userInfo = [Self.hrefKey: body["href"] as? String ?? "", Self.bridgeKey: id]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            // Asks the first time; after that, answers as the user did.
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    /// Opens a clicked notification's `href` on the page that posted it.
    private static func open(_ userInfo: [AnyHashable: Any]) async {
        guard let href = userInfo[hrefKey] as? String, !href.isEmpty else { return }
        let live = bridges.allObjects.filter { $0.page != nil }
        guard let page = (live.first { $0.id == userInfo[bridgeKey] as? String } ?? live.first)?.page else { return }
        _ = try? await page.callJavaScript("window.cohesionOpen?.(href)", arguments: ["href": href])
    }

    /// Presents notifications while the app is in front, since the page no
    /// longer shows them as toasts, and opens a clicked one.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        // Main-actor isolated, not `nonisolated`: the system hands back its
        // completion handler when these return, and traps one called off main.

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
            await NotificationBridge.open(response.notification.request.content.userInfo)
        }
    }

    /// Sets `window.cohesionNotify` before the page's scripts run. Only what
    /// a notification shows is posted, and the page's `avatar` isn't.
    static let script = """
        window.cohesionNotify = ({ message, title, href }) => {
            window.webkit.messageHandlers.\(handlerName).postMessage({
                message: String(message),
                title: title ?? '',
                href: href ?? ''
            });
        };
        """
}
