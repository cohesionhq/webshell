import Foundation
import WebKit

/// Carries the page's `/connect` WebSockets, which a scheme handler can't
/// answer, to sessions of the app's own: `script` stands in for `WebSocket`
/// on that one URL and posts what the page does to this handler, which
/// opens a session on `route` for each socket, relays text frames both ways
/// unchanged, and closes either side when the other closes, as `cohesion
/// open`'s `bridge.rs` does. The page talks to it as it would to the proxy:
/// `/connect?token=<token>`, refused without the session's token.
final class SocketBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "cohesionSocket"

    private let route: DaemonRoute
    private let token: String
    /// The page frames go back to; set once it exists.
    weak var page: WebPage?
    /// Each open socket's session, by the id the page gave the socket.
    private var sessions: [String: Session] = [:]
    /// What to tell the page, in order: it is told one thing at a time.
    private let deliveries: AsyncStream<Delivery>.Continuation
    private var delivering: Task<Void, Never>?

    init(route: DaemonRoute, token: String) {
        self.route = route
        self.token = token
        let (stream, deliveries) = AsyncStream.makeStream(of: Delivery.self)
        self.deliveries = deliveries
        super.init()
        delivering = Task { [weak self] in
            for await delivery in stream {
                await self?.deliver(delivery)
            }
        }
    }

    isolated deinit {
        deliveries.finish()
        delivering?.cancel()
        sessions.values.forEach { $0.close() }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return }
        let id = body["id"] as? String ?? ""
        switch op {
        case "open": open(id, token: body["token"] as? String)
        case "send": sessions[id]?.send(body["text"] as? String ?? "")
        case "close":
            sessions.removeValue(forKey: id)?.close()
            deliveries.yield(.closed(id, code: 1000))
        // A new document: the last one's sockets are gone.
        case "reset":
            sessions.values.forEach { $0.close() }
            sessions = [:]
        default: break
        }
    }

    private func open(_ id: String, token: String?) {
        guard token == self.token else {
            // Policy violation, as the proxy's 401 ends the handshake.
            deliveries.yield(.closed(id, code: 1008))
            return
        }
        let connection: any DaemonConnection
        do {
            connection = try route.connect()
        } catch {
            deliveries.yield(.closed(id, code: 1006))
            return
        }
        let session = Session(connection)
        sessions[id] = session
        deliveries.yield(.opened(id))
        let deliveries = deliveries
        Task { [weak self] in
            var code = 1000
            do {
                for try await frame in connection.frames {
                    deliveries.yield(.message(id, frame))
                }
            } catch {
                code = 1006
            }
            // Unless the page closed it first, which it was then told.
            guard let self, sessions[id] === session else { return }
            sessions[id] = nil
            session.close()
            deliveries.yield(.closed(id, code: code))
        }
    }

    private func deliver(_ delivery: Delivery) async {
        guard let page else { return }
        let (call, arguments): (String, [String: Any]) = switch delivery {
        case .opened(let id): ("opened(id)", ["id": id])
        case .message(let id, let text): ("message(id, text)", ["id": id, "text": text])
        case .closed(let id, let code): ("closed(id, code)", ["id": id, "code": code])
        }
        _ = try? await page.callJavaScript("window.__cohesionSocket.\(call)", arguments: arguments)
    }

    /// What happened to one of the page's sockets.
    private enum Delivery {
        case opened(String)
        case message(String, String)
        case closed(String, code: Int)
    }

    /// One socket's session: frames the page sends go out one at a time, in order.
    private final class Session {
        private let connection: any DaemonConnection
        private let outbox: AsyncStream<String>.Continuation
        private let sending: Task<Void, Never>

        init(_ connection: any DaemonConnection) {
            self.connection = connection
            let (stream, outbox) = AsyncStream.makeStream(of: String.self)
            self.outbox = outbox
            sending = Task {
                for await frame in stream {
                    do {
                        try await connection.send(frame)
                    } catch {
                        // Ends `frames`, which closes the page's socket.
                        connection.close()
                        return
                    }
                }
            }
        }

        func send(_ frame: String) {
            outbox.yield(frame)
        }

        func close() {
            outbox.finish()
            sending.cancel()
            connection.close()
        }
    }

    /// Replaces `WebSocket` for `/connect` on the page's own origin, before
    /// the page's scripts run; any other URL gets a real WebSocket. Each
    /// socket has a random id, so a reply meant for a socket of a document
    /// that has since reloaded finds nothing.
    static let script = """
        (() => {
            const handler = window.webkit.messageHandlers.\(handlerName);
            const NativeWebSocket = window.WebSocket;
            const sockets = new Map();
            const emit = (socket, event) => {
                socket.dispatchEvent(event);
                socket['on' + event.type]?.call(socket, event);
            };

            class BridgedWebSocket extends EventTarget {
                static CONNECTING = 0;
                static OPEN = 1;
                static CLOSING = 2;
                static CLOSED = 3;
                CONNECTING = 0;
                OPEN = 1;
                CLOSING = 2;
                CLOSED = 3;
                onopen = null;
                onmessage = null;
                onerror = null;
                onclose = null;
                binaryType = 'blob';
                bufferedAmount = 0;
                extensions = '';
                protocol = '';
                readyState = 0;

                constructor(url) {
                    super();
                    this.url = url.href;
                    this.id = crypto.randomUUID();
                    sockets.set(this.id, this);
                    handler.postMessage({ op: 'open', id: this.id, token: url.searchParams.get('token') ?? '' });
                }

                send(data) {
                    if (this.readyState === 0) throw new DOMException('Still connecting.', 'InvalidStateError');
                    if (this.readyState !== 1) return;
                    handler.postMessage({ op: 'send', id: this.id, text: String(data) });
                }

                close() {
                    if (this.readyState >= 2) return;
                    this.readyState = 2;
                    handler.postMessage({ op: 'close', id: this.id });
                }
            }

            Object.defineProperty(window, '__cohesionSocket', {
                value: Object.freeze({
                    opened(id) {
                        const socket = sockets.get(id);
                        if (socket?.readyState !== 0) return;
                        socket.readyState = 1;
                        emit(socket, new Event('open'));
                    },
                    message(id, text) {
                        const socket = sockets.get(id);
                        if (socket?.readyState === 1) emit(socket, new MessageEvent('message', { data: text }));
                    },
                    closed(id, code) {
                        const socket = sockets.get(id);
                        if (!socket) return;
                        sockets.delete(id);
                        socket.readyState = 3;
                        if (code !== 1000) emit(socket, new Event('error'));
                        emit(socket, new CloseEvent('close', { code, wasClean: code === 1000 }));
                    }
                })
            });

            function WebSocket(url, protocols) {
                const target = new URL(url, location.href);
                if (target.host === location.host && target.pathname === '/connect') {
                    return new BridgedWebSocket(target);
                }
                return new NativeWebSocket(url, protocols);
            }
            WebSocket.prototype = NativeWebSocket.prototype;
            Object.assign(WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
            window.WebSocket = WebSocket;
            handler.postMessage({ op: 'reset' });
        })();
        """
}
