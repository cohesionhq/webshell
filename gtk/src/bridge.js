// Replaces `WebSocket` for `/connect` on the page's own origin, before the
// page's scripts run; any other URL gets a real WebSocket. Each socket has a
// random id, so a reply meant for a socket of a document that has since
// reloaded finds nothing. The same script as CohesionWebKit's `SocketBridge`.
(() => {
    const handler = window.webkit.messageHandlers.cohesionSocket;
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
