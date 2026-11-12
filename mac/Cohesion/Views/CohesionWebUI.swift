import SwiftUI
import WebKit

/// The web UI for the daemon at `route`, or what stands in its way: a
/// pairing form when there is no route or the server no longer trusts this
/// app, a spinner while it loads, and why it couldn't.
struct CohesionWebUI: View {
    let client: WebUIClient
    let route: DaemonRoute?
    let pairings: PairingStore
    let onPair: (RemotePairing) -> Void

    /// `onPair` runs with each pairing made in the form.
    init(client: WebUIClient, route: DaemonRoute?, pairings: PairingStore, onPair: @escaping (RemotePairing) -> Void = { _ in }) {
        self.client = client
        self.route = route
        self.pairings = pairings
        self.onPair = onPair
    }

    var body: some View {
        content
            .task(id: Load(route: route, generation: client.generation)) {
                await client.load(route)
            }
    }

    @ViewBuilder private var content: some View {
        switch client.state {
        case .ready(let session):
            WebUIView(session: session)
        case .loading:
            ProgressView("Connecting…")
        case .unpaired:
            #if os(macOS)
            PairingView(store: pairings, onPair: onPair)
            #else
            // Nothing to show behind it until the app pairs.
            Color.clear
                .sheet(isPresented: .constant(true)) {
                    PairingSheet(store: pairings, onPair: onPair)
                        .interactiveDismissDisabled()
                }
            #endif
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Connect", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { client.retry() }
            }
        }
    }

    /// What to load: a new route, or the same one again after a failure.
    private struct Load: Equatable {
        let route: DaemonRoute?
        let generation: Int
    }
}

/// Shows a loaded web UI, edge to edge: the page runs up under the Mac's
/// window controls, in a window with a hidden title bar, or the iPad's
/// status bar, and keeps only `--titlebar-inset` clear for them.
struct WebUIView: View {
    #if os(macOS)
    /// The window's hidden title bar, which the page keeps clear for the
    /// window controls and this view's drag area.
    private static let titleBarHeight: CGFloat = 28
    #endif

    let session: WebUISession

    /// What the page keeps clear at its top, as `--titlebar-inset`: the
    /// title bar on a Mac; on an iPad, the status bar, or in a floating
    /// window the window controls in its top-leading corner.
    #if os(macOS)
    @State private var topInset = Self.titleBarHeight
    #else
    @State private var topInset: CGFloat = 0
    /// The view's size, once laid out.
    @State private var size: CGSize?
    /// While the window is being resized, and until the page has laid out
    /// at the new size: WebKit stretches a snapshot of the page meanwhile,
    /// which a blur covers.
    @State private var isResizing = false
    #endif

    init(session: WebUISession) {
        self.session = session
    }

    var body: some View {
        WebView(session.page)
            // The UI routes within one page; a swipe back would leave it
            // for whatever the history holds.
            .webViewBackForwardNavigationGestures(.disabled)
            .ignoresSafeArea()
            #if os(iOS)
            .onGeometryChange(for: Layout.self) { proxy in
                Layout(
                    size: proxy.size,
                    topInset: max(proxy.safeAreaInsets.top, proxy.containerCornerInsets.topLeading.height)
                )
            } action: { layout in
                // Width only: the keyboard changes the height and is no reason to blur.
                if let size, size.width != layout.size.width { isResizing = true }
                size = layout.size
                topInset = layout.topInset
            }
            .overlay {
                if isResizing {
                    Rectangle()
                        .fill(.regularMaterial)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .task(id: size) { await settle() }
            #endif
            // A new document starts without it, so it is set again after each load.
            .task(id: Inset(points: topInset, isLoading: session.page.isLoading)) {
                guard !session.page.isLoading else { return }
                _ = try? await session.page.callJavaScript(
                    "document.documentElement.style.setProperty('--titlebar-inset', `${points}px`)",
                    arguments: ["points": Double(topInset)]
                )
            }
            #if os(macOS)
            .background { MouseNavigation(page: session.page) }
            // The web view would take the clicks a title bar uses to move the window.
            .overlay(alignment: .top) {
                Color.clear
                    .frame(height: Self.titleBarHeight)
                    .contentShape(.rect)
                    .gesture(WindowDragGesture())
                    .allowsWindowActivationEvents(true)
                    .ignoresSafeArea()
            }
            #endif
            .task(id: session.url) {
                // Only the first load: a page shown again keeps its place.
                guard session.page.url == nil else { return }
                do {
                    for try await _ in session.page.load(URLRequest(url: session.url)) {}
                } catch {
                    // WebKit shows its own error page.
                }
            }
    }

    #if os(iOS)
    /// Once the size has held still for a moment, waits for the page to lay
    /// out at it, then lifts the blur.
    private func settle() async {
        guard isResizing, let size else { return }
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        // Two frames after the page reports the new width, its new layout is
        // on screen. Give up after a second and a half rather than stay blurred.
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let width = try? await session.page.callJavaScript(
                "await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))); return window.innerWidth;"
            ) as? Double
            if let width, abs(width - size.width) < 1 { break }
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) { isResizing = false }
    }

    private nonisolated struct Layout: Equatable {
        let size: CGSize
        let topInset: CGFloat
    }
    #endif

    private struct Inset: Equatable {
        let points: CGFloat
        let isLoading: Bool
    }
}

#if os(macOS)
/// Takes a mouse's back and forward buttons, clicked in this view's window,
/// through `page`'s history, as a browser does. The page fills its window.
private struct MouseNavigation: NSViewRepresentable {
    let page: WebPage

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.page = page
    }

    final class MonitorView: NSView {
        var page: WebPage?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard let self, let page, event.window === window else { return event }
                switch event.buttonNumber {
                case 3: page.goBack()
                case 4: page.goForward()
                default: return event
                }
                return nil
            }
        }

        // Clicks are the web view's.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
