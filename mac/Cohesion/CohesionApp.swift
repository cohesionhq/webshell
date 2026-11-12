import SwiftUI

/// Shows the Cohesion web UI for each server this device paired with, an
/// account in a window of its own, served from the bundle that server hands
/// out.
@main
struct CohesionApp: App {
    @State private var pairings = PairingStore()

    var body: some Scene {
        // Each window has its own page and connection, on the account it
        // was opened on, which SwiftUI restores with it. Windows on one
        // account share its pages' storage. The id names the saved window
        // frames: without one SwiftUI names them by the content's type, whose
        // name, for a private type, changes every launch.
        WindowGroup(id: "main", for: WindowAccount.self) { $account in
            CohesionWindow(pairings: pairings, account: $account)
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

/// Which account a window is on.
private enum WindowAccount: Codable, Hashable {
    /// The account with this id.
    case pairing(String)
    /// None yet: the window shows the pairing form, for a new account.
    case new
}

extension FocusedValues {
    /// The id of the account the frontmost window is on.
    @Entry var accountID: String?
}

/// One window's web UI, on one account, titled by its page.
private struct CohesionWindow: View {
    let pairings: PairingStore
    /// `nil` in a window opened before it was given one, which is on the
    /// first account.
    @Binding var account: WindowAccount?
    @State private var webUI = WebUIClient()

    /// The window's account, while the app is still paired with it.
    private var pairing: RemotePairing? {
        switch account {
        case .pairing(let id)?: pairings.remote(id: id)
        case .new?: nil
        case nil: pairings.remotes.first
        }
    }

    var body: some View {
        CohesionWebUI(client: webUI, route: pairing.map(DaemonRoute.remote), pairings: pairings) { pairing in
            account = .pairing(pairing.id)
        }
        .modifier(UpdateOffer(client: webUI))
        .navigationTitle(webUI.title)
        .focusedSceneValue(webUI)
        .focusedSceneValue(\.accountID, pairing?.id)
    }
}

/// The File menu's new windows, one for each account, and the Cohesion menu,
/// acting on the frontmost window's page and account.
private struct CohesionCommands: Commands {
    let pairings: PairingStore
    @FocusedValue(WebUIClient.self) private var webUI
    @FocusedValue(\.accountID) private var accountID
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // As Safari's profiles: with several accounts, New Window names
            // each, and ⌘N opens one on the frontmost window's.
            if pairings.remotes.count > 1 {
                let current = accountID ?? pairings.remotes.first?.id
                Menu("New Window") {
                    ForEach(pairings.remotes) { remote in
                        Button("New \(remote.label) Window") {
                            openWindow(id: "main", value: WindowAccount.pairing(remote.id))
                        }
                        .keyboardShortcut(remote.id == current ? KeyboardShortcut("n") : nil)
                    }
                }
            } else {
                Button("New Window") {
                    openWindow(id: "main", value: pairings.remotes.first.map { WindowAccount.pairing($0.id) } ?? .new)
                }
                .keyboardShortcut("n")
            }
            Button("Add Account…") { openWindow(id: "main", value: WindowAccount.new) }
        }
        // As a browser's: through the page's own history, which its routes
        // push to.
        CommandGroup(before: .toolbar) {
            Button("Back") { webUI?.page?.goBack() }
                .keyboardShortcut("[")
                .disabled(webUI?.page?.canGoBack != true)
            Button("Forward") { webUI?.page?.goForward() }
                .keyboardShortcut("]")
                .disabled(webUI?.page?.canGoForward != true)
            Divider()
        }
        CommandGroup(after: .appSettings) {
            Button("Install Update…") { webUI?.update() }
                .disabled(webUI?.updateAvailable != true)
            Button("Unpair") {
                if let accountID { pairings.unpair(id: accountID) }
            }
            .disabled(accountID == nil)
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
