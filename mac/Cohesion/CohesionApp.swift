import CohesionWebKit
import SwiftUI

/// Shows the Cohesion web UI for the server this device paired with, served
/// from the bundle that server hands out.
@main
struct CohesionApp: App {
    @State private var pairings = PairingStore()

    var body: some Scene {
        // Each window has its own page and connection. The pairing, and the
        // pages' storage, are shared. The id names the saved window frames:
        // without one SwiftUI names them by the content's type, whose name,
        // for a private type, changes every launch.
        WindowGroup(id: "main") {
            CohesionWindow(pairings: pairings)
        }
        #if os(macOS)
        // The page runs up under the window controls and keeps
        // `--titlebar-inset` clear for them.
        .windowStyle(.hiddenTitleBar)
        #endif
        .commands {
            CohesionCommands(pairings: pairings)
        }
    }
}

/// One window's web UI, titled by its page.
private struct CohesionWindow: View {
    let pairings: PairingStore
    @State private var webUI = WebUIClient()

    var body: some View {
        CohesionWebUI(client: webUI, route: pairings.remote.map(DaemonRoute.remote), pairings: pairings)
            .modifier(UpdateOffer(client: webUI))
            .navigationTitle(webUI.title)
            .focusedSceneValue(webUI)
    }
}

/// The Cohesion menu, acting on the frontmost window's page.
private struct CohesionCommands: Commands {
    let pairings: PairingStore
    @FocusedValue(WebUIClient.self) private var webUI

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Update and reload") { webUI?.update() }
                .disabled(webUI?.updateAvailable != true)
            Button("Unpair") { pairings.unpair() }
                .disabled(pairings.remote == nil)
        }
    }
}

/// Offers a newer web UI, once the page reconnects to a server serving
/// one, in a banner over the top of the page.
private struct UpdateOffer: ViewModifier {
    let client: WebUIClient
    @State private var isDismissed = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if client.updateAvailable, !isDismissed {
                    UpdateBanner(update: client.update) {
                        withAnimation { isDismissed = true }
                    }
                    .padding(8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.default, value: client.updateAvailable)
            // A later update is offered again.
            .onChange(of: client.updateAvailable) { if !client.updateAvailable { isDismissed = false } }
    }
}

private struct UpdateBanner: View {
    let update: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("A new version of Cohesion is ready.")
                .font(.callout)
            Button("Update and reload", action: update)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .glassEffect()
    }
}
